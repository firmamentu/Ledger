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

    /// §7 vanished → verified：用户打开残留清单。broken 无此转移，保持原状态。
    func openVerification(_ bundleID: String) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                guard (try? self.database.appSummaries().first { $0.bundleID == bundleID })?.state == "vanished" else {
                    return
                }
                try self.database.setAppState(bundleID: bundleID, state: "verified")
                try self.database.insertAppEvent(
                    ts: Date().timeIntervalSince1970, bundleID: bundleID,
                    kind: "vanished", detail: "verification_opened"
                )
                self.refreshUI()
            } catch {
                self.logger.error("verified 落库失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// §7 verified → settled：用户明确选择「保留」。
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

    /// §14 报告页：删了什么 / 留了什么 / 怎么恢复。
    private static func markdown(for report: CleanupReport, dateStamp: String) -> String {
        var lines: [String] = []
        lines.append("# Ledger 卸载报告 — \(report.appName)（\(report.bundleID)）")
        lines.append("")
        lines.append("时间：\(dateStamp)")
        lines.append("")
        lines.append("## 删了什么（已移入废纸篓，可还原）")
        if report.trashed.isEmpty {
            lines.append("（无）")
        } else {
            for item in report.trashed {
                lines.append("- `\(item.path)`（\(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))）")
            }
        }
        lines.append("")
        lines.append("## 留了什么")
        if report.skipped.isEmpty && report.kept.isEmpty {
            lines.append("（无）")
        } else {
            for item in report.skipped {
                lines.append("- `\(item.path)`（\(item.reason)）")
            }
            for item in report.kept {
                lines.append("- `\(item.path)`（\(item.reason)）")
            }
        }
        lines.append("")
        lines.append("## 怎么恢复")
        lines.append("废纸篓中的项目：打开废纸篓 → 右键 → 放回原处。")
        lines.append("系统项（注册项/管理员权限项）：本报告不代执行，见残留清单中的处理命令。")
        return lines.joined(separator: "\n")
    }
}
