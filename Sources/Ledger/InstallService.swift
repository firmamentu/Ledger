import Foundation
import os

/// M3 安装检测与记账（§5.2 / §5.3 / §5.7）。
/// 新装判定：事件路径属于 /Applications 或 ~/Applications 下某顶级 .app 子树，
/// 且该路径不在 apps 表（更新/修改不触发记账）且无活跃 context。
/// 稳定判定：A 的 mtime 连续 30s 无变化 → 完成；30 分钟未稳定 → broken(partial)。
final class InstallService {
    private final class Context {
        var appPath: String
        var startedAt: Date
        var preInstallState: [String: IndexEntry]?
        var registrationsBefore: Registrations
        var lastMtime: Double = 0
        var lastChangeAt: Date
        var pendingPreScan: Bool

        init(appPath: String, startedAt: Date, preInstallState: [String: IndexEntry]?, registrationsBefore: Registrations, pendingPreScan: Bool) {
            self.appPath = appPath
            self.startedAt = startedAt
            self.preInstallState = preInstallState
            self.registrationsBefore = registrationsBefore
            self.lastChangeAt = startedAt
            self.pendingPreScan = pendingPreScan
        }
    }

    private struct Registrations {
        var receipts: Set<String> = []
        var extensions: Set<String> = []
    }

    private struct AppInfo {
        var bundleID: String
        var name: String
        var version: String?
        var executable: String
    }

    private let logger = Logger(subsystem: AppPaths.bundleID, category: "install")
    private let database: Database
    private let index: IndexStore
    private let model: AppModel
    private let queue = DispatchQueue(label: "com.ledger.app.install", qos: .utility)
    private var contexts: [String: Context] = [:]
    private var timer: DispatchSourceTimer?
    private var baselineReady = false

