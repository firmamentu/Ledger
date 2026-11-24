import XCTest
@testable import Ledger

/// M7 设置：扫描根勾选持久化与索引清理、暂停持久化、保留策略。
final class SettingsServiceTests: XCTestCase {
    private var tempDir: URL!
    private var db: Database!
    private var model: AppModel!
    private var index: IndexStore!
    private var service: SettingsService!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try Database(url: tempDir.appendingPathComponent("test.sqlite"))
        model = AppModel()
        index = IndexStore(database: db)
        service = SettingsService(database: db, model: model, index: index)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRootTogglePersistsAndCleansIndex() {
        index.upsert(path: "/root-x/a.txt", entry: IndexEntry(size: 1, mtime: 0, inode: 1))
        index.upsert(path: "/root-y/b.txt", entry: IndexEntry(size: 2, mtime: 0, inode: 2))

        service.setRootEnabled("/root-x", enabled: false)
        XCTAssertTrue(SettingsService.disabledRoots(database: db).contains("/root-x"))
        XCTAssertNil(index.entry(for: "/root-x/a.txt"))  // 索引已清理
        XCTAssertNotNil(index.entry(for: "/root-y/b.txt"))  // 其他根不受影响

        service.setRootEnabled("/root-x", enabled: true)
        XCTAssertFalse(SettingsService.disabledRoots(database: db).contains("/root-x"))
    }

    func testEnabledRootsFilters() {
        service.setRootEnabled(ScanRoots.allRoots.first!.path, enabled: false)
        let enabled = SettingsService.enabledRoots(database: db)
        XCTAssertEqual(enabled.count, ScanRoots.allRoots.count - 1)
        XCTAssertFalse(enabled.contains(ScanRoots.allRoots.first!))
    }

    func testPausePersists() {
        service.setPaused(true)
        XCTAssertTrue(service.isPaused())
        service.setPaused(false)
        XCTAssertFalse(service.isPaused())
    }

    func testRetentionPolicyPrunesOldChanges() throws {
        let old = Date().addingTimeInterval(-40 * 24 * 3600).timeIntervalSince1970
        let new = Date().timeIntervalSince1970
        try db.insertChanges([
            (ts: old, path: "/old", appBundleID: nil, kind: "created", sizeDelta: 1, evidence: "unknown"),
            (ts: new, path: "/new", appBundleID: nil, kind: "created", sizeDelta: 1, evidence: "unknown"),
        ])
        let (pruned30d, _) = service.applyRetentionPolicy()
        XCTAssertEqual(pruned30d, 1)
        let stats = service.changesStats()
        XCTAssertEqual(stats.count, 1)
    }

    func testPruneNowHalves() throws {
        for i in 0..<10 {
            try db.insertChanges([
                (ts: Date().timeIntervalSince1970 + Double(i), path: "/p\(i)", appBundleID: nil, kind: "created", sizeDelta: 1, evidence: "unknown"),
            ])
        }
        service.pruneNow()
        let stats = service.changesStats()
        XCTAssertEqual(stats.count, 5)
    }
}
