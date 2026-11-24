import SwiftUI
import AppKit

/// 残留清单 Sheet（§14 / §10.4 四组核对 / §10.5 勾选规则 / §13 注册项只提示）。
struct ResidualSheet: View {
    @ObservedObject var model: AppModel
    let app: Database.AppSummary
    let database: Database

    @State private var items: [ResidualItem] = []
    @State private var checked = Set<String>()
    @State private var loading = true
    @State private var showConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            if let report = model.cleanupReport, report.bundleID == app.bundleID {
                ReportView(report: report)
            } else if loading {
                ProgressView("正在核对残留…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear(perform: load)
            } else {
                itemList
                bottomBar
            }
        }
        .frame(width: 720, height: 560)
        .overlay(alignment: .topTrailing) {
            Button("保留（不再提示）") {
                model.onKeep?(app.bundleID)
                model.residualSheetApp = nil
            }
            .controlSize(.small)
            .padding(10)
        }
    }

    // MARK: - 清单

    private var itemList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    ItemRow(item: item, isChecked: checked.contains(item.id)) { toggle in
                        if toggle { checked.insert(item.id) } else { checked.remove(item.id) }
                    }
                    Divider()
                }
            }
            .padding(12)
        }
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

                Text(item.row.evidence == "fact" ? "确证" : "推断")
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

// MARK: - 报告（§14：删了什么 / 留了什么 / 怎么恢复）

private struct ReportView: View {
    let report: CleanupReport

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("清理报告")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("删了什么（\(report.trashed.count) 项，已在废纸篓）")
                    .font(.headline)
                ForEach(report.trashed, id: \.path) { item in
                    Text("\(item.path)（\(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))）")
                        .font(.caption)
                        .textSelection(.enabled)
                }
                if report.trashed.isEmpty { Text("（无）").font(.caption).foregroundStyle(.secondary) }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("留了什么（\(report.skipped.count + report.kept.count) 项）")
                    .font(.headline)
                ForEach(report.skipped, id: \.path) { item in
                    Text("\(item.path)（\(item.reason)）")
                        .font(.caption)
                        .textSelection(.enabled)
                }
                ForEach(report.kept, id: \.self) { path in
                    Text("\(path)（未勾选）")
                        .font(.caption)
                        .textSelection(.enabled)
                }
                if report.skipped.isEmpty && report.kept.isEmpty { Text("（无）").font(.caption).foregroundStyle(.secondary) }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("怎么恢复")
                    .font(.headline)
                Text("废纸篓中的项目：打开废纸篓 → 右键 → 放回原处。系统项未删除，仅给出处理命令。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let path = report.reportPath {
                Text("报告已导出：\(path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