    init(database: Database, index: IndexStore, model: AppModel) {
        self.database = database
        self.index = index
        self.model = model
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// FSEvents 事件路径钩子（从 ScanService 转发）。
    func noteAppEvent(_ path: String) {
        queue.async { [weak self] in self?.checkInstall(path) }
    }

    /// 基线完成（§5.7）：pending context 生成 manifest（status=partial，evidence=inference）。
    func onBaselineComplete() {
        markBaselineReady()
    }

    /// 索引已从磁盘加载完成（重启重放路径）：基线就绪，安装可正常记账。
    func markBaselineReady() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.baselineReady else { return }
            self.baselineReady = true
            for (path, ctx) in self.contexts where ctx.pendingPreScan {
                self.contexts.removeValue(forKey: path)
                self.finalize(ctx, preScanPartial: true)
            }
        }
    }

    /// 提取顶级 .app 路径：/Applications/<name>.app 或 ~/Applications/<name>.app。
    static func topLevelAppPath(for path: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for base in ["/Applications", home + "/Applications"] {
            guard path.hasPrefix(base + "/") else { continue }
            let rest = String(path.dropFirst(base.count + 1))
            guard let first = rest.split(separator: "/").first else { continue }
            guard String(first).hasSuffix(".app") else { return nil }
            return base + "/" + first
        }
        return nil
    }

    // MARK: - 检测与状态机

    private func checkInstall(_ path: String) {
        guard let appPath = Self.topLevelAppPath(for: path) else { return }
        guard contexts[appPath] == nil else { return }  // 已跟踪

        do {
            // recorded/tracked → 更新/修改，不触发记账（§5.2）；
            // broken → 重新安装，重走稳定判定（§7 broken → installing）；
            // vanished 同路径重现 → 恢复：状态回 tracked，撤下待处理，保留原 manifest（§5.6）
            if let row = try database.appRow(atInstallPath: appPath) {
                if row.state == "recorded" || row.state == "tracked" {
                    return
                }
                if row.state == "vanished" {
                    try database.setAppState(bundleID: row.bundleID, state: "tracked")
                    try database.insertAppEvent(
                        ts: Date().timeIntervalSince1970, bundleID: row.bundleID,
                        kind: "restored", detail: "same_path_reappeared"
                    )
                    logger.notice("App 恢复（同路径重现）：\(row.bundleID, privacy: .public)")
                    refreshUI()
                    return
                }
            }
        } catch {
            logger.error("查询 apps 失败：\(error.localizedDescription, privacy: .public)")
            return
        }

        // 新装：创建 context（§5.3.1：started_at = 事件时间 - 2s；pre = 索引深拷贝）
        let startedAt = Date().addingTimeInterval(-2)
        let pre = baselineReady ? index.snapshot() : nil
        let ctx = Context(
            appPath: appPath,
            startedAt: startedAt,
            preInstallState: pre,
            registrationsBefore: captureRegistrations(),
            pendingPreScan: !baselineReady
        )
        contexts[appPath] = ctx
        logger.notice("发现新装：\(appPath, privacy: .public)\(ctx.pendingPreScan ? "（基线未完成，待基线后记账）" : "")")
    }

    /// 每秒：比较 A 的 mtime；连续 30s 无变化 → finalize；30 分钟未稳定 → broken。
    private func tick() {
        let now = Date()
        var toRemove: [String] = []  // 迭代期间不直接改 contexts，避免枚举变异
        for (path, ctx) in contexts {
            guard !ctx.pendingPreScan || baselineReady else { continue }  // §5.7：等基线

            var st = stat()
            guard lstat(path, &st) == 0 else {
                // 安装窗口内 App 消失：放弃记账，移除 context（消失账务由 M4 补）
                toRemove.append(path)
                logger.notice("安装窗口内 App 消失，放弃记账：\(path, privacy: .public)")
                continue
            }
            let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
            if mtime != ctx.lastMtime {
                ctx.lastMtime = mtime
                ctx.lastChangeAt = now
                continue
            }

            if now.timeIntervalSince(ctx.lastChangeAt) >= 30 {
                toRemove.append(path)
                finalize(ctx, preScanPartial: false)
            } else if now.timeIntervalSince(ctx.startedAt) >= 30 * 60 {
                toRemove.append(path)
                finalizeBroken(ctx, info: readPlistInfo(ctx.appPath), reason: "30 分钟未稳定")
            }
        }
        for path in toRemove {
            contexts.removeValue(forKey: path)
        }
    }

    // MARK: - 落库

    private func finalize(_ ctx: Context, preScanPartial: Bool) {
        let finishedAt = Date()
        guard let info = readPlistInfo(ctx.appPath) else {
            finalizeBroken(ctx, info: nil, reason: "结构校验失败：Info.plist 缺失或不可读")
            return
        }
        guard hasExecutable(info, appPath: ctx.appPath) else {
            finalizeBroken(ctx, info: info, reason: "结构校验失败：CFBundleExecutable 指向的可执行文件缺失")
            return
        }

        // 签名校验（§5.3.4）：失败仅记 warning，不判 broken
        let signatureOK = verifySignature(ctx.appPath)
        let hasWarning = !signatureOK && !preScanPartial

        // 注册项差分（§5.3.7）
        let registrationsAfter = captureRegistrations()
        let newReceipts = registrationsAfter.receipts.subtracting(ctx.registrationsBefore.receipts)
        let newExtensions = registrationsAfter.extensions.subtracting(ctx.registrationsBefore.extensions)

        let window = (ctx.startedAt.addingTimeInterval(-5).timeIntervalSince1970)...finishedAt.addingTimeInterval(30).timeIntervalSince1970
        let current = index.snapshot()
        let paths = Attribution.selectItemPaths(
            current: current,
            pre: preScanPartial ? nil : ctx.preInstallState,
            window: window,
            excludeSubtree: ctx.appPath
        )

        let names = [info.name]
        var rows: [(manifestID: Int64, path: String, itemType: String, category: String, size: Int64, mtime: Double, inode: Int64, registrationKind: String?, verdict: String, requiresAdmin: Bool, evidence: String)] = []
        rows.reserveCapacity(paths.count + newReceipts.count + newExtensions.count)

        for path in paths {
            guard let entry = current[path] else { continue }
            let evidence = preScanPartial ? "inference" : Attribution.evidence(path: path, bundleID: info.bundleID, names: names)
            rows.append((
                manifestID: 0,
                path: path,
                itemType: isDirectory(path) ? "dir" : "file",
                category: Attribution.category(path: path, registrationKind: nil),
                size: entry.size,
                mtime: entry.mtime,
                inode: entry.inode,
                registrationKind: nil,
                verdict: Attribution.verdict(path: path, registrationKind: nil),
                requiresAdmin: Attribution.requiresAdmin(path: path, registrationKind: nil),
                evidence: evidence
            ))
        }

        for pkgID in newReceipts {
            rows.append(registrationRow(
                pkgID: pkgID, bundleID: info.bundleID,
                kind: "receipt", size: 0, mtime: finishedAt.timeIntervalSince1970, inode: 0
            ))
        }
        for extID in newExtensions {
            rows.append(registrationRow(
                pkgID: extID, bundleID: info.bundleID,
                kind: "system_extension", size: 0, mtime: finishedAt.timeIntervalSince1970, inode: 0
            ))
        }

        do {
            let iconPath = cacheIcon(appPath: ctx.appPath, bundleID: info.bundleID)
            try database.insertApp(
                bundleID: info.bundleID, name: info.name, version: info.version,
                installPath: ctx.appPath, iconPath: iconPath,
                firstSeen: ctx.startedAt.timeIntervalSince1970, state: "recorded"
            )
            let manifestID = try database.insertManifest(
                appBundleID: info.bundleID,
                start: ctx.startedAt.timeIntervalSince1970,
                finish: finishedAt.timeIntervalSince1970,
                observedScope: Self.observedScopeJSON,
                blindSpots: currentBlindSpotsJSON(),
                status: preScanPartial ? "partial" : "complete",
                createdAt: finishedAt.timeIntervalSince1970
            )
            let finalRows = rows.map { row -> (manifestID: Int64, path: String, itemType: String, category: String, size: Int64, mtime: Double, inode: Int64, registrationKind: String?, verdict: String, requiresAdmin: Bool, evidence: String) in
                var copy = row
                copy.manifestID = manifestID
                return copy
            }
            try database.insertManifestItems(finalRows)
            try database.supersedeManifests(appBundleID: info.bundleID, except: manifestID)

            var detail = "installed"
            if hasWarning {
                detail = "signature_warning: 未通过 codesign 校验（可能是未签名开发构建）"
            }
            if preScanPartial {
                detail += " pre_scan_partial: 基线晚于安装开始，记账不完整"
            }
            try database.insertAppEvent(
                ts: finishedAt.timeIntervalSince1970, bundleID: info.bundleID,
                kind: "installed", detail: detail
            )

            logger.notice("记账完成：\(info.bundleID, privacy: .public)（\(paths.count) 文件/目录 + \(newReceipts.count) receipts + \(newExtensions.count) 扩展）")
            refreshUI()
        } catch {
            logger.error("落库失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func finalizeBroken(_ ctx: Context, info: AppInfo?, reason: String) {
        let finishedAt = Date()
        let fallback = URL(fileURLWithPath: ctx.appPath).deletingPathExtension().lastPathComponent
        let bundleID = info?.bundleID ?? fallback

        // §5.3.5：半成品也要记录，否则无法清理——broken 的 manifest 同样选取窗口内条目
        let window = (ctx.startedAt.addingTimeInterval(-5).timeIntervalSince1970)...finishedAt.addingTimeInterval(30).timeIntervalSince1970
        let current = index.snapshot()
        let paths = Attribution.selectItemPaths(
            current: current,
            pre: ctx.pendingPreScan ? nil : ctx.preInstallState,
            window: window,
            excludeSubtree: ctx.appPath
        )

        do {
            try database.insertApp(
                bundleID: bundleID, name: info?.name ?? bundleID, version: info?.version,
                installPath: ctx.appPath, iconPath: nil,
                firstSeen: ctx.startedAt.timeIntervalSince1970, state: "broken"
            )
            let manifestID = try database.insertManifest(
                appBundleID: bundleID,
                start: ctx.startedAt.timeIntervalSince1970,
                finish: finishedAt.timeIntervalSince1970,
                observedScope: Self.observedScopeJSON,
                blindSpots: currentBlindSpotsJSON(),
                status: "partial",
                createdAt: finishedAt.timeIntervalSince1970
            )
            if !paths.isEmpty {
                let rows = paths.compactMap { path -> (manifestID: Int64, path: String, itemType: String, category: String, size: Int64, mtime: Double, inode: Int64, registrationKind: String?, verdict: String, requiresAdmin: Bool, evidence: String)? in
                    guard let entry = current[path] else { return nil }
                    // 信息不全（无 bundle-id 或基线未完成）→ 全部 inference，永不默认勾选
                    let evidence = (info == nil || ctx.pendingPreScan)
                        ? "inference"
                        : Attribution.evidence(path: path, bundleID: info!.bundleID, names: [info!.name])
                    return (
                        manifestID: manifestID,
                        path: path,
                        itemType: isDirectory(path) ? "dir" : "file",
                        category: Attribution.category(path: path, registrationKind: nil),
                        size: entry.size,
                        mtime: entry.mtime,
                        inode: entry.inode,
                        registrationKind: nil,
                        verdict: Attribution.verdict(path: path, registrationKind: nil),
                        requiresAdmin: Attribution.requiresAdmin(path: path, registrationKind: nil),
                        evidence: evidence
                    )
                }
                try database.insertManifestItems(rows)
            }
            try database.supersedeManifests(appBundleID: bundleID, except: manifestID)
            try database.insertAppEvent(
                ts: finishedAt.timeIntervalSince1970, bundleID: bundleID,
                kind: "broken", detail: reason
            )
            logger.notice("记账失败（broken）：\(bundleID, privacy: .public)（\(reason, privacy: .public)）")
            refreshUI()
        } catch {
            logger.error("broken 落库失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func registrationRow(pkgID: String, bundleID: String, kind: String, size: Int64, mtime: Double, inode: Int64) -> (manifestID: Int64, path: String, itemType: String, category: String, size: Int64, mtime: Double, inode: Int64, registrationKind: String?, verdict: String, requiresAdmin: Bool, evidence: String) {
        let evidence = pkgID.lowercased() == bundleID.lowercased() ? "fact" : "inference"
        return (
            manifestID: 0,
            path: "registration:\(kind):\(pkgID)",
            itemType: "registration",
            category: "registration",
            size: size,
            mtime: mtime,
            inode: inode,
            registrationKind: kind,
            verdict: Attribution.verdict(path: nil, registrationKind: kind),
            requiresAdmin: Attribution.requiresAdmin(path: nil, registrationKind: kind),
            evidence: evidence
        )
    }

    private func refreshUI() {
        DispatchQueue.main.async { [model, database] in
            model.refreshApps(database: database)
        }
    }

    // MARK: - 校验与读取

    /// 只读 Info.plist（§10.3：bundle-id 读取失败按 App 名匹配 → 文件名兜底）。
    private func readPlistInfo(_ appPath: String) -> AppInfo? {
        let plistURL = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let executable = plist["CFBundleExecutable"] as? String else {
            return nil
        }
        let bundleID = (plist["CFBundleIdentifier"] as? String)
            ?? URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? bundleID
        return AppInfo(bundleID: bundleID, name: name, version: plist["CFBundleShortVersionString"] as? String, executable: executable)
    }

    /// 结构校验（§5.3.3）：CFBundleExecutable 指向的可执行文件必须存在。
    private func hasExecutable(_ info: AppInfo, appPath: String) -> Bool {
        let contents = URL(fileURLWithPath: appPath).appendingPathComponent("Contents")
        let candidates = [
            contents.appendingPathComponent("MacOS/\(info.executable)").path,
            contents.appendingPathComponent(info.executable).path,
        ]
        return candidates.contains(where: { FileManager.default.fileExists(atPath: $0) })
    }

    private func verifySignature(_ appPath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", appPath]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        return Subprocess.waitBounded(process, timeout: 10) == 0
    }

    private func cacheIcon(appPath: String, bundleID: String) -> String? {
        let resources = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Resources")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil),
              let icns = entries.filter({ $0.pathExtension == "icns" }).max(by: {
                  (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0
                      < (try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0
              }) else {
            return nil
        }
        let iconsDir = AppPaths.supportDirectory.appendingPathComponent("icons", isDirectory: true)
        let destination = iconsDir.appendingPathComponent("\(bundleID).icns")
        do {
            try FileManager.default.createDirectory(at: iconsDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: icns, to: destination)
            return destination.path
        } catch {
            return nil
        }
    }

    // MARK: - 注册项

    private func captureRegistrations() -> Registrations {
        var result = Registrations()
        result.receipts = runAndParse("/usr/sbin/pkgutil", ["--pkgs"])
        let extLines = runLines("/usr/bin/systemextensionsctl", ["list"])
        for line in extLines {
            // 行格式: [*] [enabled|disabled] <teamID> <bundleID> (version) name [state]
            var tokens = line.split(separator: " ").map(String.init)
            if tokens.first == "*" { tokens.removeFirst() }
            if let first = tokens.first, first == "enabled" || first == "disabled" || first == "activated_enabled" || first == "activated_disabled" {
                tokens.removeFirst()
            }
            if tokens.count >= 2, tokens[1].contains(".") {
                result.extensions.insert(tokens[1])
            }
        }
        return result
    }

    private func runAndParse(_ executable: String, _ arguments: [String]) -> Set<String> {
        Set(runLines(executable, arguments))
    }

    private func runLines(_ executable: String, _ arguments: [String]) -> [String] {
        Subprocess.runLines(executable, arguments)
    }

    private func isDirectory(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    // MARK: - 范围记录

    private static var observedScopeJSON: String {
        let paths = ScanRoots.roots.map { $0.path }
        return (try? JSONEncoder().encode(paths)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// manifest 盲区快照：用 meta 里最近一次基线落盘的盲区（重扫新增盲区 M4 接入）。
    private func currentBlindSpotsJSON() -> String {
        (try? database.metaGet("baseline_blind_spots")) ?? "[]"
    }
}
