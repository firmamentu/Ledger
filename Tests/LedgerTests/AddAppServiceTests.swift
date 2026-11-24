import XCTest
@testable import Ledger

/// 识别轨（手动添加已装 App）：归属收录 fact 条目、manifest partial、state=tracked。
final class AddAppServiceTests: XCTestCase {
    private var tempDir: URL!
    private var db: Database!
    private var model: AppModel!
    private var index: IndexStore!
    private var service: AddAppService!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-addapp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try Database(url: tempDir.appendingPathComponent("test.sqlite"))
        model = AppModel()
        index = IndexStore(database: db)
        service = AddAppService(database: db, index: index, model: model)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testAddExistingAppRecordsFactItems() throws {
        // 构造一个 .app 与索引中的归属条目
        let appDir = tempDir.appendingPathComponent("TestManual.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let infoPlist: [String: Any] = [
            "CFBundleIdentifier": "com.test.manual",
            "CFBundleExecutable": "TestManual",
            "CFBundleName": "Manual Test",
        ]
        try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
            .write(to: tempDir.appendingPathComponent("TestManual.app/Contents/Info.plist"))
        FileManager.default.createFile(
            atPath: appDir.appendingPathComponent("TestManual").path, contents: Data()
        )

        index.upsert(path: "/Users/x/Library/Application Support/com.test.manual/data.txt",
                     entry: IndexEntry(size: 10, mtime: 1, inode: 1))
        index.upsert(path: "/Users/x/Library/Caches/unrelated/x",
                     entry: IndexEntry(size: 20, mtime: 2, inode: 2))

        let expectation = expectation(description: "add")
        var message = ""
        service.addExistingApp(path: tempDir.appendingPathComponent("TestManual.app").path) { result in
            message = result
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        XCTAssertTrue(message.contains("已添加"))
        let summary = try XCTUnwrap(try db.appSummaries().first { $0.bundleID == "com.test.manual" })
        XCTAssertEqual(summary.state, "tracked")
        let items = try db.manifestItems(for: "com.test.manual")
        XCTAssertEqual(items.count, 1)  // 只收录 fact 归属条目
        XCTAssertEqual(items.first?.path, "/Users/x/Library/Application Support/com.test.manual/data.txt")
        XCTAssertEqual(items.first?.evidence, "fact")
    }

    func testAddDuplicateReturnsExisting() throws {
        try db.insertApp(bundleID: "com.test.dup", name: "Dup", version: nil,
                         installPath: "/Applications/Dup.app", iconPath: nil,
                         firstSeen: 1, state: "tracked")
        // 构造真实 .app（重复检测需要先读 plist）
        let appDir = tempDir.appendingPathComponent("Dup.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let infoPlist: [String: Any] = [
            "CFBundleIdentifier": "com.test.dup",
            "CFBundleExecutable": "Dup",
            "CFBundleName": "Dup",
        ]
        try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
            .write(to: tempDir.appendingPathComponent("Dup.app/Contents/Info.plist"))
        FileManager.default.createFile(atPath: appDir.appendingPathComponent("Dup").path, contents: Data())

        let expectation = expectation(description: "dup")
        var message = ""
        service.addExistingApp(path: tempDir.appendingPathComponent("Dup.app").path) { result in
            message = result
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertTrue(message.contains("已在账本中"), "实际消息：\(message)")
    }
}
