import Foundation
import os

/// M7 设置服务：扫描根勾选、暂停记录、通知开关、保留策略、登录自启。
/// 所有设置持久化到 meta 表（§8 meta 已有 schema_version/last_fsevent_id 等键）。
final class SettingsService {
    private let logger = Logger(subsystem: AppPaths.bundleID, category: "settings")
    private let database: Database
    private let model: AppModel
    private let index: IndexStore?

    /// 扫描根变化时回调（AppDelegate 重启 FSEvents）。
    var onRootsChanged: (() -> Void)?

    init(database: Database, model: AppModel, index: IndexStore?) {
        self.database = database
        self.model = model
        self.index = index
    }

    // MARK: - 扫描根勾选

    /// 已禁用的扫描根集合（meta disabled_scan_roots JSON）。
    static func disabledRoots(database: Database) -> Set<String> {
        guard let raw = try? database.metaGet("disabled_scan_roots"),
              let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(list)
    }

    static func enabledRoots(database: Database) -> [URL] {
        let disabled = disabledRoots(database: database)
        return ScanRoots.allRoots.filter { !disabled.contains($0.path) }
    }

    func setRootEnabled(_ path: String, enabled: Bool) {
        var disabled = Self.disabledRoots(database: database)
        if enabled { disabled.remove(path) } else { disabled.insert(path) }

        do {
            let json = try JSONEncoder().encode(Array(disabled).sorted())
            try database.metaSet("disabled_scan_roots", String(data: json, encoding: .utf8) ?? "[]")

            if !enabled, let index {
                // 取消勾选：从索引移除该根条目并立即落盘（否则仍会被对账使用）
                index.applySubtree([:], under: path)
                try? index.flush()
                logger.notice("已停用扫描根并清理索引：\(path, privacy: .public)")
            }
            model.publish { model in
                model.refreshApps(database: self.database)
            }
            onRootsChanged?()
        } catch {
            logger.error("保存扫描根设置失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 暂停记录（§12：状态持久化，重启保持）

    func isPaused() -> Bool {
        (try? database.metaGet("pause_state")) == "paused"
    }

    func setPaused(_ paused: Bool) {
        do {
            try database.metaSet("pause_state", paused ? "paused" : "active")
            model.publish { $0.paused = paused }
            logger.notice("暂停记录：\(paused ? "开" : "关", privacy: .public)")
        } catch {
            logger.error("保存暂停状态失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 通知

    func notificationsEnabled() -> Bool {
        (try? database.metaGet("notifications_enabled")) == "on"
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        do {
            try database.metaSet("notifications_enabled", enabled ? "on" : "off")

        } catch {
            logger.error("保存通知设置失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 保留策略（§14：30 天 / 500MB）

    func applyRetentionPolicy(force: Bool = false) -> (pruned30d: Int, prunedSize: Int) {
        do {
            // 30 天过期
            let cutoff = Date().addingTimeInterval(-30 * 24 * 3600).timeIntervalSince1970
            let pruned30d = try database.pruneChanges(olderThan: cutoff)

            // 500MB 上限（估算）
            let stats = try database.changesStats()
            var prunedSize = 0
            if stats.estimatedBytes > 500 * 1024 * 1024 {
                // 删除最旧的一半
                try database.pruneOldestChanges(stats.count / 2)
                prunedSize = stats.count / 2
            } else if force {
                try database.pruneOldestChanges(stats.count / 2)
                prunedSize = stats.count / 2
            }
            return (pruned30d, prunedSize)
        } catch {
            logger.error("保留策略执行失败：\(error.localizedDescription, privacy: .public)")
            return (0, 0)
        }
    }

    /// 立即清理按钮：删一半最旧记录。
    func pruneNow() {
        do {
            let stats = try database.changesStats()
            try database.pruneOldestChanges(stats.count / 2)
            logger.notice("手动清理：删除最旧 \(stats.count / 2) 条 changes")
        } catch {
            logger.error("手动清理失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    func changesStats() -> (count: Int, estimatedBytes: Int64, oldestTs: Double?) {
        (try? database.changesStats()) ?? (0, 0, nil)
    }

    // MARK: - 登录自启（LaunchAgent，§3）

    private var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.ledger.app.plist", isDirectory: false)
    }

    func launchAtLoginEnabled() -> Bool {
        FileManager.default.fileExists(atPath: agentPlistURL.path)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                let executable = Bundle.main.executablePath
                    ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/Ledger").path
                let plist: [String: Any] = [
                    "Label": "com.ledger.app",
                    "ProgramArguments": [executable],
                    "RunAtLoad": true,
                ]
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                    .write(to: agentPlistURL)
                logger.notice("已安装登录自启：\(executable, privacy: .public)")
            } else {
                try? FileManager.default.removeItem(at: agentPlistURL)
                logger.notice("已移除登录自启")
            }

        } catch {
            logger.error("登录自启设置失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 权限状态（FDA）

    /// FDA 检测：试探读 TCC 保护目录（无 FDA 时不可读）。
    func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let probes = ["Library/Safari", "Library/Mail", "Library/Messages"]
        for probe in probes {
            let path = home + "/" + probe
            if FileManager.default.isReadableFile(atPath: path) {
                return true
            }
        }
        return false
    }
}
