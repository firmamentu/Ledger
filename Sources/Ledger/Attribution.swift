import Foundation

/// §10 判定规则的纯函数实现（无 I/O，可单测）。
enum Attribution {

    // MARK: - evidence（§10.3）

    /// fact：路径某段目录名 == bundle-id、或以其开头（如 <bundle-id>.savedState）、
    /// 或与 CFBundleDisplayName/CFBundleName 大小写不敏感相等；否则 inference。
    static func evidence(path: String, bundleID: String?, names: [String]) -> String {
        let segments = path.split(separator: "/").map(String.init)
        let bundle = bundleID?.lowercased()
        for segment in segments {
            let lower = segment.lowercased()
            if let bundle, lower == bundle || lower.hasPrefix(bundle + ".") {
                return "fact"
            }
            for name in names where lower == name.lowercased() {
                return "fact"
            }
        }
        return "inference"
    }

    // MARK: - verdict（§10.1，路径段匹配）

    private static let safeSegments = ["Caches", "Logs", "HTTPStorages", "WebKit", "Saved Application State", "DiagnosticReports"]
    private static let cautionSegments = ["Application Support", "Containers", "Group Containers", "Application Scripts", "Preferences"]
    private static let dontTouchSegments = ["TCC", "BTM", "Keychain", "System Extensions"]

    /// 注册项 verdict（§10.1 未列其余注册项 → unknown，禁止猜测）；
    /// system_extension/btm/tcc 明确归 dont_touch。
    static func verdict(path: String?, registrationKind: String?) -> String {
        if let registrationKind {
            switch registrationKind {
            case "system_extension", "btm", "tcc":
                return "dont_touch"
            default:
                return "unknown"
            }
        }
        guard let path else { return "unknown" }
        let segments = path.split(separator: "/").map(String.init)
        for segment in segments {
            if dontTouchSegments.contains(segment) { return "dont_touch" }
            if cautionSegments.contains(segment) { return "caution" }
            if safeSegments.contains(segment) { return "safe" }
        }
        return "unknown"
    }

    // MARK: - requires_admin（§10.2）

    static func requiresAdmin(path: String?, registrationKind: String?) -> Bool {
        if let registrationKind {
            return registrationKind != "launch_agent"  // 用户级 launch_agent 无需管理员
        }
        guard let path else { return false }
        return path.hasPrefix("/Library/LaunchAgents/")
            || path.hasPrefix("/Library/LaunchDaemons/")
            || path.hasPrefix("/Library/PrivilegedHelperTools/")
    }

    // MARK: - category（§8）

    static func category(path: String?, registrationKind: String?) -> String {
        if registrationKind != nil { return "registration" }
        guard let path else { return "unknown" }
        let segments = path.split(separator: "/").map(String.init)
        if segments.contains("Caches") { return "cache" }
        if segments.contains("Logs") { return "log" }
        if segments.contains("Preferences") { return "preference" }
        if segments.contains("Application Support")
            || segments.contains("Containers")
            || segments.contains("Group Containers")
            || segments.contains("Application Scripts")
            || segments.contains("Saved Application State")
            || segments.contains("HTTPStorages")
            || segments.contains("WebKit") {
            return "app_data"
        }
        return "unknown"
    }

    // MARK: - manifest_items 三集合并（§5.3.6）

    /// a. mtime 落在安装窗口；b. 当前索引存在但 pre 不存在；c. 前后均存在但 size 变化。
    /// 排除 app 自身子树；pre 为 nil（基线未完成）时只有 a 集合。
    static func selectItemPaths(
        current: [String: IndexEntry],
        pre: [String: IndexEntry]?,
        window: ClosedRange<Double>,
        excludeSubtree: String
    ) -> Set<String> {
        var paths = Set<String>()

        for (path, entry) in current where window.contains(entry.mtime) {
            paths.insert(path)
        }
        if let pre {
            for path in current.keys where pre[path] == nil {
                paths.insert(path)
            }
            for (path, entry) in current {
                if let old = pre[path], old.size != entry.size {
                    paths.insert(path)
                }
            }
        }
        return paths.filter { $0 != excludeSubtree && !$0.hasPrefix(excludeSubtree + "/") }
    }
}
