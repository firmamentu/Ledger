import Foundation
import os

/// M4 消失/卸载检测（§5.5）与启动对账（§12「Ledger 退出期卸载」）。
/// 判定顺序：废纸篓有同名 .app → 卸载；Spotlight 找到别处 → 移动（不触发提示）；
/// 都找不到 → 判卸载并带「只是移动了它？」撤销入口（跨卷移动误报兜底）。
/// 禁止用 inode 区分移动/废纸篓（§5.5）。
final class VanishService {
    private let logger = Logger(subsystem: AppPaths.bundleID, category: "vanish")
    private let database: Database
    private let model: AppModel
    private let queue = DispatchQueue(label: "com.ledger.app.vanish", qos: .utility)

    init(database: Database, model: AppModel) {
        self.database = database
        self.model = model
    }

    /// 事件钩子：顶级 .app A 已消失（从 ScanService 转发）。
    func noteAppRemoval(_ appPath: String) {
        queue.async { [weak self] in self?.handleRemoval(appPath) }
    }

    /// 启动对账：recorded/tracked 但 .app 已不存在 → 补标 vanished。
    func reconcileAtStartup() {
        queue.async { [weak self] in self?.reconcile() }
    }

    /// 误报撤销：「只是移动了它？」→ 状态回 tracked，撤下待处理。
    func markAsMoved(_ bundleID: String) {
        queue.async { [weak self] in self?.undoMisreport(bundleID) }
    }

    /// 重新追踪：把已处理（settled/verified）的 App 放回 tracked，重新开始记录其变化。
    func resumeTracking(_ bundleID: String) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.database.setAppState(bundleID: bundleID, state: "tracked")
                try self.database.insertAppEvent(
                    ts: Date().timeIntervalSince1970, bundleID: bundleID,
                    kind: "restored", detail: "user_resumed_tracking"
                )
                self.logger.notice("重新追踪：\(bundleID, privacy: .public)")
                self.refreshUI()
            } catch {
                self.logger.error("重新追踪失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func handleRemoval(_ appPath: String) {
        guard let row = try? database.appRow(atInstallPath: appPath),
              row.state == "recorded" || row.state == "tracked" else { return }
        classify(bundleID: row.bundleID, path: appPath)
    }

    private func reconcile() {
        guard let rows = try? database.trackedApps() else { return }
        for row in rows {
            guard let path = row.installPath, Self.isAppLocation(path) else { continue }
            var st = stat()
            if lstat(path, &st) != 0 {
                classify(bundleID: row.bundleID, path: path)
            }
        }
    }

    private func classify(bundleID: String, path: String) {
        // 竞态防护：判定落库前 App 已重现则跳过（交给恢复事件）
        var st = stat()
        guard lstat(path, &st) != 0 else { return }

        let name = (path as NSString).lastPathComponent
        if FileManager.default.fileExists(atPath: ScanRoots.trashURL.appendingPathComponent(name).path) {
            markVanished(bundleID, detail: "trash_detected：App 在废纸篓中")
            return
        }
        if let elsewhere = findElsewhere(bundleID: bundleID, excluding: path) {
            do {
                try database.setAppInstallPath(bundleID: bundleID, installPath: elsewhere)
                logger.notice("App 移动（不触发提示）：\(bundleID, privacy: .public) → \(elsewhere, privacy: .public)")
            } catch {
                logger.error("更新移动路径失败：\(error.localizedDescription, privacy: .public)")
            }
            return
        }
        markVanished(bundleID, detail: "location_unknown：未在废纸篓或 Spotlight 找到（可能是跨卷移动，可用「只是移动了它？」撤销）")
    }

    /// Spotlight 查 bundle-id 的其它位置（滞后时找不到 → 走误报入口兜底）。
    private func findElsewhere(bundleID: String, excluding path: String) -> String? {
        // bundleID 来自不受信任的 Info.plist：仅合法格式才查询，防 mdfind 查询注入
        guard bundleID.range(of: "^[A-Za-z0-9.\\-]+$", options: .regularExpression) != nil else {
            return nil
        }
        for line in Subprocess.runLines("/usr/bin/mdfind", ["kMDItemCFBundleIdentifier == '\(bundleID)'"]) {
            guard line.hasSuffix(".app"), line != path,
                  !ScanRoots.isUnderTrash(line),  // 废纸篓重名（App 2.app）会误判为移动
                  FileManager.default.fileExists(atPath: line) else { continue }
            return line
        }
        return nil
    }

    private func markVanished(_ bundleID: String, detail: String) {
        do {
            try database.setAppState(bundleID: bundleID, state: "vanished")
            try database.insertAppEvent(
                ts: Date().timeIntervalSince1970, bundleID: bundleID,
                kind: "vanished", detail: detail
            )
            logger.notice("判定卸载：\(bundleID, privacy: .public)（\(detail, privacy: .public)）")
            refreshUI()

            // §14 通知：开关开启时提示「还有 N 处」
            if (try? database.metaGet("notifications_enabled")) == "on" {
                let name = (try? database.appSummaries().first { $0.bundleID == bundleID })?.name ?? bundleID
                let count = (try? database.manifestItems(for: bundleID))?.count ?? 0
                DispatchQueue.main.async {
                    NotificationService.notifyUninstalled(appName: name, residualCount: count)
                }
            }
        } catch {
            logger.error("vanish 落库失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func undoMisreport(_ bundleID: String) {
        do {
            try database.setAppState(bundleID: bundleID, state: "tracked")
            try database.insertAppEvent(
                ts: Date().timeIntervalSince1970, bundleID: bundleID,
                kind: "restored", detail: "misreport_undone：用户标为移动"
            )
            logger.notice("误报撤销：\(bundleID, privacy: .public) 回 tracked")
            refreshUI()
        } catch {
            logger.error("误报撤销失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    static func isAppLocation(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    private func refreshUI() {
        DispatchQueue.main.async { [model, database] in
            model.refreshApps(database: database)
        }
    }
}
