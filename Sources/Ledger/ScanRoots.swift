import Foundation

/// §9 的 17 个扫描根 + ~/.Trash（仅监听、不扫描）。
enum ScanRoots {
    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// 17 个扫描根（展开为绝对路径；启用子集由 SettingsService 过滤）。
    static var allRoots: [URL] {
        let homeLibrary = home.appendingPathComponent("Library", isDirectory: true)
        return [
            homeLibrary.appendingPathComponent("Caches"),
            homeLibrary.appendingPathComponent("Containers"),
            homeLibrary.appendingPathComponent("Group Containers"),
            homeLibrary.appendingPathComponent("Application Support"),
            homeLibrary.appendingPathComponent("Logs"),
            homeLibrary.appendingPathComponent("HTTPStorages"),
            homeLibrary.appendingPathComponent("WebKit"),
            homeLibrary.appendingPathComponent("Saved Application State"),
            homeLibrary.appendingPathComponent("Preferences"),
            homeLibrary.appendingPathComponent("LaunchAgents"),
            homeLibrary.appendingPathComponent("Application Scripts"),
            URL(fileURLWithPath: "/Library/Application Support"),
            URL(fileURLWithPath: "/Library/Preferences"),
            URL(fileURLWithPath: "/Library/Logs"),
            URL(fileURLWithPath: "/Library/LaunchAgents"),
            URL(fileURLWithPath: "/Library/LaunchDaemons"),
            URL(fileURLWithPath: "/Library/PrivilegedHelperTools"),
        ]
    }

    static var trashURL: URL {
        home.appendingPathComponent(".Trash", isDirectory: true)
    }


    /// 判断路径是否在 ~/.Trash 下（M4 卸载判定用；M2 只跳过、不处理）。
    static func isUnderTrash(_ path: String) -> Bool {
        let trash = trashURL.path
        return path == trash || path.hasPrefix(trash + "/")
    }
}
