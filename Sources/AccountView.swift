import SwiftUI
import PhotosUI
import UIKit

private enum AccountPage: String {
    case home, login, register, recover, profile, password
}

struct AccountView: View {
    @EnvironmentObject private var cloud: CloudClient
    @Environment(\.dismiss) private var dismiss
    @State private var page: AccountPage = .home
    @State private var busy = false
    @State private var error: String?
    @State private var notification = ""
    @State private var userID = ""
    @State private var email = ""
    @State private var birthdate = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var oldPassword = ""
    @State private var recovery = ""
    @State private var consent = false
    @State private var recoveryResult: String?
    @State private var recoverySaved = false
    @State private var avatarPicker: PhotosPickerItem?
    @State private var pendingAvatar: Data?
    @State private var selectedCropImage: UIImage?
    @State private var showingCrop = false

    var body: some View {
        NavigationStack {
            Form {
                if let code = recoveryResult {
                    Section(rd("復旧コード（この画面で一度だけ表示）")) {
                        Text(rd("このコードを安全な場所へ保存してください。紛失するとパスワードの復旧ができません。"))
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(code.isEmpty ? "サーバーから復旧コードが返されませんでした" : code)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Toggle("復旧コードを保存しました", isOn: $recoverySaved)
                        Button(rd("次へ")) {
                            recoveryResult = nil; recoverySaved = false; page = .home
                            clearSecrets()
                        }.disabled(!recoverySaved)
                    }
                } else {
                    switch page {
                    case .home: homeContent
                    case .login: loginContent
                    case .register: registerContent
                    case .recover: recoverContent
                    case .profile: profileContent
                    case .password: passwordContent
                    }
                }
                if busy { Section { ProgressView("通信中…") } }
                if !notification.isEmpty {
                    Section { Text(notification).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(rd("アカウント"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(rd("戻る")) {
                        if page == .home { dismiss() }
                        else { page = .home; clearSecrets() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if page == .home { Button(rd("閉じる")) { dismiss() } }
                }
            }
            .onChange(of: avatarPicker) { _, next in
                guard let next else { return }
                Task { await selectAvatar(next) }
            }
            .alert("RouteDiary", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("OK") { error = nil }
                } message: { Text(error ?? "") }
            .task { if cloud.signedIn { await cloud.refreshAvatar() } }
            .sheet(isPresented: $showingCrop) {
                if let selectedCropImage {
                    AvatarCropView(image: selectedCropImage) { jpeg in
                        pendingAvatar = jpeg
                        if cloud.signedIn {
                            run { try await cloud.uploadAvatar(jpeg: jpeg); notification = "プロフィール画像を更新しました" }
                        } else { notification = "登録時に使用するアイコン画像を選択しました" }
                    }
                }
            }
        }
    }

    @ViewBuilder private var homeContent: some View {
        if cloud.signedIn {
            Section {
                HStack(spacing: 14) {
                    avatarView(size: 65)
                    VStack(alignment: .leading) {
                        Text(rd("ログイン中")).font(.caption).foregroundStyle(.secondary)
                        Text(cloud.username).font(.headline)
                    }
                }
                PhotosPicker(selection: $avatarPicker, matching: .images) {
                    Label(rd("プロフィール画像を変更"), systemImage: "person.crop.circle")
                }
                Text(rd("画像は中央の正方形を切り出して送信します（最大512px）。"))
                    .font(.caption2).foregroundStyle(.secondary)
                Button(rd("プロフィール・個人情報を変更")) { page = .profile; Task { await loadProfile() } }
                Button(rd("パスワードを変更")) { page = .password }
                Button(rd("ログアウト"), role: .destructive) {
                    run { await cloud.logout(); notification = "ログアウトしました" }
                }
            }
        } else {
            Section {
                Button(rd("ログイン")) { page = .login }
                Button(rd("パスワードを忘れた場合")) { page = .recover }
                Button(rd("新規会員登録")) { page = .register }
            }
        }
        Section {
            NavigationLink(destination: DashboardCustomizeView()) {
                Label(rd("カスタム画面"), systemImage: "rectangle.3.group")
            }
            Text(rd("カスタム画面はログインしなくても使用できます。"))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var loginContent: some View {
        Section(rd("ログイン")) {
            TextField(rd("ユーザーID または メールアドレス"), text: $userID)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField(rd("パスワード"), text: $password)
                .textContentType(.password)
            Button(rd("ログイン")) {
                run {
                    try await cloud.login(identifier: userID.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
                    clearSecrets(); page = .home
                }
            }.disabled(userID.isEmpty || password.isEmpty || busy)
        }
    }

    @ViewBuilder private var registerContent: some View {
        Section(rd("新規会員登録")) {
            Text(rd("18歳以上であることが必要です。登録時に復旧コードが一度だけ表示されます。"))
                .font(.footnote).foregroundStyle(.secondary)
            TextField(rd("ユーザーID（3～32文字）"), text: $userID).textInputAutocapitalization(.never)
            TextField(rd("メールアドレス"), text: $email).textContentType(.emailAddress)
                .keyboardType(.emailAddress).textInputAutocapitalization(.never)
            TextField(rd("生年月日 YYYY-MM-DD"), text: $birthdate).keyboardType(.numbersAndPunctuation)
            SecureField(rd("パスワード（12文字以上）"), text: $password)
            SecureField(rd("パスワード確認"), text: $confirmPassword)
            PhotosPicker(selection: $avatarPicker, matching: .images) {
                Label(pendingAvatar == nil ? "任意のアイコン画像を選択" : "アイコン画像を変更", systemImage: "photo")
            }
            Toggle("18歳以上であること、オンラインの位置履歴保存に同意します", isOn: $consent)
            Button(rd("登録する")) {
                guard password == confirmPassword, password.count >= 12 else {
                    error = "パスワードが一致しないか、12文字未満です"; return
                }
                guard consent else { error = "年齢とオンライン保存への同意が必要です"; return }
                run {
                    let code = try await cloud.register(username: userID.trimmingCharacters(in: .whitespacesAndNewlines),
                         email: email, birthdate: birthdate, password: password)
                    if let jpeg = pendingAvatar {
                        do { try await cloud.uploadAvatar(jpeg: jpeg) }
                        catch { notification = "アイコン画像の送信に失敗しました。後から再登録できます。" }
                    }
                    clearSecrets(); recoveryResult = code
                }
            }.disabled(userID.isEmpty || email.isEmpty || birthdate.isEmpty || password.isEmpty || busy)
        }
    }

    @ViewBuilder private var recoverContent: some View {
        Section(rd("パスワード再設定")) {
            Text(rd("登録したID、メール、生年月日、登録時に保存した復旧コードが必要です。"))
                .font(.footnote).foregroundStyle(.secondary)
            TextField(rd("登録ユーザーID"), text: $userID).textInputAutocapitalization(.never)
            TextField(rd("登録メールアドレス"), text: $email).keyboardType(.emailAddress)
            TextField(rd("生年月日 YYYY-MM-DD"), text: $birthdate).keyboardType(.numbersAndPunctuation)
            TextField(rd("復旧コード"), text: $recovery).textInputAutocapitalization(.never)
            SecureField(rd("新しいパスワード"), text: $password)
            SecureField(rd("パスワード確認"), text: $confirmPassword)
            Button(rd("パスワードを再設定")) {
                guard password == confirmPassword, password.count >= 12 else { error = "新しいパスワードを確認してください（12文字以上）"; return }
                run {
                    let code = try await cloud.recover(username: userID, email: email, birthdate: birthdate,
                        recoveryCode: recovery, newPassword: password)
                    clearSecrets(); recoveryResult = code
                }
            }.disabled(userID.isEmpty || email.isEmpty || birthdate.isEmpty || recovery.isEmpty || busy)
        }
    }

    @ViewBuilder private var profileContent: some View {
        Section(rd("プロフィール・個人情報の変更")) {
            TextField(rd("ユーザーID"), text: $userID).textInputAutocapitalization(.never)
            TextField(rd("メールアドレス"), text: $email).textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
            TextField(rd("生年月日 YYYY-MM-DD"), text: $birthdate).keyboardType(.numbersAndPunctuation)
            SecureField(rd("現在のパスワード（本人確認用）"), text: $oldPassword)
            Button(rd("変更を保存")) {
                run {
                    try await cloud.updateProfile(username: userID, email: email, birthdate: birthdate, password: oldPassword)
                    oldPassword = ""; page = .home; notification = "プロフィールを更新しました"
                }
            }.disabled(userID.isEmpty || email.isEmpty || birthdate.isEmpty || oldPassword.isEmpty || busy)
        }
    }

    @ViewBuilder private var passwordContent: some View {
        Section(rd("パスワード変更")) {
            SecureField(rd("現在のパスワード"), text: $oldPassword)
            SecureField(rd("新しいパスワード（12文字以上）"), text: $password)
            SecureField(rd("新しいパスワードの確認"), text: $confirmPassword)
            Button(rd("パスワードを変更")) {
                guard password.count >= 12, password == confirmPassword else { error = "新しいパスワードを確認してください"; return }
                run {
                    try await cloud.changePassword(current: oldPassword, new: password)
                    clearSecrets(); page = .home; notification = "パスワードを更新しました"
                }
            }.disabled(oldPassword.isEmpty || password.isEmpty || busy)
        }
    }

    @ViewBuilder private func avatarView(size: CGFloat) -> some View {
        if let image = cloud.avatarImage {
            Image(uiImage: image).resizable().scaledToFill().frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable().foregroundStyle(.secondary).frame(width: size, height: size)
        }
    }
    private func clearSecrets() { password = ""; confirmPassword = ""; oldPassword = ""; recovery = "" }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; notification = ""
        Task { @MainActor in
            defer { busy = false }
            do { try await action() }
            catch { RDLog.write("Cloud account operation failed"); self.error = error.localizedDescription }
        }
    }
    private func loadProfile() async {
        do {
            let profile = try await cloud.profile()
            userID = profile["username"] as? String ?? cloud.username
            email = profile["email"] as? String ?? ""
            birthdate = profile["birthdate"] as? String ?? ""
        } catch { self.error = error.localizedDescription }
    }
    private func selectAvatar(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              data.count < 12 * 1024 * 1024, let image = UIImage(data: data) else {
            error = "画像を読み込めません（12MB以下を選んでください）"; return
        }
        selectedCropImage = image
        showingCrop = true
    }
}
