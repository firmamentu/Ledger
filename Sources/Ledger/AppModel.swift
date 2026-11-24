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
    @Published var residualSheetApp: Database.AppSummary?
    @Published var cleanupReport: CleanupReport?
    @Published var weekly: WeeklyReport?
    @Published var weeklyExportPath: String?
    @Published var paused = false  // 菜单栏同步用（设置页直接走 SettingsService）
    @Published var dailyChanges: [(path: String, appBundleID: String?, kind: String, sizeDelta: Int64)] = []
    @Published var addAppMessage: String?
    @Published var historyEvents: [(ts: Double, bundleID: String, name: String?, kind: String, detail: String)] = []
    @Published var historyReports: [HistoryReport] = []

    struct HistoryReport: Identifiable {
        var id = UUID()
        var date: Date
        var kind: String
        var trashedCount: Int
        var reportPath: String?
    }

    /// 手动添加 App（识别轨）。
    var onAddApp: ((String, @escaping (String) -> Void) -> Void)?
    /// 重新追踪（settled/verified → tracked）。
    var onResumeTracking: ((String) -> Void)?

    /// 待处理 = vanished + broken（appSummaries 已按足迹降序）。
    var pendingApps: [Database.AppSummary] {
        apps.filter { $0.state == "vanished" || $0.state == "broken" }
    }

    /// 「只是移动了它？」动作（AppDelegate 接线到 VanishService）。
    var onMarkAsMoved: ((String) -> Void)?
    /// 执行清理（AppDelegate 接线到 CleanupService）。
    var onCleanup: ((String, [String], String) -> Void)?
    /// 明确选择保留（AppDelegate 接线到 CleanupService：→ settled）。
    var onKeep: ((String) -> Void)?

    /// 打开残留清单。不改变状态（打开即转 verified 会导致「看一眼就撤下待处理」，
    /// 用户无法自由关闭、尝试性删除后无法再查看——按用户反馈移除该转移，见 devlog）。
    func openResiduals(_ app: Database.AppSummary) {
        residualSheetApp = app
    }

    /// 后台线程 → 主线程更新 UI 状态。
    func publish(_ update: @escaping (AppModel) -> Void) {
        DispatchQueue.main.async { update(self) }
    }

    /// 主线程刷新 App 概览（记账落库后与打开窗口时调用）。
    func refreshApps(database: Database) {
        apps = (try? database.appSummaries()) ?? []
        hasPending = apps.contains { $0.state == "vanished" || $0.state == "broken" }
    }

    /// 加载本周周报（周报 Tab onAppear 调用）。
    func loadWeekly(database: Database) {
        DispatchQueue.global(qos: .userInitiated).async {
            let calendar = Calendar.current
            let now = Date()
            let offset = (calendar.component(.weekday, from: now) + 5) % 7
            let monday = calendar.startOfDay(
                for: calendar.date(byAdding: .day, value: -offset, to: now) ?? now
            )
            let end = calendar.date(byAdding: .day, value: 7, to: monday) ?? now

            let changes = (try? database.weeklyChanges(
                start: monday.timeIntervalSince1970, end: end.timeIntervalSince1970
            )) ?? []
            let installs = (try? database.manifestCount(
                start: monday.timeIntervalSince1970, end: end.timeIntervalSince1970
            )) ?? 0
            let report = WeeklyAggregator.aggregate(
                changes: changes, newInstallCount: installs, calendar: calendar
            )
            let names = Dictionary(uniqueKeysWithValues:
                ((try? database.appSummaries()) ?? []).map { ($0.bundleID, $0.name) })

            // 今日明细（日报）：今天 0 点至今的变化，按字节影响降序
            let todayStart = calendar.startOfDay(for: now)
            let todayRows = ((try? database.weeklyChanges(
                start: todayStart.timeIntervalSince1970, end: now.timeIntervalSince1970
            )) ?? []).sorted { abs($0.sizeDelta) > abs($1.sizeDelta) }
            let today = todayRows.map { (path: $0.path, appBundleID: $0.appBundleID, kind: $0.kind, sizeDelta: $0.sizeDelta) }

            DispatchQueue.main.async {
                self.weekly = report
                self.weeklyAppNames = names
                self.dailyChanges = today
            }
        }
    }

    @Published var weeklyAppNames: [String: String] = [:]

    /// 加载操作历史（待处理页「历史」分区）。
    func loadHistory(database: Database) {
        DispatchQueue.global(qos: .userInitiated).async {
            let events = (try? database.appEventsHistory(limit: 200)) ?? []
            let reports = (try? database.reportsList(limit: 50)) ?? []
            let parsed: [HistoryReport] = reports.compactMap { row in
                guard let data = row.contentJSON.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let trashed = json["trashed"] as? [[String: Any]] else {
                    return nil
                }
                return HistoryReport(
                    date: Date(timeIntervalSince1970: row.createdAt),
                    kind: row.kind,
                    trashedCount: trashed.count,
                    reportPath: json["report_path"] as? String
                )
            }
            DispatchQueue.main.async {
                self.historyEvents = events
                self.historyReports = parsed
            }
        }
    }

    /// 今日新增字节（概览指标，§14 口径）。
    var todayNewBytes: Int64 {
        guard let weekly else { return 0 }
        let today = WeeklyAggregator.dayIndex(for: Date(), calendar: .current)
        return weekly.dayBytes[today]?.values.reduce(0, +) ?? 0
    }

    /// 未知项数（本周未归属 changes，§14 概览）。
    var unknownCount: Int {
        weekly?.unknownCount ?? 0
    }
}

extension Database.AppSummary: Identifiable {
    public var id: String { bundleID }
}
