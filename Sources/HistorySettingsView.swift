import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
    @ObservedObject var model: RouteDiaryModel
    @State private var exporting = false
    @State private var importing = false
    @State private var exportDocument = CSVDocument()
    @State private var confirmDelete = false
    @State private var editingStay: StayRecord?
    @State private var newTitle = ""
    @State private var showImportResult = false
    @State private var importResult = ""

    var body: some View {
        List {
            Section {
                DailyMetricsView(model: model)
            }
            Section(rd("保存済み地点")) {
                if model.points.isEmpty { Text(rd("この日のGPS履歴はありません")).foregroundStyle(.secondary) }
                ForEach(model.points.suffix(200).reversed()) { point in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(point.time.formatted(date: .omitted, time: .standard))
                            .font(.headline)
                        HStack {
                            Text(String(format: "%.6f, %.6f", point.latitude, point.longitude))
                            Spacer()
                            Text(String(format: "%.0fm", point.segment))
                        }.font(.caption).foregroundStyle(.secondary)
                        if point.gap {
                            Label(rd("GPS欠損区間（距離に加算しません）"), systemImage: "exclamationmark.triangle")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
                if model.points.count > 200 { Text(rd("直近200地点まで表示（CSVには全件出力）")).font(.caption) }
            }
            Section(rd("滞在")) {
                if model.stays.isEmpty { Text(rd("この日の滞在記録はありません")).foregroundStyle(.secondary) }
                ForEach(model.stays) { stay in
                    Button {
                        editingStay = stay; newTitle = stay.title
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(stay.title.isEmpty ? "滞在地点" : stay.title).foregroundStyle(.primary)
                                Text(stay.start.formatted(date: .omitted, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(stay.duration.durationLabel)
                        }
                    }
                }
            }
            Section(rd("除外エリア滞在")) {
                if model.zoneVisits.isEmpty { Text(rd("この日の除外エリア滞在はありません")).foregroundStyle(.secondary) }
                ForEach(model.zoneVisits) { visit in
                    HStack { Text(visit.title); Spacer(); Text(visit.duration.durationLabel).foregroundStyle(.secondary) }
                }
            }
            Section(rd("バックアップ・復元")) {
                Button { do {
                    exportDocument = CSVDocument(contents: try CSVBridge.export(store: model.store, date: model.selectedDay))
                    exporting = true
                } catch { model.message = error.localizedDescription } } label: {
                    Label(rd("選択日をCSVへ書き出し"), systemImage: "square.and.arrow.up")
                }
                Button { importing = true } label: {
                    Label(rd("Android版CSVを取り込み"), systemImage: "square.and.arrow.down")
                }
                Button(rd("選択日の履歴を消去"), role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(rd("移動履歴"))
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .commaSeparatedText,
                      defaultFilename: "route_\(model.selectedDay.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))") { result in
            if case .failure(let error) = result { model.message = error.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            do {
                let url = try result.get()
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard !model.recorder.recording else {
                    model.message = "GPS記録を停止してからCSVを取り込んでください"
                    return
                }
                let summary = try CSVBridge.importFile(data: data, into: model.store)
                model.refresh()
                importResult = "追加: \(summary.imported)地点 / 重複: \(summary.skipped)地点。滞在・最高速度も反映しました。"
                showImportResult = true
            } catch { model.message = error.localizedDescription }
        }
        .alert("CSV取り込み完了", isPresented: $showImportResult) {
            Button("OK") { showImportResult = false }
        } message: { Text(importResult) }
        .confirmationDialog("選択日の履歴を削除しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(rd("削除"), role: .destructive) { model.deleteDay() }
        } message: { Text(rd("この操作は元に戻せません。")) }
        .alert("滞在タイトル", isPresented: Binding(get: { editingStay != nil }, set: { if !$0 { editingStay = nil } })) {
            TextField(rd("タイトル"), text: $newTitle)
            Button(rd("保存")) {
                if let stay = editingStay { model.renameStay(stay, title: newTitle) }
                editingStay = nil
            }
            Button(rd("キャンセル"), role: .cancel) { editingStay = nil }
        } message: { Text(rd("滞在地点の表示名を編集します")) }
    }
}

struct SettingsView: View {
    @ObservedObject var model: RouteDiaryModel
    @ObservedObject private var recorder: LocationRecorder
    @AppStorage("recordDistanceM") private var distance: Double = 25
    @AppStorage("intervalSeconds") private var interval: Double = 30
    @AppStorage("staySeconds") private var stay: Double = 60
    @AppStorage("mapSatellite") private var satellite = false
    @AppStorage("recordPinsVisible") private var showPins = true
    @AppStorage("liveMarkerAvatar") private var useAvatar = false
    @AppStorage("appDarkMode") private var dark = false
    @AppStorage("appLanguage") private var language = "ja"
    @State private var confirmEraseAll = false

    init(model: RouteDiaryModel) { self.model = model; self.recorder = model.recorder }

    var body: some View {
        Form {
            Section(rd("GPS記録")) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("\(rd("移動判定距離")): \(Int(distance))m")
                    Slider(value: $distance, in: 5...2000, step: 5)
                }
                Picker(rd("GPS記録間隔（端末や測位状況によって変動）"), selection: $interval) {
                    Text(rd("10秒")).tag(10.0)
                    Text(rd("30秒")).tag(30.0)
                    Text(rd("1分")).tag(60.0)
                    Text(rd("2分")).tag(120.0)
                    Text(rd("5分")).tag(300.0)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("\(rd("滞在判定時間")): \(Int(stay))秒")
                    Slider(value: $stay, in: 10...3600, step: 10)
                }
                Text(rd("iOSはAndroidと違い測位頻度を固定できません。受信したGPS測位の保存間隔を調整します。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(rd("表示設定")) {
                Toggle(rd("衛星写真を使用"), isOn: $satellite)
                Toggle(rd("記録地点のピンを表示"), isOn: $showPins)
                Toggle(rd("現在地にプロフィール画像を表示"), isOn: $useAvatar)
                Toggle(rd("ダークモード"), isOn: $dark)
                Picker(rd("言語 / Language / 语言"), selection: $language) {
                    Text(rd("日本語")).tag("ja")
                    Text("English").tag("en")
                    Text(rd("简体中文")).tag("zh")
                }
                NavigationLink(destination: DashboardCustomizeView()) {
                    Label(rd("カスタム画面"), systemImage: "rectangle.3.group")
                }
            }
            Section(rd("位置情報")) {
                Text(recorder.status).font(.caption)
                if let point = recorder.currentLocation {
                    Text(String(format: "現在地: %.6f, %.6f / 精度 %.0fm", point.coordinate.latitude,
                                point.coordinate.longitude, point.horizontalAccuracy)).font(.caption)
                }
                Button(rd("現在地を再取得")) { recorder.requestOneShotLocation() }
                Text(rd("iOSがアプリを強制終了した場合、Androidの前景サービスのような連続GPS記録は保証されません。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(rd("アカウント")) {
                NavigationLink(rd("アカウント・プロフィール")) { AccountView() }
                NavigationLink(rd("クラウドバックアップ")) { CloudBackupView(model: model) }
            }
            Section(rd("アプリ情報")) {
                NavigationLink(rd("ログ・エラー情報")) { DiagnosticsView() }
                NavigationLink(rd("バージョン情報")) { VersionInfoView() }
                NavigationLink(rd("アプリの更新を確認")) { VersionInfoView() }
            }
            Section(rd("ローカルデータ")) {
                Button(rd("すべての履歴を削除"), role: .destructive) { confirmEraseAll = true }
                Text(rd("除外エリアの設定は保持します。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(rd("設定"))
        .confirmationDialog("全移動履歴を削除しますか？", isPresented: $confirmEraseAll, titleVisibility: .visible) {
            Button(rd("すべて削除"), role: .destructive) { model.deleteAll() }
        } message: { Text(rd("復元できないため、先にCSVを書き出してください。")) }
    }
}

struct VersionInfoView: View {
    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2"
    }
    var body: some View {
        Form {
            Section("RouteDiary iOS") {
                LabeledContent("iOS版", value: currentVersion)
                LabeledContent("移植元", value: "Android v2.11")
                Text("SwiftUI / CoreLocation / MapKit / SQLite / HTTPS API")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section(rd("IPAの更新")) {
                Text(rd("GitHub Actionsで最新のIPAをビルドし、Sideloadlyで同じApple AccountとBundle IDを使用して再署名・上書きインストールしてください。端末内の履歴を保持するため、アプリをアンインストールしないでください。"))
                    .font(.footnote)
                Text(rd("無料署名は通常7日ごとに再署名が必要です。iOSはAndroidのAPK自動更新機能に対応しません。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(rd("バージョン情報"))
    }
}
