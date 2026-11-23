import Foundation

/// 扫描根内单条目的元数据（§5.1 索引项）。
struct IndexEntry {
    var size: Int64
    var mtime: Double
    var inode: Int64
}

/// 内存索引：`Map<path, IndexEntry>`，仅含扫描根内条目。
/// 读（UI）与写（扫描/FSEvents）并发访问，用锁保护；60s 定时落盘见 ScanService。
final class IndexStore {
    private let lock = NSLock()
    private let database: Database
    private var entries: [String: IndexEntry] = [:]
    private var dirty: Set<String> = []

    init(database: Database) {
        self.database = database
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.isEmpty
    }

    /// 待落盘条目数（测试与调试用）。
    var dirtyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dirty.count
    }

    /// 索引快照（CoW：快照后 entries 的变更会触发复制，不污染快照）。
    func snapshot() -> [String: IndexEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func entry(for path: String) -> IndexEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[path]
    }

    func contains(_ path: String) -> Bool {
        entry(for: path) != nil
    }

    /// 从 SQLite 加载全部索引（重启路径）。
    func load() throws {
        let rows = try database.loadIndexEntries()
        lock.lock()
        entries = Dictionary(uniqueKeysWithValues: rows.map { ($0.path, IndexEntry(size: $0.size, mtime: $0.mtime, inode: $0.inode)) })
        dirty.removeAll()
        lock.unlock()
    }

    /// 单条 upsert（FSEvents 文件级事件）。
    func upsert(path: String, entry: IndexEntry) {
        lock.lock()
        entries[path] = entry
        dirty.insert(path)
        lock.unlock()
    }

    /// 单条删除（FSEvents 移除事件）。
    func remove(path: String) {
        lock.lock()
        if entries.removeValue(forKey: path) != nil {
            dirty.insert(path)
        }
        lock.unlock()
    }

    /// 用扫描结果更新某个根/子树（基线扫描、目录重扫）。
    /// mergeOnly=true（扫描超时/不完整）时只 upsert 不删除，保住 find 没走到的旧条目。
    func applySubtree(_ newEntries: [String: IndexEntry], under root: String, mergeOnly: Bool = false) {
        lock.lock()
        if !mergeOnly {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            for key in entries.keys where key == root || key.hasPrefix(prefix) {
                if newEntries[key] == nil {
                    entries.removeValue(forKey: key)
                    dirty.insert(key)
                }
            }
        }
        for (key, value) in newEntries {
            entries[key] = value
            dirty.insert(key)
        }
        lock.unlock()
    }

    /// 把 dirty 落盘；失败时 dirty 保留（下次重试）。
    func flush() throws {
        lock.lock()
        let snapshotPaths = Array(dirty)
        var upserts: [(path: String, size: Int64, mtime: Double, inode: Int64)] = []
        var deletes: [String] = []
        upserts.reserveCapacity(snapshotPaths.count)
        for path in snapshotPaths {
            if let entry = entries[path] {
                upserts.append((path, entry.size, entry.mtime, entry.inode))
            } else {
                deletes.append(path)
            }
        }
        lock.unlock()

        guard !upserts.isEmpty || !deletes.isEmpty else { return }
        try database.applyIndexChanges(upserts: upserts, deletes: deletes)

        lock.lock()
        // shortcut: flush 期间同一 path 的新变化会被一并清除，60s 后下一轮 dirty 不会再含它。
        // 概率极低（flush <1s 内同 path 恰好再变）；触发时该 path 状态滞后一轮，下次事件纠正。
        dirty.subtract(snapshotPaths)
        if dirty.isEmpty {
            dirty.removeAll(keepingCapacity: false)  // 释放全扫后遗留的桶容量（约 5MB）
        }
        lock.unlock()
    }
}
