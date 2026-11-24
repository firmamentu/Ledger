import Foundation
import os

/// M5 清理执行（§10.5 / §6 ⑤⑥⑦）与状态转移（§7 verified/settled）。
/// 唯一删除动作 = FileManager.trashItem；逐项执行，删除前再次校验 size/inode，
/// 不一致或已消失 → 跳过并记录，不中断整体。
struct CleanupReport {
    var bundleID: String
    var appName: String
    var trashed: [(path: String, size: Int64)] = []
    var skipped: [(path: String, reason: String)] = []
    var kept: [(path: String, reason: String)] = []
    var reportPath: String?
}

/// 报告类别标题兜底（知识库不可用时）。
enum ReportPresentation {
    static func categoryTitle(_ category: String) -> String {
        switch category {
        case "cache": return "应用缓存"
        case "log": return "日志"
        case "preference": return "偏好设置"
        case "app_data": return "应用数据"
        case "registration": return "注册项"
        default: return "其他"
        }
    }
}

final class CleanupService {
    private let logger = Logger(subsystem: AppPaths.bundleID, category: "cleanup")
    private let database: Database
    private let model: AppModel
    private let supportDirectory: URL
    private let queue = DispatchQueue(label: "com.ledger.app.cleanup", qos: .utility)

    init(database: Database, model: AppModel, supportDirectory: URL = AppPaths.supportDirectory) {
        self.database = database
        self.model = model
        self.supportDirectory = supportDirectory
    }

