import Foundation
import SwiftUI

/// 個人情報・位置座標・トークン・パスワードはログに記録しません。
enum RDLog {
    private static let maxBytes = 256 * 1024
    static var logURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RouteDiary", isDirectory: true)
            .appendingPathComponent("diagnostics.log")
    }
    static func write(_ event: String) {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("RouteDiary", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var old = (try? Data(contentsOf: logURL)) ?? Data()
        if old.count > maxBytes { old = Data(old.suffix(maxBytes / 2)) }
        let safe = event.replacingOccurrences(of: "\n", with: " ").prefix(400)
        if let suffix = "\(ISO8601DateFormatter().string(from: Date())) \(safe)\n".data(using: .utf8) {
            old.append(suffix)
            try? old.write(to: logURL, options: .atomic)
        }
    }
    static func read() -> String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "ログはまだありません。" }
    static func clear() { try? FileManager.default.removeItem(at: logURL) }
}

struct DiagnosticsView: View {
    @State private var contents = RDLog.read()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button(rd("更新")) { contents = RDLog.read() }
                    Spacer()
                    ShareLink(item: contents) { Label(rd("共有"), systemImage: "square.and.arrow.up") }
                    Button(rd("消去"), role: .destructive) { RDLog.clear(); contents = RDLog.read() }
                }
                Text(contents).font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Text("位置座標、メールアドレス、パスワード、認証トークンは記録しません。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding()
        }.navigationTitle(rd("ログ・エラー情報"))
    }
}
