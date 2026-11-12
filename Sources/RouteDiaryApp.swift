import SwiftUI

@MainActor
final class AppBootstrap: ObservableObject {
    let model: RouteDiaryModel?
    let errorMessage: String?
    init() {
        do { model = try RouteDiaryModel(); errorMessage = nil }
        catch { model = nil; errorMessage = error.localizedDescription }
    }
}

@main
struct RouteDiaryApp: App {
    @StateObject private var bootstrap = AppBootstrap()
    var body: some Scene {
        WindowGroup {
            if let model = bootstrap.model {
                RootView(model: model)
            } else {
                ContentUnavailableView("起動できません", systemImage: "exclamationmark.triangle",
                                       description: Text(bootstrap.errorMessage ?? "データベースを開けませんでした"))
            }
        }
    }
}
