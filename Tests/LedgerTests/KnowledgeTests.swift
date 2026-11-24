import XCTest
@testable import Ledger

/// §11 解释层匹配优先级：最长 path_prefix → filename_suffix → registration_kind → bundle_dir → 未收录。
final class KnowledgeTests: XCTestCase {
    private var knowledge: Knowledge!

    override func setUpWithError() throws {
        let json = """
        [
          {"id":"caches","match":{"type":"path_prefix","value":"~/Library/Caches/"},
           "category":"cache","verdict":"safe","requires_admin":false,
           "title":"缓存","explanation":"临时数据","verify":"du -sh"},
          {"id":"cache-sub","match":{"type":"path_prefix","value":"~/Library/Caches/com.foo/"},
           "category":"cache","verdict":"safe","requires_admin":false,
           "title":"特定缓存","explanation":"某 App 的缓存","verify":"du -sh"},
          {"id":"plist","match":{"type":"filename_suffix","value":".plist"},
           "category":"preference","verdict":"caution","requires_admin":false,
           "title":"属性列表","explanation":"配置","verify":"plutil -p"},
          {"id":"receipt","match":{"type":"registration_kind","value":"receipt"},
           "category":"registration","verdict":"unknown","requires_admin":true,
           "title":"安装回执","explanation":"pkgutil --forget","verify":"pkgutil --pkgs"},
          {"id":"appdir","match":{"type":"bundle_dir","value":""},
           "category":"app_data","verdict":"caution","requires_admin":false,
           "title":"应用目录","explanation":"属于该 App","verify":"ls"}
        ]
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        knowledge = Knowledge(url: url)
        defer { try? FileManager.default.removeItem(at: url) }
    }

    func testLongestPrefixWins() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let result = knowledge.explanation(
            for: home + "/Library/Caches/com.foo/x", registrationKind: nil, bundleID: nil
        )
        XCTAssertEqual(result.title, "特定缓存")
    }

    func testPrefixFallback() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let result = knowledge.explanation(
            for: home + "/Library/Caches/other/x", registrationKind: nil, bundleID: nil
        )
        XCTAssertEqual(result.title, "缓存")
    }

    func testRegistrationKindFirst() {
        let result = knowledge.explanation(
            for: "registration:receipt:com.foo", registrationKind: "receipt", bundleID: nil
        )
        XCTAssertEqual(result.title, "安装回执")
    }

    func testSuffixMatch() {
        let result = knowledge.explanation(
            for: "/Users/x/Library/Preferences/com.foo.plist", registrationKind: nil, bundleID: nil
        )
        XCTAssertEqual(result.title, "属性列表")
    }

    func testBundleDirMatch() {
        let result = knowledge.explanation(
            for: "/Users/x/Library/Application Support/com.foo/data", registrationKind: nil, bundleID: "com.foo"
        )
        XCTAssertEqual(result.title, "应用目录")
    }

    func testUnknownFallback() {
        let result = knowledge.explanation(
            for: "/somewhere/else/thing.bin", registrationKind: nil, bundleID: nil
        )
        XCTAssertEqual(result.title, "未收录")
    }
}
