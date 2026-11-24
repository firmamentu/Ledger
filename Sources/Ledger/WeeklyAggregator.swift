import Foundation

/// M6 周报聚合（纯函数，可单测）。
/// 「新增字节」口径（§14）：Σ(created.size) + Σ(max(0, modified.size_delta))；
/// removed 只作副指标；moved 不产生字节变化。
struct WeeklyReport {
    /// day 0=周一 … 6=周日 → app bundleID（或「未知」）→ 新增字节
    var dayBytes: [Int: [String: Int64]] = [:]
    /// day → category → 新增字节（副图）
    var dayCategoryBytes: [Int: [String: Int64]] = [:]
    var removedBytes: Int64 = 0
    var unknownCount: Int = 0
    var newInstallCount: Int = 0

    var totalNewBytes: Int64 {
        dayBytes.values.reduce(0) { $0 + $1.values.reduce(0, +) }
    }

    /// Top5：按 bundleID 聚合降序。
    var topApps: [(bundleID: String, bytes: Int64)] {
        var totals: [String: Int64] = [:]
        for day in dayBytes.values {
            for (app, bytes) in day { totals[app, default: 0] += bytes }
        }
        return totals.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }
    }
}

enum WeeklyAggregator {
    static let dayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    static func aggregate(
        changes: [(ts: Double, path: String, appBundleID: String?, kind: String, sizeDelta: Int64)],
        newInstallCount: Int,
        calendar: Calendar = .current
    ) -> WeeklyReport {
        var report = WeeklyReport()
        report.newInstallCount = newInstallCount
        report.dayBytes = Dictionary(uniqueKeysWithValues: (0..<7).map { ($0, [String: Int64]()) })
        report.dayCategoryBytes = Dictionary(uniqueKeysWithValues: (0..<7).map { ($0, [String: Int64]()) })

        for change in changes {
            let day = dayIndex(for: Date(timeIntervalSince1970: change.ts), calendar: calendar)
            let app = change.appBundleID ?? "未知"
            let category = change.appBundleID == nil
                ? "unknown"
                : Attribution.category(path: change.path, registrationKind: nil)

            switch change.kind {
            case "created", "modified":
                addBytes(max(0, change.sizeDelta), app: app, category: category, day: day, to: &report)
            case "removed":
                report.removedBytes += max(0, -change.sizeDelta)
            default:
                break  // moved 不产生字节变化
            }

            if change.appBundleID == nil {
                report.unknownCount += 1
            }
        }
        return report
    }

    /// weekday: 1=周日 … 7=周六 → 0=周一 … 6=周日。
    static func dayIndex(for date: Date, calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    private static func addBytes(_ bytes: Int64, app: String, category: String, day: Int, to report: inout WeeklyReport) {
        guard bytes > 0 else { return }
        report.dayBytes[day, default: [:]][app, default: 0] += bytes
        report.dayCategoryBytes[day, default: [:]][category, default: 0] += bytes
    }
}

/// 周报导出（§14：reports/weekly-<date>.md）。
enum WeeklyExporter {
    static func export(report: WeeklyReport, names: [String: String], to directory: URL) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let stamp = formatter.string(from: Date())

        var lines: [String] = []
        lines.append("# Ledger 周报")
        lines.append("")
        lines.append("本周新增总量：\(ByteCountFormatter.string(fromByteCount: report.totalNewBytes, countStyle: .file))")
        lines.append("新装 App 数：\(report.newInstallCount)")
        lines.append("未知项数：\(report.unknownCount)")
        lines.append("移除字节（副指标）：\(ByteCountFormatter.string(fromByteCount: report.removedBytes, countStyle: .file))")
        lines.append("")
        lines.append("## 每日新增")
        lines.append("")
        lines.append("| 日 | 新增字节 |")
        lines.append("|---|---|")
        for day in 0..<7 {
            let bytes = report.dayBytes[day]?.values.reduce(0, +) ?? 0
            lines.append("| \(WeeklyAggregator.dayNames[day]) | \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) |")
        }
        lines.append("")
        lines.append("## Top5")
        lines.append("")
        for app in report.topApps {
            let name = names[app.bundleID] ?? app.bundleID
            lines.append("- \(name)（\(app.bundleID)）：\(ByteCountFormatter.string(fromByteCount: app.bytes, countStyle: .file))")
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("weekly-\(stamp).md")
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
