import SwiftUI
import AppKit

/// 残留清单 Sheet——面向普通用户的展示（目标用户 §1）：
/// 三色总结（可安全释放/谨慎处理/不会删除）+ 按类别分组（默认收起、组勾选）+
/// 大小降序 + 搜索与大文件筛选。技术细节（路径/evidence）降级为次要信息。
/// 勾选规则仍按 §10.5：默认 fact+safe；inference 永不默认；dont_touch/unknown/需管理员不可勾。
struct ResidualSheet: View {
    @ObservedObject var model: AppModel
    let app: Database.AppSummary
    let database: Database

    @State private var items: [ResidualItem] = []
    @State private var checked = Set<String>()
    @State private var defaultChecked = Set<String>()
    @State private var loading = true
    @State private var showConfirm = false
    @State private var filterText = ""
    @State private var onlyLarge = false
    @State private var expandedGroups = Set<String>()

    private var report: CleanupReport? {
        guard let report = model.cleanupReport, report.bundleID == app.bundleID else { return nil }
        return report
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let report {
                ReportView(report: report) {
                    model.residualSheetApp = nil
                }
            } else if loading {
                ProgressView("正在核对残留…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear(perform: load)
            } else {
                summaryBar
                Divider()
                toolbar
                groupList
                bottomBar
            }
        }
        .frame(width: 760, height: 600)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            if let iconPath = app.iconPath, let image = NSImage(contentsOfFile: iconPath) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 30, height: 30)
            } else {
                Image(systemName: "app")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.headline)
                Text("残留 \(app.fileCount) 项 · 共 \(ByteCountFormatter.string(fromByteCount: app.footprint, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if report == nil {
                Button("保留（不再提示）") {
                    model.onKeep?(app.bundleID)
                    model.residualSheetApp = nil
                }
                .controlSize(.small)
            }
            Button("关闭") {
                model.residualSheetApp = nil
            }
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - 三色总结

    private var summaryBar: some View {
        HStack(spacing: 10) {
            summaryCard("可安全释放", bytes: safeBytes, count: safeCount, color: .green, icon: "checkmark.circle.fill")
            summaryCard("谨慎处理", bytes: cautionBytes, count: cautionCount, color: .yellow, icon: "hand.raised.fill")
            summaryCard("不会删除", bytes: lockedBytes, count: lockedCount, color: .red, icon: "lock.fill")
        }
        .padding(12)
        .background(.bar)
    }

    private func summaryCard(_ title: String, bytes: Int64, count: Int, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
            Text("\(count) 项")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private var safeBytes: Int64 { items.filter { $0.group == .deletable && $0.row.verdict == "safe" }.reduce(0) { $0 + $1.row.size } }
    private var safeCount: Int { items.filter { $0.group == .deletable && $0.row.verdict == "safe" }.count }
    private var cautionBytes: Int64 { items.filter { $0.group == .deletable && $0.row.verdict == "caution" }.reduce(0) { $0 + $1.row.size } }
    private var cautionCount: Int { items.filter { $0.group == .deletable && $0.row.verdict == "caution" }.count }
    private var lockedBytes: Int64 { items.filter { $0.group == .admin || ($0.group == .deletable && $0.row.verdict != "safe" && $0.row.verdict != "caution") }.reduce(0) { $0 + $1.row.size } }
    private var lockedCount: Int { items.filter { $0.group == .admin || ($0.group == .deletable && $0.row.verdict != "safe" && $0.row.verdict != "caution") }.count }

    // MARK: - 工具条（搜索/大文件/恢复默认）

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索文件", text: $filterText)
                .textFieldStyle(.roundedBorder)
            Toggle("只看 ≥1MB", isOn: $onlyLarge)
                .toggleStyle(.checkbox)
                .font(.caption)
            Spacer()
            Text("已选 \(checked.count) 项 · \(ByteCountFormatter.string(fromByteCount: checkedBytes, countStyle: .file))")
                .font(.callout)
                .monospacedDigit()
            Button("恢复默认勾选") {
                checked = defaultChecked
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 分组列表

    private struct SheetGroup: Identifiable {
        enum Kind {
            case safeDeletable, cautionDeletable, locked, changed, gone, admin
        }

        var id: String
        var kind: Kind
        var title: String
        var subtitle: String
        var items: [ResidualItem]
        var bytes: Int64 { items.reduce(0) { $0 + $1.row.size } }
    }

    private var groups: [SheetGroup] {
        var buckets: [String: [ResidualItem]] = [:]
        for item in items {
            let kindKey: String
            switch item.group {
            case .deletable:
                switch item.row.verdict {
                case "safe": kindKey = "safe"
                case "caution": kindKey = "caution"
                default: kindKey = "locked"
                }
            case .changed: kindKey = "changed"
            case .gone: kindKey = "gone"
            case .admin: kindKey = "admin"
            }
            let category = Attribution.category(path: item.row.path, registrationKind: item.row.registrationKind)
            buckets["\(kindKey)|\(category)", default: []].append(item)
        }

        var result: [SheetGroup] = []
        for (key, bucket) in buckets {
            let parts = key.split(separator: "|")
            let kindKey = String(parts[0])
            let category = String(parts[1])
            let kind: SheetGroup.Kind = switch kindKey {
            case "safe": .safeDeletable
            case "caution": .cautionDeletable
            case "changed": .changed
            case "gone": .gone
            case "admin": .admin
            default: .locked
            }
            let filtered = bucket.filter { item in
                let matchesText = filterText.isEmpty
                    || item.row.path.localizedCaseInsensitiveContains(filterText)
                let matchesSize = !onlyLarge || item.row.size >= 1_000_000
                return matchesText && matchesSize
            }
            guard !filtered.isEmpty else { continue }
            // 组内按大小降序
            let sorted = filtered.sorted { $0.row.size > $1.row.size }
            let title = Knowledge.shared.explanation(
                for: sorted[0].row.path, registrationKind: sorted[0].row.registrationKind, bundleID: app.bundleID
            ).title
            result.append(SheetGroup(
                id: key,
                kind: kind,
                title: title,
                subtitle: "\(sorted.count) 项 · \(ByteCountFormatter.string(fromByteCount: sorted.reduce(0) { $0 + $1.row.size }, countStyle: .file))",
                items: sorted
            ))
        }
        return result.sorted { $0.bytes > $1.bytes }
    }

    private var groupList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if groups.isEmpty {
                    Text(filterText.isEmpty ? "没有残留条目" : "没有匹配的条目")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(20)
                } else {
                    ForEach(groups) { group in
                        groupRow(group)
                        if expandedGroups.contains(group.id) {
                            ForEach(group.items) { item in
                                itemRow(item, in: group)
                                Divider()
                            }
                        }
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    /// §10.5 可勾选：deletable/changed 且 verdict ∈ {safe, caution} 且非管理员、非注册项。
    /// dont_touch/unknown 永不可勾（即使组显示为可删组，如 verdict=dont_touch 的普通文件）。
    private func isCheckable(_ item: ResidualItem) -> Bool {
        (item.group == .deletable || item.group == .changed)
            && item.row.registrationKind == nil
            && !item.row.requiresAdmin
            && (item.row.verdict == "safe" || item.row.verdict == "caution")
    }

    private func groupRow(_ group: SheetGroup) -> some View {
        let checkable = group.items.filter { isCheckable($0) }
        let checkedCount = checkable.filter { checked.contains($0.id) }.count
        let icon: String = switch group.kind {
        case .safeDeletable: "checkmark.circle.fill"
        case .cautionDeletable: "hand.raised.fill"
        case .locked: "lock.fill"
        case .changed: "exclamationmark.triangle.fill"
        case .gone: "checkmark.circle"
        case .admin: "lock.fill"
        }
        let color: Color = switch group.kind {
        case .safeDeletable: .green
        case .cautionDeletable: .yellow
        case .locked, .admin: .red
        case .changed: .orange
        case .gone: .gray
        }
        let isExpanded = expandedGroups.contains(group.id)

        return HStack(spacing: 8) {
            if !checkable.isEmpty {
                Button {
                    if checkedCount == checkable.count {
                        for item in checkable { checked.remove(item.id) }
                    } else {
                        for item in checkable { checked.insert(item.id) }
                    }
                } label: {
                    Image(systemName: checkedCount == 0 ? "square" : checkedCount == checkable.count ? "checkmark.square.fill" : "minus.square.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("勾选/取消整组")
            } else {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 16)
            }

            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(color)

            Text(group.title)
                .font(.callout.weight(.medium))

            Text(group.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if expandedGroups.contains(group.id) {
                expandedGroups.remove(group.id)
            } else {
                expandedGroups.insert(group.id)
            }
        }
    }

    private func itemRow(_ item: ResidualItem, in group: SheetGroup) -> some View {
        HStack(spacing: 8) {
            if isCheckable(item) {
                Toggle("", isOn: Binding(
                    get: { checked.contains(item.id) },
                    set: { toggle in
                        if toggle { checked.insert(item.id) } else { checked.remove(item.id) }
                    }
                ))
                .labelsHidden()
            } else {
                Image(systemName: item.group == .admin ? "lock.fill" : "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }

            Text(Self.displayName(for: item.row.path))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.row.path)  // 悬停显示完整路径

            Spacer()

            Text(ByteCountFormatter.string(fromByteCount: item.row.size, countStyle: .file))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if item.group == .changed {
                Text("可能不是原来那个")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if item.group == .admin || item.row.registrationKind != nil {
                CommandCopyButton(command: item.explanation.verify)
            }
        }
        .padding(.vertical, 5)
        .padding(.leading, 30)
    }

    /// 路径弱化：只显示文件名 + 所属类别（悬停看全路径）。
    static func displayName(for path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let category = Attribution.category(path: path, registrationKind: nil)
        let categoryLabel = ReportPresentation.categoryTitle(category)
        return name.isEmpty ? path : "\(name) · \(categoryLabel)"
    }

    // MARK: - 底部

    private var bottomBar: some View {
        HStack {
            Text("已选 \(checked.count) 项 · 释放 \(ByteCountFormatter.string(fromByteCount: checkedBytes, countStyle: .file))")
                .font(.callout.weight(.medium))
                .monospacedDigit()
            Spacer()
            Button {
                showConfirm = true
            } label: {
                Label("移入废纸篓", systemImage: "trash")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .disabled(checked.isEmpty)
            .help("移入废纸篓后可还原；系统项不会删除")
        }
        .padding(12)
        .background(.bar)
        .confirmationDialog(
            "将把 \(checked.count) 项移入废纸篓，共 \(ByteCountFormatter.string(fromByteCount: checkedBytes, countStyle: .file))，可从废纸篓恢复。系统项不会删除，只给出处理方式。",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("移入废纸篓") {
                model.onCleanup?(app.bundleID, Array(checked), app.name)
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var checkedBytes: Int64 {
        items.filter { checked.contains($0.id) }.reduce(0) { $0 + $1.row.size }
    }

    // MARK: - 加载

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = (try? database.manifestItems(for: app.bundleID)) ?? []
            var loaded: [ResidualItem] = []
            var defaults = Set<String>()
            for row in rows {
                let group = Self.classify(row)
                let explanation = Knowledge.shared.explanation(
                    for: row.path, registrationKind: row.registrationKind, bundleID: app.bundleID
                )
                // §10.5：默认勾选 = fact + safe + 非管理员 + 可删组
                if group == .deletable, row.evidence == "fact", row.verdict == "safe", !row.requiresAdmin {
                    defaults.insert(row.path)
                }
                loaded.append(ResidualItem(row: row, group: group, explanation: explanation))
            }
            DispatchQueue.main.async {
                self.items = loaded
                self.checked = defaults
                self.defaultChecked = defaults
                self.loading = false
                // 展开第一个可删组，给用户即时反馈
                if let first = self.groups.first(where: { $0.kind == .safeDeletable || $0.kind == .cautionDeletable }) {
                    self.expandedGroups = [first.id]
                }
            }
        }
    }

    static func classify(_ row: Database.ManifestItemRow) -> ResidualGroup {
        if row.registrationKind != nil { return .admin }
        var st = stat()
        guard lstat(row.path, &st) == 0 else { return .gone }
        let size = st.st_size
        let inode = Int64(st.st_ino)
        guard size == row.size, inode == row.inode else { return .changed }
        return row.requiresAdmin ? .admin : .deletable
    }
}

enum ResidualGroup {
    case deletable
    case changed
    case gone
    case admin
}

struct ResidualItem: Identifiable {
    var id: String { row.path }
    let row: Database.ManifestItemRow
    let group: ResidualGroup
    let explanation: (title: String, explanation: String, verify: String)
}

/// 小型复制命令按钮（§13：只提示，禁止代执行）。
private struct CommandCopyButton: View {
    let command: String

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(command, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.caption2)
        }
        .buttonStyle(.borderless)
        .help("复制处理命令（Ledger 不代执行）")
    }
}

// MARK: - 报告（人读化：总结 → 按类别 → 留了什么 → 怎么恢复）

private struct ReportView: View {
    let report: CleanupReport
    let onClose: () -> Void

    private var totalBytes: Int64 {
        report.trashed.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summaryCard

                sectionTitle("已清理（按类别）", subtitle: "全部在废纸篓中，可还原")
                let groups = CleanupService.trashedGroups(report, bundleID: report.bundleID)
                if groups.isEmpty {
                    Text("（无）").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(groups, id: \.title) { group in
                        DisclosureGroup {
                            ForEach(group.paths.prefix(10), id: \.path) { item in
                                Text(item.path)
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                            if group.paths.count > 10 {
                                Text("…还有 \(group.paths.count - 10) 项")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } label: {
                            HStack {
                                Text(group.title)
                                    .font(.callout.weight(.medium))
                                Text("\(group.count) 项 · \(ByteCountFormatter.string(fromByteCount: group.bytes, countStyle: .file))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                sectionTitle("留了什么", subtitle: "已变化或未勾选的项目未被删除")
                keptSection

                sectionTitle("怎么恢复", subtitle: nil)
                Text("废纸篓中的项目：打开废纸篓 → 右键 → 放回原处。系统项本报告不代执行，处理命令见残留清单。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let path = report.reportPath {
                    Text("报告已导出：\(path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(18)
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 14) {
            summaryStat("已清理", "\(report.trashed.count) 项", color: .green)
            summaryStat("释放空间", ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file), color: .blue)
            summaryStat("跳过", "\(report.skipped.count) 项", color: .orange)
            summaryStat("保留", "\(report.kept.count) 项", color: .gray)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5))
        }
    }

    private func summaryStat(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionTitle(_ title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var keptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            let changed = report.skipped.filter { $0.reason.contains("已变化") }
            let failed = report.skipped.filter { $0.reason.contains("删除失败") }
            let system = report.kept.filter { $0.reason == "系统项，不代执行" }
            let unchecked = report.kept.filter { $0.reason == "未勾选" }
            let other = report.skipped.filter {
                !$0.reason.contains("已变化") && !$0.reason.contains("删除失败")
            }

            if changed.isEmpty && failed.isEmpty && system.isEmpty && unchecked.isEmpty && other.isEmpty {
                Text("（无）").font(.caption).foregroundStyle(.secondary)
            } else {
                if !changed.isEmpty {
                    keptRow("已变化（可能不是原来那个）", changed.count, items: changed.map(\.path))
                }
                if !failed.isEmpty {
                    keptRow("删除失败", failed.count, items: failed.map(\.path))
                }
                if !system.isEmpty {
                    keptRow("系统项（不代执行）", system.count, items: system.map(\.path))
                }
                if !unchecked.isEmpty {
                    keptRow("未勾选", unchecked.count, items: unchecked.map(\.path))
                }
                if !other.isEmpty {
                    keptRow("其他", other.count, items: other.map(\.path))
                }
            }
        }
    }

    private func keptRow(_ title: String, _ count: Int, items: [String]) -> some View {
        DisclosureGroup {
            ForEach(items.prefix(10), id: \.self) { path in
                Text(path)
                    .font(.caption)
                    .textSelection(.enabled)
            }
            if items.count > 10 {
                Text("…还有 \(items.count - 10) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Text("\(title)（\(count) 项）")
                .font(.callout)
        }
    }
}
