import Foundation
import os

/// M6 追踪（§6 ③）：FSEvents 变化 → changes 表。
/// 归属：路径按 §10.3 fact 规则匹配已知 bundle-id/名称；不中 → app_bundle_id 为 NULL（未知项）。
/// moved：同批内同 inode 的 removed+created 配对（原子保存/重命名），不产生字节变化（§14 口径）。
struct ChangeRecord {
    var ts: Double
    var path: String
    var appBundleID: String?
    var kind: String  // created|modified|removed|moved
    var sizeDelta: Int64
    var evidence: String
    var inode: Int64
}

final class ChangeTracker {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    /// 同批内 moved 配对（纯函数，可单测）：同 inode 的 removed+created → 一条 moved（delta 0）。
    /// shortcut: 跨批次的重命名（间隔 >0.5s）按 removed+created 记录，字节口径略有膨胀。
    static func matchMoves(_ records: [ChangeRecord]) -> [ChangeRecord] {
        let removedInodes = Set(records.filter { $0.kind == "removed" }.map(\.inode))
        let createdInodes = Set(records.filter { $0.kind == "created" }.map(\.inode))
        let movedInodes = removedInodes.intersection(createdInodes)

        var result: [ChangeRecord] = []
        result.reserveCapacity(records.count)
        for record in records {
            switch record.kind {
            case "removed" where movedInodes.contains(record.inode):
                continue  // 已配对为 moved
            case "created" where movedInodes.contains(record.inode):
                var copy = record
                copy.kind = "moved"
                copy.sizeDelta = 0
                result.append(copy)
            default:
                result.append(record)
            }
        }
        return result
    }

    /// 批量落库（带归属标注）。
    func record(_ records: [ChangeRecord], summaries: [(bundleID: String, name: String)]) throws {
        guard !records.isEmpty else { return }
        let attributed = records.map { record -> ChangeRecord in
            var copy = record
            if let (bundleID, evidence) = Self.attribute(path: record.path, summaries: summaries) {
                copy.appBundleID = bundleID
                copy.evidence = evidence
            } else {
                copy.evidence = "unknown"
            }
            return copy
        }
        try database.insertChanges(attributed.map {
            (ts: $0.ts, path: $0.path, appBundleID: $0.appBundleID, kind: $0.kind, sizeDelta: $0.sizeDelta, evidence: $0.evidence)
        })
    }

    /// §10.3：路径某段 == bundle-id 或以其开头、或与名称大小写不敏感相等 → fact 归属。
    static func attribute(path: String, summaries: [(bundleID: String, name: String)]) -> (bundleID: String, evidence: String)? {
        for summary in summaries {
            if Attribution.evidence(path: path, bundleID: summary.bundleID, names: [summary.name]) == "fact" {
                return (summary.bundleID, "fact")
            }
        }
        return nil
    }
}
