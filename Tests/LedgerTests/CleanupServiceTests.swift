import XCTest
@testable import Ledger

/// M5 清理执行（§10.5）：真实移废纸篓、删除前校验、跳过记录、报告落盘、settled。
final class CleanupServiceTests: XCTestCase {
    private var tempDir: URL!
    private var db: Database!
    private var model: AppModel!
    private var service: CleanupService!
    private var trashedName = "ledger-cleanup-test-\(UUID().uuidString).txt"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try Database(url: tempDir.appendingPathComponent("test.sqlite"))
        model = AppModel()
        service = CleanupService(database: db, model: model, supportDirectory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: ScanRoots.trashURL.appendingPathComponent(trashedName))
    }

    private func waitForSettled(_ bundleID: String, timeout: TimeInterval = 10) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var state: String?
        repeat {
            state = (try? db.appSummaries().first { $0.bundleID == bundleID })?.state
            if state == "settled" { break }
            usleep(100_000)
        } while Date() < deadline
        return state
    }

    func testCleanupTrashesSkipsAndReports() throws {
        // a：可删（正确 size/inode）；b：已变化；c：已消失
        let fileA = tempDir.appendingPathComponent(trashedName)
        try "hello".write(to: fileA, atomically: true, encoding: .utf8)
        var st = stat()
        lstat(fileA.path, &st)
        let sizeA = st.st_size
        let inodeA = Int64(st.st_ino)

        let fileB = tempDir.appendingPathComponent("b.txt")
        try "world".write(to: fileB, atomically: true, encoding: .utf8)
        let fileC = tempDir.appendingPathComponent("gone.txt")

        try db.insertApp(bundleID: "com.test.clean", name: "Clean", version: nil,
                         installPath: "/Applications/Clean.app", iconPath: nil,
                         firstSeen: 1, state: "vanished")
        let manifestID = try db.insertManifest(appBundleID: "com.test.clean", start: 1, finish: 2,
                                               observedScope: "[]", blindSpots: "[]",
                                               status: "complete", createdAt: 2)
        try db.insertManifestItems([
            (manifestID, fileA.path, "file", "app_data", sizeA, 2, inodeA, nil, "safe", false, "fact"),
            (manifestID, fileB.path, "file", "app_data", 999, 2, 999, nil, "safe", false, "fact"),
            (manifestID, fileC.path, "file", "app_data", 1, 2, 1, nil, "safe", false, "fact"),
        ])

        service.cleanup(bundleID: "com.test.clean", checkedPaths: [fileA.path, fileB.path, fileC.path], appName: "Clean")

        XCTAssertEqual(waitForSettled("com.test.clean"), "settled")

        // a 已移入废纸篓（§16.4 可还原的落点）；b 原地未动；c 无操作
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ScanRoots.trashURL.appendingPathComponent(trashedName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileB.path))

        // 报告文件已生成 + reports 表有记录
        let reportsDir = tempDir.appendingPathComponent("reports")
        let reportFiles = try FileManager.default.contentsOfDirectory(atPath: reportsDir.path)
        XCTAssertEqual(reportFiles.count, 1)
        XCTAssertTrue(reportFiles[0].hasPrefix("uninstall-com.test.clean-"))
        let report = try String(contentsOf: reportsDir.appendingPathComponent(reportFiles[0]), encoding: .utf8)
        XCTAssertTrue(report.contains("删了什么"))
        XCTAssertTrue(report.contains("已变化"))
        XCTAssertTrue(report.contains("怎么恢复"))
    }
}
