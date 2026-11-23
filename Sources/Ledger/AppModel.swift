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

    /// 后台线程 → 主线程更新 UI 状态。
    func publish(_ update: @escaping (AppModel) -> Void) {
        DispatchQueue.main.async { update(self) }
    }
}
