import XCTest
@testable import Ledger

/// M4 消失检测（§5.5 判定链）与误报撤销。
final class VanishServiceTests: XCTestCase {
    private var tempDir: URL!
    private var db: Database!
    private var model: AppModel!
    private var service: VanishService!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-vanish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try Database(url: tempDir.appendingPathComponent("test.sqlite"))
        model = AppModel()
        service = VanishService(database: db, model: model)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func waitForState(_ bundleID: String, expected: String, timeout: TimeInterval = 8) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var state: String?
        repeat {
            state = (try? db.appSummaries().first { $0.bundleID == bundleID })?.state
            if state == expected { break }
            usleep(100_000)
        } while Date() < deadline
        return state
    }

    func testReconcileMarksMissingAppVanished() throws {
        try db.insertApp(
            bundleID: "com.test.gone", name: "Gone", version: nil,
            installPath: "/Applications/DefinitelyGone.app", iconPath: nil,
            firstSeen: 1, state: "tracked"
        )
        service.reconcileAtStartup()
        XCTAssertEqual(waitForState("com.test.gone", expected: "vanished"), "vanished")
    }

    func testReconcileKeepsExistingAppTracked() throws {
        let realApp = tempDir.appendingPathComponent("StillHere.app")
        try FileManager.default.createDirectory(at: realApp, withIntermediateDirectories: true)
        try db.insertApp(
            bundleID: "com.test.here", name: "Here", version: nil,
            installPath: realApp.path, iconPath: nil,
            firstSeen: 1, state: "tracked"
        )
        service.reconcileAtStartup()
        // 等 2 秒确认没有误判（分类是异步的，给足时间）
        usleep(2_000_000)
        let state = (try? db.appSummaries().first { $0.bundleID == "com.test.here" })?.state
        XCTAssertEqual(state, "tracked")
    }

    func testMarkAsMovedRestoresTracked() throws {
        try db.insertApp(
            bundleID: "com.test.moved", name: "Moved", version: nil,
            installPath: "/Applications/Moved.app", iconPath: nil,
            firstSeen: 1, state: "vanished"
        )
        service.markAsMoved("com.test.moved")
        XCTAssertEqual(waitForState("com.test.moved", expected: "tracked"), "tracked")
    }
}
