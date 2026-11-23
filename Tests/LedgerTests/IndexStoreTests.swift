import XCTest
@testable import Ledger

/// IndexStore 的替换/合并语义与落盘（评审发现 1/4：部分扫描不得删除未扫到的旧条目）。
final class IndexStoreTests: XCTestCase {
    private var tempDir: URL!
    private var db: Database!
    private var store: IndexStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try Database(url: tempDir.appendingPathComponent("test.sqlite"))
        store = IndexStore(database: db)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testReplaceRemovesUnlistedEntries() {
        store.upsert(path: "/r/old.txt", entry: IndexEntry(size: 1, mtime: 0, inode: 1))
        store.applySubtree(["/r/new.txt": IndexEntry(size: 2, mtime: 1, inode: 2)], under: "/r")
        XCTAssertNil(store.entry(for: "/r/old.txt"), "完整扫描应删除未列出的旧条目")
        XCTAssertNotNil(store.entry(for: "/r/new.txt"))
    }

    func testMergeKeepsUnlistedEntries() {
        store.upsert(path: "/r/old.txt", entry: IndexEntry(size: 1, mtime: 0, inode: 1))
        store.applySubtree(
            ["/r/new.txt": IndexEntry(size: 2, mtime: 1, inode: 2)],
            under: "/r",
            mergeOnly: true
        )
        XCTAssertNotNil(store.entry(for: "/r/old.txt"), "超时的部分扫描必须保留未扫到的旧条目")
        XCTAssertNotNil(store.entry(for: "/r/new.txt"))
    }

    func testMergeUpdatesExistingEntries() {
        store.upsert(path: "/r/a.txt", entry: IndexEntry(size: 1, mtime: 0, inode: 1))
        store.applySubtree(
            ["/r/a.txt": IndexEntry(size: 99, mtime: 5, inode: 1)],
            under: "/r",
            mergeOnly: true
        )
        XCTAssertEqual(store.entry(for: "/r/a.txt")?.size, 99)
    }

    func testFlushPersistsUpsertsAndDeletes() throws {
        store.upsert(path: "/r/a.txt", entry: IndexEntry(size: 3, mtime: 2, inode: 3))
        store.upsert(path: "/r/b.txt", entry: IndexEntry(size: 4, mtime: 3, inode: 4))
        try store.flush()

        store.remove(path: "/r/b.txt")
        try store.flush()

        let rows = try db.loadIndexEntries()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.path, "/r/a.txt")
        XCTAssertEqual(rows.first?.size, 3)
    }

    func testFlushClearsDirty() throws {
        // 写失败保留 dirty 的语义由代码结构保证（subtract 在成功写入之后）；
        // 这里验证成功路径：flush 后 dirty 清空
        store.upsert(path: "/r/a.txt", entry: IndexEntry(size: 1, mtime: 0, inode: 1))
        XCTAssertEqual(store.dirtyCount, 1)
        try store.flush()
        XCTAssertEqual(store.dirtyCount, 0)
    }
}
