import XCTest
@testable import Ledger

/// §10 判定规则纯函数（M3 记账的核心判定）。
final class AttributionTests: XCTestCase {

    // MARK: - evidence（§10.3）

    func testEvidenceFactByBundleIDSegment() {
        let path = "/Users/x/Library/Application Support/com.foo.app/data.db"
        XCTAssertEqual(Attribution.evidence(path: path, bundleID: "com.foo.app", names: ["Foo"]), "fact")
    }

    func testEvidenceFactByBundleIDPrefix() {
        let path = "/Users/x/Library/Saved Application State/com.foo.app.savedState/data"
        XCTAssertEqual(Attribution.evidence(path: path, bundleID: "com.foo.app", names: ["Foo"]), "fact")
    }

    func testEvidenceFactByNameCaseInsensitive() {
        let path = "/Users/x/Library/Application Support/foo app/config.json"
        XCTAssertEqual(Attribution.evidence(path: path, bundleID: "com.foo.app", names: ["Foo App"]), "fact")
    }

    func testEvidenceInferenceWhenNoMatch() {
        let path = "/Users/x/Library/Caches/unrelated-cache/data"
        XCTAssertEqual(Attribution.evidence(path: path, bundleID: "com.foo.app", names: ["Foo"]), "inference")
    }

    // MARK: - verdict（§10.1）

    func testVerdictBySegment() {
        XCTAssertEqual(Attribution.verdict(path: "/x/Caches/foo", registrationKind: nil), "safe")
        XCTAssertEqual(Attribution.verdict(path: "/x/Application Support/foo", registrationKind: nil), "caution")
        XCTAssertEqual(Attribution.verdict(path: "/x/TCC/foo", registrationKind: nil), "dont_touch")
        XCTAssertEqual(Attribution.verdict(path: "/x/elsewhere", registrationKind: nil), "unknown")
    }

    func testVerdictForRegistrations() {
        XCTAssertEqual(Attribution.verdict(path: nil, registrationKind: "system_extension"), "dont_touch")
        XCTAssertEqual(Attribution.verdict(path: nil, registrationKind: "receipt"), "unknown")
    }

    // MARK: - requires_admin（§10.2）

    func testRequiresAdmin() {
        XCTAssertTrue(Attribution.requiresAdmin(path: "/Library/LaunchDaemons/com.foo.plist", registrationKind: nil))
        XCTAssertFalse(Attribution.requiresAdmin(path: "/Users/x/Library/LaunchAgents/com.foo.plist", registrationKind: nil))
        XCTAssertTrue(Attribution.requiresAdmin(path: nil, registrationKind: "receipt"))
        XCTAssertFalse(Attribution.requiresAdmin(path: nil, registrationKind: "launch_agent"))
    }

    // MARK: - category（§8）

    func testCategory() {
        XCTAssertEqual(Attribution.category(path: "/x/Caches/foo", registrationKind: nil), "cache")
        XCTAssertEqual(Attribution.category(path: "/x/Logs/foo", registrationKind: nil), "log")
        XCTAssertEqual(Attribution.category(path: "/x/Preferences/foo", registrationKind: nil), "preference")
        XCTAssertEqual(Attribution.category(path: nil, registrationKind: "receipt"), "registration")
    }

    // MARK: - 三集合并（§5.3.6）

    func testSelectItemsThreeSetsAndExclusion() {
        let window = 100.0...200.0
        let current: [String: IndexEntry] = [
            "/x/in-window": IndexEntry(size: 1, mtime: 150, inode: 1),     // a
            "/x/new-file": IndexEntry(size: 2, mtime: 999, inode: 2),      // b（不在窗口、pre 无）
            "/x/changed": IndexEntry(size: 9, mtime: 999, inode: 3),       // c（size 变化）
            "/x/unchanged": IndexEntry(size: 4, mtime: 999, inode: 4),     // 都不中
            "/Apps/Foo.app/x": IndexEntry(size: 5, mtime: 150, inode: 5),  // 排除子树
        ]
        let pre: [String: IndexEntry] = [
            "/x/changed": IndexEntry(size: 1, mtime: 50, inode: 3),
            "/x/unchanged": IndexEntry(size: 4, mtime: 50, inode: 4),
        ]
        let selected = Attribution.selectItemPaths(
            current: current, pre: pre, window: window, excludeSubtree: "/Apps/Foo.app"
        )
        XCTAssertEqual(selected, ["/x/in-window", "/x/new-file", "/x/changed"])
    }

    func testSelectItemsWithoutPreOnlyUsesWindow() {
        let current: [String: IndexEntry] = [
            "/x/in-window": IndexEntry(size: 1, mtime: 150, inode: 1),
            "/x/outside": IndexEntry(size: 2, mtime: 999, inode: 2),
        ]
        let selected = Attribution.selectItemPaths(
            current: current, pre: nil, window: 100.0...200.0, excludeSubtree: "/Apps"
        )
        XCTAssertEqual(selected, ["/x/in-window"])
    }
}
