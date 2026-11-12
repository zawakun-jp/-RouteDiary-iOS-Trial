import Foundation
import SwiftUI

/// Android v2.11 の i18n_en / i18n_zh と同じ日本語キー辞書を利用。
/// SwiftUI の @AppStorage 変更で View が再描画されると翻訳が反映されます。
enum RDI18n {
    private static let english = load("i18n_en")
    private static let chinese = load("i18n_zh")

    private static func load(_ name: String) -> [String: String] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return value
    }

    static func translate(_ japanese: String) -> String {
        let language = UserDefaults.standard.string(forKey: "appLanguage") ?? "ja"
        switch language {
        case "en": return english[japanese] ?? overridesEN[japanese] ?? japanese
        case "zh": return chinese[japanese] ?? overridesZH[japanese] ?? japanese
        default: return japanese
        }
    }

    private static let overridesEN: [String: String] = [
        "地図": "Map", "履歴": "History", "除外": "Private zones", "設定": "Settings",
        "クラウド": "Cloud", "記録中": "Recording", "停止中": "Stopped", "今日": "Today",
        "ログイン": "Sign in", "アカウント": "Account", "保存": "Save", "キャンセル": "Cancel",
        "戻る": "Back", "記録開始": "Start recording", "記録停止": "Stop recording",
        "カスタム画面": "Customize dashboard", "ログ・エラー情報": "Diagnostics"
    ]
    private static let overridesZH: [String: String] = [
        "地図": "地图", "履歴": "历史", "除外": "排除区域", "設定": "设置",
        "クラウド": "云端", "記録中": "记录中", "停止中": "已停止", "今日": "今天",
        "ログイン": "登录", "アカウント": "账户", "保存": "保存", "キャンセル": "取消",
        "戻る": "返回", "記録開始": "开始记录", "記録停止": "停止记录",
        "カスタム画面": "自定义仪表板", "ログ・エラー情報": "日志与错误"
    ]
}

func rd(_ text: String) -> String { RDI18n.translate(text) }

struct DashboardEntry: Identifiable, Codable, Equatable {
    var id: String
    var visible: Bool
}

@MainActor
final class DashboardSettings: ObservableObject {
    static let defaults = ["points", "distance", "peak", "stay", "current_stay", "zone_total"]
    @Published var entries: [DashboardEntry] {
        didSet { persist() }
    }
    init() {
        let stored: [DashboardEntry]
        if let raw = UserDefaults.standard.data(forKey: "dashboardEntries"),
           let decoded = try? JSONDecoder().decode([DashboardEntry].self, from: raw) { stored = decoded }
        else { stored = [] }
        var result: [DashboardEntry] = []
        for item in stored where Self.defaults.contains(item.id) && !result.contains(where: { $0.id == item.id }) {
            result.append(item)
        }
        for key in Self.defaults where !result.contains(where: { $0.id == key }) {
            result.append(DashboardEntry(id: key, visible: true))
        }
        entries = result
    }
    func reset() { entries = Self.defaults.map { DashboardEntry(id: $0, visible: true) } }
    func move(from: IndexSet, to: Int) { entries.move(fromOffsets: from, toOffset: to) }
    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: "dashboardEntries") }
    }
    static func label(_ id: String) -> String {
        let names: [String: String] = [
            "points": "記録地点数", "distance": "移動距離", "peak": "最高速度",
            "stay": "滞在", "current_stay": "今回の滞在", "zone_total": "除外エリアの滞在合計"
        ]
        return rd(names[id] ?? id)
    }
}

struct DashboardCustomizeView: View {
    @EnvironmentObject private var dashboard: DashboardSettings
    var body: some View {
        List {
            Section {
                ForEach($dashboard.entries) { $entry in
                    Toggle(DashboardSettings.label(entry.id), isOn: $entry.visible)
                }
                .onMove(perform: dashboard.move)
            } header: { Text(rd("カスタム画面")) }
              footer: { Text(rd("右側で表示・非表示を選択できます。左の≡で並べ替えできます。")) }
            Section {
                Button(rd("初期配置に戻す")) { dashboard.reset() }
            }
        }
        .navigationTitle(rd("カスタム画面"))
        .toolbar { EditButton() }
        .environment(\.editMode, .constant(.active))
    }
}
