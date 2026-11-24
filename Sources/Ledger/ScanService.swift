import Foundation
import os

/// 后台扫描：全量基线、目录重扫、文件事件应用、60s 定时落盘、唤醒对账。
/// 所有索引写都经本队列串行（FSEvents 文件事件也在此应用），避免与基线快照竞态。
final class ScanService {
    private let logger = Logger(subsystem: AppPaths.bundleID, category: "scan")
    private let database: Database
    private let index: IndexStore
    private let model: AppModel
    private let queue = DispatchQueue(label: "com.ledger.app.scan", qos: .utility)
    private var flushTimer: DispatchSourceTimer?
    private var lastFullScanAt = Date.distantPast
    private var pendingDirs = Set<String>()  // 在扫的目录（去重，仅本队列访问）
    private var stalledDirs = Set<String>()  // 本会话扫描超时的目录（不再重试，仅本队列访问）
    var installService: InstallService?  // M3：安装事件钩子（AppDelegate 接线）
    var vanishService: VanishService?  // M4：消失事件钩子（AppDelegate 接线）

    init(database: Database, index: IndexStore, model: AppModel) {
        self.database = database
        self.index = index
        self.model = model
    }

    /// 启动 60s 定时落盘（§15.1）。
    func startPeriodicFlush() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in self?.flushNow() }
        timer.resume()
        flushTimer = timer
    }

    /// 全量基线扫描：17 根逐个扫，每根完成即并入索引；不存在的根跳过，
    /// 不可读根记入盲区（禁止静默跳过，§9）。完成立即落盘。
    func fullScan() {
        queue.async { [weak self] in self?.performFullScan() }
    }

    /// 唤醒对账（§5.4）：轻量 = 节流全量重扫。
    /// shortcut: 唤醒一律全量重扫、1 小时节流，未做增量；代价是每次唤醒后台扫几分钟。
    func wakeReconcile() {
        queue.async { [weak self] in
            guard let self else { return }
            guard Date().timeIntervalSince(self.lastFullScanAt) > 3600 else { return }
            self.performFullScan()
        }
    }

    /// FSEvents 文件/目录事件批量应用（事件队列只转发；索引写与基线快照同队列串行）。
    func applyFileEvents(paths: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            var notedApps = Set<String>()  // 批内去重：大安装上万事件只转发每个顶级 .app 一次
            for path in paths {
                // Applications 下的事件：A 已消失 → 卸载判定（M4）；否则安装检测（M3）。
                // 均不入索引（Applications 不是扫描根）
                if let appPath = InstallService.topLevelAppPath(for: path) {
                    guard notedApps.insert(appPath).inserted else { continue }
                    var st = stat()
                    if lstat(appPath, &st) != 0 {
                        self.vanishService?.noteAppRemoval(appPath)
                    } else {
                        self.installService?.noteAppEvent(path)
                    }
                    continue
                }
                var st = stat()
                guard lstat(path, &st) == 0 else {
                    self.index.remove(path: path)
                    continue
                }
                switch st.st_mode & S_IFMT {
                case S_IFLNK:
                    self.index.remove(path: path)  // §9：跳过符号链接
                case S_IFDIR:
                    self.performRescan(path)
                default:
                    self.index.upsert(path: path, entry: IndexEntry(
                        size: st.st_size,
                        mtime: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9,
                        inode: Int64(st.st_ino)
                    ))
                }
            }
        }
    }

    private func performFullScan() {
        lastFullScanAt = Date()
        model.publish { $0.scanState = .scanning }

        var blindSpots: [String] = []
        var total = 0
        for root in ScanRoots.roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }

            let (entries, spots, complete) = scan(url: root, progress: { [weak self] scanned in
                self?.model.publish { $0.scannedCount = scanned }
            })
            blindSpots.append(contentsOf: spots)
            index.applySubtree(entries, under: root.path, mergeOnly: !complete)
            total += entries.count
        }

        do {
            try index.flush()
            try database.metaSet(
                "baseline_blind_spots",
                String(data: try JSONEncoder().encode(blindSpots), encoding: .utf8) ?? "[]"
            )
        } catch {
            logger.error("基线落盘失败：\(error.localizedDescription, privacy: .public)")
        }

        model.publish {
            $0.scanState = .ready
            $0.indexCount = self.index.count
            $0.blindSpots = blindSpots
        }
        logger.notice("基线扫描完成：\(total) 项，盲区 \(blindSpots.count) 处")

        // §5.7：基线完成 → 处理基线期间发现的安装（partial manifest，evidence 降为 inference）
        installService?.onBaselineComplete()
    }

    /// 目录重扫（目录级事件）：去重；超时/失败记入 stalledDirs 本会话不再重试；
    /// 不完整结果只合并（mergeOnly），不删除未扫到的旧条目。
    private func performRescan(_ path: String) {
        guard !pendingDirs.contains(path) else { return }
        pendingDirs.insert(path)
        defer { pendingDirs.remove(path) }

        guard !stalledDirs.contains(path) else { return }

        let (entries, spots, complete) = scan(url: URL(fileURLWithPath: path))
        if !complete { stalledDirs.insert(path) }
        index.applySubtree(entries, under: path, mergeOnly: !complete)
        model.publish { model in
            model.indexCount = self.index.count
            let newSpots = spots.filter { !model.blindSpots.contains($0) }
            if !newSpots.isEmpty {
                model.blindSpots.append(contentsOf: newSpots)
            }
        }
    }

    /// 只读元数据扫描（§9）：子进程 /usr/bin/find 遍历 + 应用内 lstat 取 size/mtime/inode。
    /// 不用进程内遍历：本机存在 readdir 永久阻塞的目录（Group Containers 下多个容器、
    /// com.apple.CloudPhotosConfiguration），进程内遍历会被卡死。find 子进程以「无输出超时」
    /// 保护：15 秒无输出即终止，该根记为盲区（不完整），其余根不受影响。lstat 不阻塞。
    /// com.apple.* 目录整树跳过：系统目录不是可归属的 App 残留（推断，见 devlog）。
    private func scan(
        url: URL,
        progress: ((Int) -> Void)? = nil
    ) -> (entries: [String: IndexEntry], blindSpots: [String], complete: Bool) {
        var entries: [String: IndexEntry] = [:]
        var blindSpots: [String] = []

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        process.arguments = [url.path, "-type", "d", "-path", "*/com.apple.*", "-prune", "-o", "-print0"]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        let errURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-find-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        process.standardError = try? FileHandle(forWritingTo: errURL)

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: errURL)
            blindSpots.append("\(url.path)：无法启动扫描子进程（\(error.localizedDescription)）")
            return (entries, blindSpots, false)
        }

        let (rawPaths, timedOut) = readPaths(
            fd: stdoutPipe.fileHandleForReading.fileDescriptor,
            process: process
        )
        let errLines = (try? String(contentsOf: errURL, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        try? FileManager.default.removeItem(at: errURL)

        var scanned = 0
        for path in rawPaths {
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            scanned += 1
            let mode = st.st_mode & S_IFMT
            if mode == S_IFLNK { continue }  // §9：跳过符号链接
            entries[path] = IndexEntry(
                size: mode == S_IFDIR ? 0 : st.st_size,
                mtime: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9,
                inode: Int64(st.st_ino)
            )
            if scanned % 1000 == 0 { progress?(scanned) }
        }
        if timedOut {
            blindSpots.append("\(url.path)：部分目录读取阻塞超时，本根不完整（其余内容已收录）")
        }
        blindSpots.append(contentsOf: errLines.prefix(50).map { "\(url.path)：\($0)" })
        progress?(scanned)
        return (entries, blindSpots, !timedOut)
    }

    /// 非阻塞读 find 的 NUL 分隔输出；15 秒无输出视为卡死，终止子进程。
    private func readPaths(fd: Int32, process: Process) -> (paths: [String], timedOut: Bool) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var buffer = [UInt8](repeating: 0, count: 65536)
        var out = Data()
        var lastActivity = Date()
        var timedOut = false

        while true {
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let rc = poll(&pollFD, 1, 1000)
            if rc == 0 {
                if Date().timeIntervalSince(lastActivity) > 15 {
                    process.terminate()
                    timedOut = true
                    // SIGTERM 对不可中断睡眠无效；3 秒后升级 SIGKILL（PID 复用窗口极小）
                    let pid = process.processIdentifier
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                        kill(pid, SIGKILL)
                    }
                    break
                }
                continue
            }
            if rc < 0 { break }

            let capacity = buffer.count
            let n = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, capacity)
            }
            if n == 0 { break }  // EOF
            if n < 0 {
                if errno == EAGAIN { continue }
                break
            }
            out.append(contentsOf: buffer[0..<n])
            lastActivity = Date()
        }
        process.waitUntilExit()

        let paths = out.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
        return (paths, timedOut)
    }

    private func flushNow() {
        do {
            try index.flush()
            model.publish { $0.lastFlushAt = Date() }
        } catch {
            logger.error("索引落盘失败：\(error.localizedDescription, privacy: .public)")
        }
    }
}