    /// §7 verified → settled：用户明确选择「保留」。
    /// （打开清单不再转 verified：该转移让「看一眼」就撤下待处理且无法自由关闭，
    /// 按用户反馈移除，见 devlog；状态只由清理完成或明确保留推进到 settled。）
    func keep(_ bundleID: String) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.database.setAppState(bundleID: bundleID, state: "settled")
                try self.database.insertAppEvent(
                    ts: Date().timeIntervalSince1970, bundleID: bundleID,
                    kind: "settled", detail: "kept_by_choice"
                )
                self.refreshUI()
            } catch {
                self.logger.error("settled 落库失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// §6 ⑥⑦：逐项移入废纸篓 → 报告落库 + 导出 Markdown → settled。
    func cleanup(bundleID: String, checkedPaths: [String], appName: String) {
        queue.async { [weak self] in
            guard let self else { return }
            var report = CleanupReport(bundleID: bundleID, appName: appName)

            guard let rows = try? self.database.manifestItems(for: bundleID) else {
                // 清单读取失败：不清不 settled，待处理条目保留
                self.logger.error("残留清单读取失败，取消清理：\(bundleID, privacy: .public)")
                self.refreshUI()
                return
            }
            defer { self.finishCleanup(report) }  // 值捕获：退出时用最终状态
            let byPath = Dictionary(uniqueKeysWithValues: rows.map { ($0.path, $0) })
            report.kept = rows.compactMap { row in
                checkedPaths.contains(row.path) ? nil
                    : (row.path, row.registrationKind != nil || row.requiresAdmin ? "系统项，不代执行" : "未勾选")
            }

            // 文件先、目录按深度降序，避免目录连带子项导致二次 trash 失败
            let ordered = checkedPaths.sorted { a, b in
                let aDir = self.isDirectory(a), bDir = self.isDirectory(b)
                if aDir != bDir { return !aDir }
                return a.split(separator: "/").count > b.split(separator: "/").count
            }

            for path in ordered {
                guard let row = byPath[path], row.registrationKind == nil else {
                    report.skipped.append((path, "注册项或已无记录"))
                    continue
                }
                var st = stat()
                guard lstat(path, &st) == 0 else {
                    report.skipped.append((path, "已消失"))
                    continue
                }
                let size = st.st_size
                let inode = Int64(st.st_ino)
                guard size == row.size, inode == row.inode else {
                    report.skipped.append((path, "已变化（可能不是原来那个）"))
                    continue
                }
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                    report.trashed.append((path, size))
                } catch {
                    report.skipped.append((path, "删除失败：\(error.localizedDescription)"))
                }
            }
        }
    }

    private func finishCleanup(_ report: CleanupReport) {
        var report = report
        let dateStamp = Self.dateFormatter.string(from: Date())
        let md = Self.markdown(for: report, dateStamp: dateStamp)

        let reportsDir = supportDirectory.appendingPathComponent("reports", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)
            let fileURL = reportsDir.appendingPathComponent("uninstall-\(report.bundleID)-\(dateStamp).md")
            try md.write(to: fileURL, atomically: true, encoding: .utf8)
            report.reportPath = fileURL.path
        } catch {
            logger.error("报告写入失败：\(error.localizedDescription, privacy: .public)")
        }

        do {
            try database.setAppState(bundleID: report.bundleID, state: "settled")
            try database.insertAppEvent(
                ts: Date().timeIntervalSince1970, bundleID: report.bundleID,
                kind: "settled",
                detail: "cleaned: \(report.trashed.count) 移入废纸篓，\(report.skipped.count) 跳过，\(report.kept.count) 保留"
            )
            let content: [String: Any] = [
                "trashed": report.trashed.map { ["path": $0.path, "size": $0.size] },
                "skipped": report.skipped.map { ["path": $0.path, "reason": $0.reason] },
                "kept": report.kept.map { ["path": $0.path, "reason": $0.reason] },
                "report_path": report.reportPath ?? "",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: content),
               let json = String(data: data, encoding: .utf8) {
                try database.insertReport(createdAt: Date().timeIntervalSince1970, kind: "uninstall", contentJSON: json)
            }
        } catch {
            logger.error("settled 落库失败：\(error.localizedDescription, privacy: .public)")
        }

        model.publish { model in
            model.cleanupReport = report
            model.refreshApps(database: self.database)
        }
    }

    private func isDirectory(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    private func refreshUI() {
        DispatchQueue.main.async { [model, database] in
            model.refreshApps(database: database)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// 报告展示分组（视图与 Markdown 共用）：按类别聚合已清理项。
    struct TrashedGroup {
        var title: String
        var count: Int
        var bytes: Int64
        var paths: [(path: String, size: Int64)]
    }

    static func trashedGroups(_ report: CleanupReport, bundleID: String) -> [TrashedGroup] {
        var byCategory: [String: TrashedGroup] = [:]
        for item in report.trashed {
            let category = Attribution.category(path: item.path, registrationKind: nil)
            var group = byCategory[category] ?? TrashedGroup(
                title: ReportPresentation.categoryTitle(category), count: 0, bytes: 0, paths: []
            )
            group.count += 1
            group.bytes += item.size
            group.paths.append(item)
            byCategory[category] = group
        }
        // 组标题优先取知识库（用组内首个路径的代表性解释）
        for (category, group) in byCategory {
            var titled = group
            if let first = group.paths.first {
                titled.title = Knowledge.shared.explanation(
                    for: first.path, registrationKind: nil, bundleID: bundleID
                ).title
            }
            byCategory[category] = titled
        }
        return byCategory.values.sorted { $0.bytes > $1.bytes }
    }

    /// §14 报告页（人读化）：总结 → 按类别分组的已清理 → 留了什么（按原因）→ 怎么恢复。
    private static func markdown(for report: CleanupReport, dateStamp: String) -> String {
        let totalBytes = report.trashed.reduce(0) { $0 + $1.size }
        var lines: [String] = []
        lines.append("# Ledger 卸载报告 — \(report.appName)")
        lines.append("")
        lines.append("时间：\(dateStamp)")
        lines.append("")
        lines.append("## 总结")
        lines.append("")
        lines.append("- 已清理：\(report.trashed.count) 项，共 \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))，全部在废纸篓中，可还原")
        lines.append("- 跳过：\(report.skipped.count) 项（已变化或删除失败，见下）")
        lines.append("- 保留：\(report.kept.count) 项（未勾选或系统项）")
        lines.append("")
        lines.append("## 已清理（按类别）")
        lines.append("")
        let groups = trashedGroups(report, bundleID: report.bundleID)
        if groups.isEmpty {
            lines.append("（无）")
        } else {
            for group in groups {
                lines.append("### \(group.title)（\(group.count) 项，\(ByteCountFormatter.string(fromByteCount: group.bytes, countStyle: .file))）")
                for item in group.paths.prefix(30) {
                    lines.append("- `\(item.path)`")
                }
                if group.paths.count > 30 {
                    lines.append("- …还有 \(group.paths.count - 30) 项")
                }
                lines.append("")
            }
        }
        lines.append("## 留了什么")
        lines.append("")
        var handledPaths: [String] = []
        for reason in ["已变化", "删除失败", "系统项，不代执行", "未勾选"] {
            var items: [(path: String, reason: String)] = []
            for item in report.skipped where item.reason.contains(reason) {
                items.append((item.path, item.reason))
            }
            for item in report.kept where item.reason == reason {
                items.append((item.path, item.reason))
            }
            guard !items.isEmpty else { continue }
            handledPaths += report.skipped.filter { $0.reason.contains(reason) }.map(\.path)
            let labeled = reason == "已变化" ? "\(reason)（可能不是原来那个）" : reason
            lines.append("### \(labeled)（\(items.count) 项）")
            for item in items.prefix(20) {
                lines.append("- `\(item.path)`")
            }
            if items.count > 20 {
                lines.append("- …还有 \(items.count - 20) 项")
            }
            lines.append("")
        }
        let leftovers = report.skipped.filter { !handledPaths.contains($0.path) }
        if !leftovers.isEmpty {
            lines.append("### 其他（\(leftovers.count) 项）")
            for item in leftovers.prefix(20) {
                lines.append("- `\(item.path)`（\(item.reason)）")
            }
            lines.append("")
        }
        if report.skipped.isEmpty && report.kept.isEmpty {
            lines.append("（无）")
        }
        lines.append("")
        lines.append("## 怎么恢复")
        lines.append("")
        lines.append("废纸篓中的项目：打开废纸篓 → 右键 → 放回原处。")
        lines.append("系统项（注册项/管理员权限项）本报告不代执行，处理命令见残留清单。")
        return lines.joined(separator: "\n")
    }
}
