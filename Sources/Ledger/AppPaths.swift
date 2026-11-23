import Foundation

enum AppPaths {
    // Info.plist 的 CFBundleIdentifier 是唯一真源
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.ledger.app"

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(bundleID)", isDirectory: true)
    }

    static var databaseURL: URL {
        supportDirectory.appendingPathComponent("ledger.sqlite", isDirectory: false)
    }

    static var lockURL: URL {
        supportDirectory.appendingPathComponent("ledger.lock", isDirectory: false)
    }
}
