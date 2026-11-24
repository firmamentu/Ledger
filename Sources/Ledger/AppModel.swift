import Foundation

/// UI 状态（仅主线程更新，后台通过 `publish` 转回主线程）。
final class AppModel: ObservableObject {
    enum ScanState {
        case idle
        case scanning
        case ready
    }

    @Published var scanState: ScanState = .idle
    @Published var scannedCount: Int = 0
    @Published var indexCount: Int = 0
    @Published var blindSpots: [String] = []
    @Published var eventsProcessed: Int = 0
    @Published var lastFlushAt: Date?
    @Published var apps: [Database.AppSummary] = []
    @Published var hasPending = false

    /// 待处理 = vanished + broken（appSummaries 已按足迹降序）。
    var pendingApps: [Database.AppSummary] {
        apps.filter { $0.state == "vanished" || $0.state == "broken" }
    }

    /// 「只是移动了它？」动作（AppDelegate 接线到 VanishService）。
    var onMarkAsMoved: ((String) -> Void)?

    /// 后台线程 → 主线程更新 UI 状态。
    func publish(_ update: @escaping (AppModel) -> Void) {
        DispatchQueue.main.async { update(self) }
    }

    /// 主线程刷新 App 概览（记账落库后与打开窗口时调用）。
    func refreshApps(database: Database) {
        apps = (try? database.appSummaries()) ?? []
        hasPending = apps.contains { $0.state == "vanished" || $0.state == "broken" }
    }
}
