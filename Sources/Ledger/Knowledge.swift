import Foundation

/// §11 解释层：本地知识库（非 AI）。匹配优先级：最长 path_prefix → filename_suffix
/// → bundle_dir（目录名 == bundle-id）→ 全不中 = 未收录（禁止猜测）。
struct KnowledgeEntry: Codable {
    struct Match: Codable {
        var type: String
        var value: String
    }

    var id: String
    var match: Match
    var category: String
    var verdict: String
    var requiresAdmin: Bool
    var title: String
    var explanation: String
    var verify: String
}

final class Knowledge {
    static let shared = Knowledge(url: Bundle.main.url(forResource: "knowledge", withExtension: "json"))

    private var prefixEntries: [KnowledgeEntry] = []
    private var suffixEntries: [KnowledgeEntry] = []
    private var registrationEntries: [String: KnowledgeEntry] = [:]
    private var genericAppDir: KnowledgeEntry?

    private let unknownEntry = KnowledgeEntry(
        id: "unknown",
        match: .init(type: "fallback", value: ""),
        category: "unknown", verdict: "unknown", requiresAdmin: false,
        title: "未收录",
        explanation: "暂无解释",
        verify: "ls -la <path>"
    )

    /// 可注入 URL 便于测试；nil 时全部落到「未收录」。
    init(url: URL?) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase  // knowledge.json 用蛇形命名
        guard let url,
              let data = try? Data(contentsOf: url),
              let entries = try? decoder.decode([KnowledgeEntry].self, from: data) else {
            return
        }
        for entry in entries {
            switch entry.match.type {
            case "path_prefix": prefixEntries.append(entry)
            case "filename_suffix": suffixEntries.append(entry)
            case "registration_kind": registrationEntries[entry.match.value] = entry
            case "bundle_dir": genericAppDir = entry
            default: break
            }
        }
        // §11：最长 path_prefix / filename_suffix 优先
        prefixEntries.sort { $0.match.value.count > $1.match.value.count }
        suffixEntries.sort { $0.match.value.count > $1.match.value.count }
    }

    func explanation(for path: String, registrationKind: String?, bundleID: String?) -> (title: String, explanation: String, verify: String) {
        if let kind = registrationKind, let entry = registrationEntries[kind] {
            return (entry.title, entry.explanation, entry.verify)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for entry in prefixEntries {
            let expanded = entry.match.value.hasPrefix("~/")
                ? home + String(entry.match.value.dropFirst())
                : entry.match.value
            if path.hasPrefix(expanded) {
                return (entry.title, entry.explanation, entry.verify)
            }
        }

        for entry in suffixEntries where path.hasSuffix(entry.match.value) {
            return (entry.title, entry.explanation, entry.verify)
        }

        if let bundleID, let generic = genericAppDir,
           path.split(separator: "/").map(String.init).contains(bundleID) {
            return (generic.title, generic.explanation, generic.verify)
        }

        return (unknownEntry.title, unknownEntry.explanation, unknownEntry.verify)
    }
}
