import XCTest
@testable import Ledger

/// M6 追踪：moved 配对（同 inode 的 removed+created → moved，字节口径不变）与归属判定。
final class ChangeTrackerTests: XCTestCase {

    func testMatchMovesPairsSameInode() {
        let records = [
            ChangeRecord(ts: 1, path: "/x/old", appBundleID: nil, kind: "removed", sizeDelta: -10, evidence: "unknown", inode: 42),
            ChangeRecord(ts: 1, path: "/x/new", appBundleID: nil, kind: "created", sizeDelta: 10, evidence: "unknown", inode: 42),
        ]
        let matched = ChangeTracker.matchMoves(records)
        XCTAssertEqual(matched.count, 1)
        XCTAssertEqual(matched[0].kind, "moved")
        XCTAssertEqual(matched[0].sizeDelta, 0)
        XCTAssertEqual(matched[0].path, "/x/new")
    }

    func testMatchMovesLeavesUnmatchedAlone() {
        let records = [
            ChangeRecord(ts: 1, path: "/x/gone", appBundleID: nil, kind: "removed", sizeDelta: -3, evidence: "unknown", inode: 1),
            ChangeRecord(ts: 1, path: "/x/new", appBundleID: nil, kind: "created", sizeDelta: 3, evidence: "unknown", inode: 2),
        ]
        let matched = ChangeTracker.matchMoves(records)
        XCTAssertEqual(matched.count, 2)
        XCTAssertTrue(matched.contains { $0.kind == "removed" })
        XCTAssertTrue(matched.contains { $0.kind == "created" })
    }

    func testAttributeByBundleIDAndName() {
        let summaries = [("com.foo.app", "Foo App")]
        XCTAssertEqual(
            ChangeTracker.attribute(path: "/Users/x/Library/Application Support/com.foo.app/data", summaries: summaries)?.bundleID,
            "com.foo.app"
        )
        XCTAssertEqual(
            ChangeTracker.attribute(path: "/Users/x/Library/Caches/foo app/x", summaries: summaries)?.bundleID,
            "com.foo.app"
        )
        XCTAssertNil(ChangeTracker.attribute(path: "/Users/x/Library/Caches/unrelated", summaries: summaries))
    }
}
