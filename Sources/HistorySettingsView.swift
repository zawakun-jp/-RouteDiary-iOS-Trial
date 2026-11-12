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
            Section("保存済み地点") {
                if model.points.isEmpty { Text("この日のGPS履歴はありません").foregroundStyle(.secondary) }
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
                            Label("GPS欠損区間（距離に加算しません）", systemImage: "exclamationmark.triangle")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
                if model.points.count > 200 { Text("直近200地点まで表示（CSVには全件出力）").font(.caption) }
            }
            Section("滞在") {
                if model.stays.isEmpty { Text("この日の滞在記録はありません").foregroundStyle(.secondary) }
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
            Section("除外エリア滞在") {
                if model.zoneVisits.isEmpty { Text("この日の除外エリア滞在はありません").foregroundStyle(.secondary) }
                ForEach(model.zoneVisits) { visit in
                    HStack { Text(visit.title); Spacer(); Text(visit.duration.durationLabel).foregroundStyle(.secondary) }
                }
            }
            Section("バックアップ・復元") {
                Button { do {
                    exportDocument = CSVDocument(contents: try CSVBridge.export(store: model.store, date: model.selectedDay))
                    exporting = true
                } catch { model.message = error.localizedDescription } } label: {
                    Label("選択日をCSVへ書き出し", systemImage: "square.and.arrow.up")
                }
                Button { importing = true } label: {
                    Label("Android版CSVを取り込み", systemImage: "square.and.arrow.down")
                }
                Button("選択日の履歴を消去", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle("移動履歴")
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
            Button("削除", role: .destructive) { model.deleteDay() }
        } message: { Text("この操作は元に戻せません。") }
        .alert("滞在タイトル", isPresented: Binding(get: { editingStay != nil }, set: { if !$0 { editingStay = nil } })) {
            TextField("タイトル", text: $newTitle)
            Button("保存") {
                if let stay = editingStay { model.renameStay(stay, title: newTitle) }
                editingStay = nil
            }
            Button("キャンセル", role: .cancel) { editingStay = nil }
        } message: { Text("滞在地点の表示名を編集します") }
    }
}

struct SettingsView: View {
    @ObservedObject var model: RouteDiaryModel
    @ObservedObject private var recorder: LocationRecorder
    @AppStorage("recordDistanceM") private var distance: Double = 25
    @AppStorage("intervalSeconds") private var interval: Double = 30
    @AppStorage("staySeconds") private var stay: Double = 60
    @AppStorage("mapSatellite") private var satellite = false
    @State private var confirmEraseAll = false

    init(model: RouteDiaryModel) {
        self.model = model; self.recorder = model.recorder
    }
    var body: some View {
        Form {
            Section("GPS記録") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("移動判定距離: \(Int(distance))m")
                    Slider(value: $distance, in: 5...200, step: 5)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("最短保存間隔: \(Int(interval))秒")
                    Slider(value: $interval, in: 10...300, step: 5)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("滞在判定時間: \(Int(stay))秒")
                    Slider(value: $stay, in: 30...600, step: 10)
                }
                Text("iOSは測位頻度を完全に固定できません。届いた新しいGPS測位をこの設定で間引きます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("地図") {
                Toggle("衛星写真を使用", isOn: $satellite)
            }
            Section("位置情報") {
                Text(recorder.status).font(.caption)
                if let point = recorder.currentLocation {
                    Text(String(format: "現在地: %.6f, %.6f / 精度 %.0fm", point.coordinate.latitude,
                                point.coordinate.longitude, point.horizontalAccuracy)).font(.caption)
                }
                Button("現在地を再取得") { recorder.requestOneShotLocation() }
                Text("バックグラウンド記録はiOSの制御を受けます。強制終了後の連続GPS記録は保証されません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("ローカルデータ") {
                Button("すべての履歴を削除", role: .destructive) { confirmEraseAll = true }
                Text("記録除外エリアの設定は維持します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("試験版について") {
                LabeledContent("アプリ", value: "RouteDiary iOS Trial")
                LabeledContent("バージョン", value: "0.1")
                Text("Android v2.11の移植試験。会員登録・MySQL同期・オンライン更新・多言語画面は未実装です。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("設定")
        .confirmationDialog("全移動履歴を削除しますか？", isPresented: $confirmEraseAll, titleVisibility: .visible) {
            Button("すべて削除", role: .destructive) { model.deleteAll() }
        } message: { Text("復元できないため、先にCSVを書き出してください。") }
    }
}
