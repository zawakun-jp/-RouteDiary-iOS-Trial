import Foundation
import Security
import Combine
import UIKit

/// Android v2.11 の BackupApi と同じサーバー API。秘密情報は Keychain のみに保存。
enum CloudError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let detail) = self { return detail }; return "クラウド通信エラー" }
}

private enum TokenVault {
    private static let service = "jp.zsg.routediary.ios.cloud"
    private static let account = "access_token"
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw CloudError.message("Keychainにログイン情報を保存できません")
        }
    }
    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class CloudClient: ObservableObject {
    private let url = URL(string: "https://cc.zsg.jp/routediary/api/v1/index.php")!
    @Published private(set) var username = UserDefaults.standard.string(forKey: "cloudUsername") ?? ""
    @Published private(set) var signedIn = TokenVault.read() != nil
    @Published private(set) var avatarImage: UIImage?

    private func request(_ action: String, method: String = "GET", body: [String: Any]? = nil,
                         authenticated: Bool = true, query: [URLQueryItem] = []) async throws -> Any {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "action", value: action)] + query
        guard let endpoint = components.url else { throw CloudError.message("API URLが不正です") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if authenticated {
            guard let token = TokenVault.read() else { throw CloudError.message("ログインしてください") }
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.message("HTTP応答がありません") }
        guard data.count <= 6 * 1024 * 1024 else { throw CloudError.message("応答サイズが大きすぎます") }
        let parsed = try? JSONSerialization.jsonObject(with: data)
        let wrapper = parsed as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            let detail = wrapper?["message"] as? String ?? wrapper?["error"] as? String ?? "HTTP \(http.statusCode)"
            throw CloudError.message("サーバー: \(detail)")
        }
        guard let dataValue = wrapper?["data"] else { throw CloudError.message("サーバー応答にdataがありません") }
        return dataValue
    }

    private func recordLogin(_ data: [String: Any]) throws {
        guard let token = data["access_token"] as? String, !token.isEmpty,
              let user = data["user"] as? [String: Any],
              let name = user["username"] as? String, !name.isEmpty else {
            throw CloudError.message("ログイン情報が不完全です")
        }
        let ownerKey = "cloudLocalOwner"
        let prior = UserDefaults.standard.string(forKey: ownerKey) ?? ""
        guard prior.isEmpty || prior.caseInsensitiveCompare(name) == .orderedSame else {
            throw CloudError.message("この端末の履歴は別ユーザーに紐づいています。異なるアカウントへのアップロードを防ぐため、ログインできません")
        }
        try TokenVault.save(token)
        if prior.isEmpty { UserDefaults.standard.set(name, forKey: ownerKey) }
        UserDefaults.standard.set(name, forKey: "cloudUsername")
        username = name; signedIn = true
        RDLog.write("Cloud account signed in")
    }

    func login(identifier: String, password: String) async throws {
        let object = try await request("login", method: "POST", body: ["identifier": identifier, "password": password], authenticated: false)
        guard let dictionary = object as? [String: Any] else { throw CloudError.message("ログイン応答が不正です") }
        try recordLogin(dictionary)
        await refreshAvatar()
    }
    func register(username: String, email: String, birthdate: String, password: String) async throws -> String {
        let object = try await request("register", method: "POST", body: [
            "username": username, "email": email, "birthdate": birthdate,
            "password": password, "accept_terms": true], authenticated: false)
        guard let dictionary = object as? [String: Any] else { throw CloudError.message("登録応答が不正です") }
        try recordLogin(dictionary)
        return dictionary["recovery_code"] as? String ?? ""
    }
    func recover(username: String, email: String, birthdate: String,
                 recoveryCode: String, newPassword: String) async throws -> String {
        let object = try await request("recover", method: "POST", body: [
            "username": username, "email": email, "birthdate": birthdate,
            "recovery_code": recoveryCode.components(separatedBy: .whitespacesAndNewlines).joined(),
            "new_password": newPassword], authenticated: false)
        TokenVault.delete(); signedIn = false; self.username = ""; avatarImage = nil
        UserDefaults.standard.removeObject(forKey: "cloudUsername")
        return (object as? [String: Any])?["recovery_code"] as? String ?? ""
    }
    func profile() async throws -> [String: Any] {
        guard let data = try await request("me") as? [String: Any] else { throw CloudError.message("プロフィール取得失敗") }
        return data
    }
    func updateProfile(username: String, email: String, birthdate: String, password: String) async throws {
        guard let data = try await request("profile_update", method: "POST", body: [
            "username": username, "email": email, "birthdate": birthdate, "current_password": password]) as? [String: Any],
              let changed = data["username"] as? String else { throw CloudError.message("変更結果が不正です") }
        self.username = changed
        UserDefaults.standard.set(changed, forKey: "cloudUsername")
        UserDefaults.standard.set(changed, forKey: "cloudLocalOwner")
    }
    func changePassword(current: String, new: String) async throws {
        _ = try await request("password_change", method: "POST", body: ["current_password": current, "new_password": new])
    }
    func logout() async {
        _ = try? await request("logout", method: "POST", body: [:])
        TokenVault.delete(); signedIn = false; username = ""; avatarImage = nil
        UserDefaults.standard.removeObject(forKey: "cloudUsername")
        RDLog.write("Cloud account signed out")
    }
    func syncPush(type: String, items: [[String: Any]]) async throws {
        _ = try await request("sync_push", method: "POST", body: ["schema": 1, "type": type, "items": items])
    }
    func syncPull(type: String, after: Int64) async throws -> [String: Any] {
        guard let dictionary = try await request("sync_pull", query: [
            URLQueryItem(name: "type", value: type), URLQueryItem(name: "after", value: String(after))]) as? [String: Any] else {
            throw CloudError.message("バックアップ応答が不正です")
        }
        return dictionary
    }
    func syncStats() async throws -> [String: Any] {
        guard let dictionary = try await request("sync_stats") as? [String: Any] else { throw CloudError.message("保存件数を取得できません") }
        return dictionary
    }

    func exportCloudCSV() async throws -> Data {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "action", value: "export_csv")]
        guard let endpoint = components.url, let token = TokenVault.read() else { throw CloudError.message("ログインしてください") }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 120
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().hasPrefix("text/csv") else {
            throw CloudError.message("CSVのダウンロードに失敗しました")
        }
        guard data.count <= 50 * 1024 * 1024 else { throw CloudError.message("CSVが50MBを超えています") }
        return data
    }

    func refreshAvatar() async {
        guard let token = TokenVault.read() else { avatarImage = nil; return }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "action", value: "avatar")]
        guard let endpoint = components.url else { return }
        var req = URLRequest(url: endpoint)
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        guard let result = try? await URLSession.shared.data(for: req),
              let http = result.1 as? HTTPURLResponse, http.statusCode == 200,
              result.0.count <= 3 * 1024 * 1024 else { return }
        avatarImage = UIImage(data: result.0)
    }
    func uploadAvatar(jpeg: Data) async throws {
        guard jpeg.count <= 3 * 1024 * 1024, !jpeg.isEmpty else { throw CloudError.message("画像が大きすぎます") }
        guard let token = TokenVault.read() else { throw CloudError.message("ログインしてください") }
        let boundary = "RD" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "action", value: "avatar_upload")]
        guard let endpoint = components.url else { throw CloudError.message("URLが不正です") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 50
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"avatar\"; filename=\"avatar.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw CloudError.message(parsed?["message"] as? String ?? "画像送信に失敗しました")
        }
        await refreshAvatar()
    }
}

