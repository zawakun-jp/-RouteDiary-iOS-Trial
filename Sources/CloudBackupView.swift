import SwiftUI
import UniformTypeIdentifiers

struct CloudBackupView: View {
    @ObservedObject var model: RouteDiaryModel
    @EnvironmentObject private var cloud: CloudClient
    @State private var busy = false
    @State private var progress = ""
    @State private var stats = ""
    @State private var error: String?
    @State private var showBackupConfirm = false
    @State private var showRestoreConfirm = false
    @State private var exportDocument = CSVDocument()
    @State private var exporting = false

    var body: some View {
        Form {
            Section(rd("クラウドバックアップ")) {
                Text(rd("MySQLにGPS地点・滞在・日別最高速度の構造化データを保存します。CSVファイルそのものは送信しません。除外エリア設定と画面設定はバックアップ対象外です。"))
                    .font(.footnote).foregroundStyle(.secondary)
                if cloud.signedIn {
                    LabeledContent("ログイン中", value: cloud.username)
                    Button(rd("全履歴をクラウドへバックアップ")) { showBackupConfirm = true }
                        .disabled(busy)
                    Button(rd("クラウドから全履歴を復元")) { showRestoreConfirm = true }
                        .disabled(busy)
                    Button(rd("クラウドの全日分をCSVで書き出す")) {
                        perform {
                            let data = try await cloud.exportCloudCSV()
                            guard let text = String(data: data, encoding: .utf8) else {
                                throw CloudError.message("CSVをUTF-8で読み込めません")
                            }
                            exportDocument = CSVDocument(contents: text)
                            exporting = true
                        }
                    }.disabled(busy)
                    Button(rd("クラウド保存件数を更新")) { Task { await loadStats() } }
                        .disabled(busy)
                    if !stats.isEmpty { Text(stats).font(.footnote) }
                } else {
                    Text(rd("クラウドの利用にはアカウントへのログインが必要です。アカウント画面からログインしてください。"))
                        .foregroundStyle(.secondary)
                    NavigationLink("アカウントを開く") { AccountView() }
                }
            }
            if busy {
                Section(rd("処理中")) {
                    ProgressView()
                    Text(progress).font(.caption)
                }
            } else if !progress.isEmpty {
                Section(rd("処理結果")) { Text(progress).font(.footnote) }
            }
        }
        .navigationTitle(rd("クラウド"))
        .confirmationDialog("端末内のすべての履歴をバックアップしますか？", isPresented: $showBackupConfirm, titleVisibility: .visible) {
            Button(rd("バックアップする")) {
                perform {
                    let count = try await CloudSync.backup(store: model.store, client: cloud) { progress = $0 }
                    progress = "バックアップ完了：\(count)件。端末内の履歴は削除していません。"
                    await loadStats()
                }
            }
        } message: { Text("アカウント \(cloud.username) に送信します。") }
        .confirmationDialog("クラウドの履歴を復元しますか？", isPresented: $showRestoreConfirm, titleVisibility: .visible) {
            Button(rd("復元する")) {
                guard !model.recorder.recording else { error = "GPS記録を停止してから復元してください"; return }
                perform {
                    let result = try await CloudSync.restore(store: model.store, client: cloud) { progress = $0 }
                    model.refresh()
                    progress = "復元完了：受信 \(result.0)件、追加地点 \(result.1)件。既存データは保持しています。"
                }
            }
        } message: { Text(rd("既存の履歴は削除せず、同じ地点は重複登録しません。")) }
        .fileExporter(isPresented: $exporting, document: exportDocument,
                      contentType: .commaSeparatedText, defaultFilename: "RouteDiary-Cloud-AllDates") { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
        .alert("RouteDiary", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .task { if cloud.signedIn { await loadStats() } }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; progress = "通信中…"
        Task { @MainActor in
            defer { busy = false }
            do { try await operation() }
            catch { self.error = error.localizedDescription; progress = "処理に失敗しました"; RDLog.write("Cloud backup operation failed") }
        }
    }
    private func loadStats() async {
        do {
            let result = try await cloud.syncStats()
            let points = (result["points"] as? NSNumber)?.intValue ?? 0
            let stays = (result["stays"] as? NSNumber)?.intValue ?? 0
            let maxSpeeds = (result["max_speeds"] as? NSNumber)?.intValue ?? 0
            stats = "クラウド保存件数：地点 \(points) / 滞在 \(stays) / 最高速度 \(maxSpeeds)"
        } catch { stats = "保存件数の取得に失敗：\(error.localizedDescription)" }
    }
}
