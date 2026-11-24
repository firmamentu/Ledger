import SwiftUI
import AppKit

/// 残留清单 Sheet（§14 / §10.4 四组核对 / §10.5 勾选规则 / §13 注册项只提示）。
/// 分区：确证归属（fact，与 App 直接相关）常显；推断归属（安装窗口内变化）默认折叠。
struct ResidualSheet: View {
    @ObservedObject var model: AppModel
    let app: Database.AppSummary
    let database: Database

    @State private var items: [ResidualItem] = []
    @State private var checked = Set<String>()
    @State private var loading = true
    @State private var showConfirm = false
    @State private var showInference = false

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
                itemList
                bottomBar
            }
        }
        .frame(width: 740, height: 580)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let iconPath = app.iconPath, let image = NSImage(contentsOfFile: iconPath) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: "app")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.headline)
                Text("\(app.fileCount) 项 · \(app.registrationCount) 注册项")
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

    // MARK: - 清单（fact/inference 分区）

    private var factItems: [ResidualItem] {
        items.filter { $0.row.evidence == "fact" }
    }

    private var inferenceItems: [ResidualItem] {
        items.filter { $0.row.evidence != "fact" }
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                sectionHeader("确证归属", subtitle: "与 \(app.name) 直接相关 · \(factItems.count) 项")
                ForEach(factItems) { item in
                    ItemRow(item: item, isChecked: checked.contains(item.id)) { toggle in
                        if toggle { checked.insert(item.id) } else { checked.remove(item.id) }
                    }
                    Divider()
                }

                if !inferenceItems.isEmpty {
                    DisclosureGroup(isExpanded: $showInference) {
                        ForEach(inferenceItems) { item in
                            ItemRow(item: item, isChecked: checked.contains(item.id)) { toggle in
                                if toggle { checked.insert(item.id) } else { checked.remove(item.id) }
                            }
                            Divider()
                        }
                    } label: {
                        sectionHeader(
                            "推断归属",
                            subtitle: "安装窗口内变化 · \(inferenceItems.count) 项 · 默认不勾选"
                        )
                        .padding(.top, 12)
                    }
                }
            }
            .padding(12)
        }
    }

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    private var bottomBar: some View {
        HStack {
            Text("已选 \(checked.count) 项 · 共 \(ByteCountFormatter.string(fromByteCount: checkedBytes, countStyle: .file))")
                .font(.callout)
            Spacer()
            Button("移入废纸篓") {
                showConfirm = true
            }
            .disabled(checked.isEmpty)
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
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

    // MARK: - 加载与四组核对（§10.4）

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
                self.loading = false
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
    case deletable   // 可删：存在 + size/inode 一致 + 非管理员
    case changed     // 已变化：默认不勾选，提示「可能不是原来那个」
    case gone        // 已消失
    case admin       // 需管理员：不可勾选，仅展示处理方式（含注册项）
}

struct ResidualItem: Identifiable {
    var id: String { row.path }
    let row: Database.ManifestItemRow
    let group: ResidualGroup
    let explanation: (title: String, explanation: String, verify: String)
}

// MARK: - 行

private struct ItemRow: View {
    let item: ResidualItem
    let isChecked: Bool
    let onToggle: (Bool) -> Void

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if item.group == .deletable || item.group == .changed {
                    Toggle("", isOn: Binding(get: { isChecked }, set: onToggle))
                        .labelsHidden()
                } else {
                    Image(systemName: item.group == .admin ? "lock" : "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                }

                Text(item.row.path)
                    .font(.callout)
                    .lineLimit(expanded ? nil : 1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Spacer()

                Text(ByteCountFormatter.string(fromByteCount: item.row.size, countStyle: .file))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                GroupBadge(group: item.group)

                Text(item.row.verdict == "safe" ? "可删" : item.row.verdict == "caution" ? "谨慎" : item.row.verdict == "dont_touch" ? "勿动" : "未知")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())

                Text(item.row.requiresAdmin ? "需管理员" : "用户级")
                    .font(.caption2)
                    .foregroundStyle(item.row.requiresAdmin ? .orange : .secondary)

                Text(evidenceLabel(item.row.evidence))
                    .font(.caption2)
                    .foregroundStyle(item.row.evidence == "fact" ? .green : .secondary)

                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.explanation.title)
                        .font(.callout.weight(.semibold))
                    Text(item.explanation.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if item.group == .admin || item.row.registrationKind != nil {
                        CommandRow(command: item.explanation.verify)
                    }
                }
                .padding(.leading, 26)
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
    }

    private func evidenceLabel(_ evidence: String) -> String {
        switch evidence {
        case "fact": return "确证"
        case "inference": return "推断"
        default: return "未知"
        }
    }
}

private struct GroupBadge: View {
    let group: ResidualGroup

    var body: some View {
        let (text, color): (String, Color) = switch group {
        case .deletable: ("可删", .green)
        case .changed: ("已变化", .orange)
        case .gone: ("已消失", .gray)
        case .admin: ("需管理员", .orange)
        }
        return Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

/// §13：只提示命令 + 复制按钮，禁止代执行。
private struct CommandRow: View {
    let command: String

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            Button("复制命令") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(command, forType: .string)
            }
            .controlSize(.mini)
        }
        .padding(6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
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
