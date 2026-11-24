import Foundation
import os

/// 识别轨（§1 边界）：手动登记已安装的 App。
/// 已装 App 没有安装窗口可对照，只收录索引中按 fact 规则归属该 App 的现有条目，
/// manifest status=partial（尽力而为），state=tracked。
final class AddAppService {
    private let logger = Logger(subsystem: AppPaths.bundleID, category: "addapp")
    private let database: Database
    private let index: IndexStore
    private let model: AppModel
    private let queue = DispatchQueue(label: "com.ledger.app.addapp", qos: .utility)

    init(database: Database, index: IndexStore, model: AppModel) {
        self.database = database
        self.index = index
        self.model = model
    }

    /// 手动添加：返回用户可读的结果消息。
    func addExistingApp(path: String, completion: @escaping (String) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let message = self.performAdd(path: path)
            DispatchQueue.main.async {
                completion(message)
                self.model.refreshApps(database: self.database)
            }
        }
    }

    private func performAdd(path: String) -> String {
        guard path.hasSuffix(".app"),
              let info = InstallService.readPlistInfo(path) else {
            return "无法读取该 App 的 Info.plist（需选择完整的 .app 包）"
        }

        do {
            if let existing = try database.appSummaries().first(where: { $0.bundleID == info.bundleID }) {
                return "「\(existing.name)」已在账本中（状态：\(Self.stateLabel(existing.state))），无需重复添加"
            }

            let paths = Attribution.attributedPaths(
                index: index.snapshot(), bundleID: info.bundleID, names: [info.name]
            )
            let current = index.snapshot()

            let iconPath = try? InstallService.cacheIcon(appPath: path, bundleID: info.bundleID)
            try database.insertApp(
                bundleID: info.bundleID, name: info.name, version: info.version,
                installPath: path, iconPath: iconPath,
                firstSeen: Date().timeIntervalSince1970, state: "tracked"
            )
            let manifestID = try database.insertManifest(
                appBundleID: info.bundleID,
                start: Date().timeIntervalSince1970,
                finish: Date().timeIntervalSince1970,
                observedScope: InstallService.observedScopeJSON(database: database),
                blindSpots: (try? database.metaGet("baseline_blind_spots")) ?? "[]",
                status: "partial",
                createdAt: Date().timeIntervalSince1970
            )

            let rows = paths.compactMap { path -> (manifestID: Int64, path: String, itemType: String, category: String, size: Int64, mtime: Double, inode: Int64, registrationKind: String?, verdict: String, requiresAdmin: Bool, evidence: String)? in
                guard let entry = current[path] else { return nil }
                return (
                    manifestID: manifestID,
                    path: path,
                    itemType: Self.isDirectory(path) ? "dir" : "file",
                    category: Attribution.category(path: path, registrationKind: nil),
                    size: entry.size,
                    mtime: entry.mtime,
                    inode: entry.inode,
                    registrationKind: nil,
                    verdict: Attribution.verdict(path: path, registrationKind: nil),
                    requiresAdmin: Attribution.requiresAdmin(path: path, registrationKind: nil),
                    evidence: "fact"
                )
            }
            try database.insertManifestItems(rows)
            try database.insertAppEvent(
                ts: Date().timeIntervalSince1970, bundleID: info.bundleID,
                kind: "installed", detail: "manual_recognition：识别轨登记（已装 App，尽力而为）"
            )
            logger.notice("识别轨登记：\(info.bundleID, privacy: .public)（\(rows.count) 项）")
            return "已添加「\(info.name)」，识别到 \(rows.count) 个相关文件/目录"
        } catch {
            logger.error("识别轨登记失败：\(error.localizedDescription, privacy: .public)")
            return "添加失败：\(error.localizedDescription)"
        }
    }

    private static func stateLabel(_ state: String?) -> String {
        switch state {
        case "broken": return "安装未完成"
        case "vanished": return "已卸载"
        case "settled": return "已处理"
        case "verified": return "已核对"
        default: return "追踪中"
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

}