@MainActor
enum CloudSync {
    static let types = ["points", "stays", "max_speeds"]
    static func backup(store: TrackStore, client: CloudClient, progress: @escaping (String) -> Void) async throws -> Int {
        var total = 0
        for type in types {
            var cursor: Int64 = 0
            while true {
                let page = try store.cloudPage(type: type, afterID: cursor)
                guard !page.items.isEmpty else { break }
                guard page.next > cursor else { throw CloudError.message("端末のページ送りが進みません") }
                try await client.syncPush(type: type, items: page.items)
                total += page.items.count
                cursor = page.next
                progress("\(type): \(total)件送信")
            }
        }
        if total == 0 { throw CloudError.message("端末にバックアップできる履歴がありません") }
        RDLog.write("Cloud backup completed records=\(total)")
        return total
    }
    static func restore(store: TrackStore, client: CloudClient, progress: @escaping (String) -> Void) async throws -> (Int, Int) {
        var received = 0, added = 0
        for type in types {
            var cursor: Int64 = 0
            while true {
                let page = try await client.syncPull(type: type, after: cursor)
                guard let items = page["items"] as? [[String: Any]],
                      let more = page["has_more"] as? Bool,
                      let next = (page["next_cursor"] as? NSNumber)?.int64Value else {
                    throw CloudError.message("復元応答の形式が不正です")
                }
                guard items.count <= 200 else { throw CloudError.message("サーバーレコード数が上限を超えています") }
                added += try store.importCloudRecords(type, items: items)
                received += items.count
                progress("\(type): \(received)件受信")
                if !more { break }
                guard !items.isEmpty, next > cursor else { throw CloudError.message("復元のページ送りが不正です") }
                cursor = next
            }
        }
        RDLog.write("Cloud restore completed records=\(received)")
        return (received, added)
    }
}
