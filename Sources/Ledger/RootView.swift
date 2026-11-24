import SwiftUI
import Charts
import UniformTypeIdentifiers

struct RootView: View {
    @ObservedObject var model: AppModel
    let database: Database
    let settings: SettingsService

    var body: some View {
        TabView {
            OverviewView(model: model)
                .tabItem { Label("概览", systemImage: "square.grid.2x2") }

            PendingView(model: model, database: database)
                .tabItem { Label("待处理", systemImage: "tray") }

            WeeklyView(model: model, database: database)
                .tabItem { Label("周报", systemImage: "chart.bar.xaxis") }

            SettingsView(model: model, settings: settings, database: database)
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .frame(minWidth: 780, minHeight: 520)
        .sheet(item: $model.residualSheetApp) { app in
            ResidualSheet(model: model, app: app, database: database)
        }
        .onChange(of: model.residualSheetApp?.bundleID) { _ in
            if model.residualSheetApp == nil {
                model.cleanupReport = nil  // 关闭清单时清掉上次报告
            }
        }
    }

}
private struct OverviewView: View {
    @ObservedObject var model: AppModel
    @State private var showImporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top) {
                    PageHeader(
                        title: "概览",
                        subtitle: "安装时记账，卸载时对账。"
                    )
                    Spacer()
                    Button {
                        showImporter = true
                    } label: {
                        Label("添加 App", systemImage: "plus")
                    }
                    .help("手动登记一个已安装的 App（识别轨，尽力而为）")
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                    MetricCard(title: "已记录 App", value: "\(model.apps.count)", systemImage: "square.stack.3d.up")
                    MetricCard(title: "未知项", value: "\(model.unknownCount)", systemImage: "questionmark.circle")
                    MetricCard(title: "今日新增", value: ByteCountFormatter.string(fromByteCount: model.todayNewBytes, countStyle: .file), systemImage: "arrow.down.circle")
                }

                BaselineCard(model: model)

                VStack(alignment: .leading, spacing: 12) {
                    Text("App 足迹")
                        .font(.headline)
                    if model.apps.isEmpty {
                        EmptyState(
                            systemImage: "book.closed",
                            title: "还没有记账记录",
                            message: "新安装的 App 稳定后，会在这里留下完整足迹。也可以点右上角「添加 App」手动登记已装的 App。"
                        )
                    } else {
                        AppFootprintList(model: model)
                    }
                }
            }
            .padding(28)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [UTType(importedAs: "com.apple.application-bundle")]
        ) { result in
            if case .success(let url) = result {
                model.onAddApp?(url.path) { message in
                    model.addAppMessage = message
                }
            }
        }
        .alert(
            "添加 App",
            isPresented: Binding(
                get: { model.addAppMessage != nil },
                set: { if !$0 { model.addAppMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { model.addAppMessage = nil }
        } message: {
            Text(model.addAppMessage ?? "")
        }
    }
}

/// 待处理页（M4）：vanished、broken 按残留大小降序；vanished 带「只是移动了它？」撤销入口。
/// 顶部切换「待处理 / 历史」（操作痕迹时间线 + 清理报告）。
private struct PendingView: View {
    @ObservedObject var model: AppModel
    let database: Database
    @State private var segment = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    PageHeader(
                        title: "待处理",
                        subtitle: "已从应用程序文件夹消失、或安装未完成的 App。"
                    )
                    Spacer()
                    Picker("", selection: $segment) {
                        Text("待处理").tag(0)
                        Text("历史").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }

                if segment == 1 {
                    HistoryView(model: model, database: database)
                } else {
                    pendingList
                }
            }
            .padding(28)
        }
    }

    private var pendingList: some View {
        Group {
            if model.pendingApps.isEmpty {
                EmptyState(
                    systemImage: "tray",
                    title: "没有待处理项",
                    message: "App 被卸载后，它的残留会在这里等待你核对。"
                )
            } else {
                    VStack(spacing: 0) {
                        ForEach(model.pendingApps, id: \.bundleID) { app in
                            VStack(alignment: .leading, spacing: 8) {
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
                                            .font(.body.weight(.medium))
                                        Text(app.bundleID)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("\(app.fileCount) 项 · \(app.registrationCount) 注册项")
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                        Text(ByteCountFormatter.string(fromByteCount: app.footprint, countStyle: .file))
                                            .font(.callout.weight(.semibold))
                                            .monospacedDigit()
                                    }

                                    if app.state == "broken" {
                                        badge("安装未完成", color: .orange)
                                    } else {
                                        badge("已卸载", color: .red)
                                    }
                                }

                                if app.state == "vanished" {
                                    HStack {
                                        Spacer()
                                        Button("只是移动了它？标为移动") {
                                            model.onMarkAsMoved?(app.bundleID)
                                        }
                                        .controlSize(.small)
                                    }
                                }
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 4)
                            .contentShape(Rectangle())
                            .onTapGesture { model.openResiduals(app) }
                            Divider()
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5))
                    }
                }
            }
        }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

}
/// 历史（待处理页分区）：操作痕迹时间线 + 清理报告列表。
private struct HistoryView: View {
    @ObservedObject var model: AppModel
    let database: Database

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("操作记录")
                    .font(.headline)
                if model.historyEvents.isEmpty {
                    Text("暂无操作记录")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.historyEvents.prefix(120).enumerated()), id: \.offset) { _, event in
                        HStack(spacing: 8) {
                            Image(systemName: Self.kindIcon(event.kind))
                                .foregroundStyle(Self.kindColor(event.kind))
                                .frame(width: 18)
                            Text(event.name ?? event.bundleID)
                                .font(.callout.weight(.medium))
                            Text(Self.kindLabel(event.kind))
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Self.kindColor(event.kind).opacity(0.15), in: Capsule())
                            Text(event.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(Self.dateFormatter.string(from: Date(timeIntervalSince1970: event.ts)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("清理报告")
                    .font(.headline)
                if model.historyReports.isEmpty {
                    Text("还没有清理记录")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.historyReports) { report in
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(Self.dateFormatter.string(from: report.date))
                                .font(.callout)
                                .monospacedDigit()
                            Text("已清理 \(report.trashedCount) 项")
                                .font(.callout)
                            Spacer()
                            if let path = report.reportPath, !path.isEmpty {
                                Button("打开报告") {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                                }
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .onAppear {
            model.loadHistory(database: database)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "installed": return "已安装"
        case "broken": return "安装未完成"
        case "vanished": return "已卸载"
        case "restored": return "已恢复"
        case "settled": return "已处理"
        case "superseded": return "已替代"
        default: return kind
        }
    }

    static func kindIcon(_ kind: String) -> String {
        switch kind {
        case "installed": return "plus.circle.fill"
        case "broken": return "exclamationmark.triangle.fill"
        case "vanished": return "trash.fill"
        case "restored": return "arrow.uturn.backward.circle.fill"
        case "settled": return "checkmark.seal.fill"
        default: return "circle.fill"
        }
    }

    static func kindColor(_ kind: String) -> Color {
        switch kind {
        case "installed": return .green
        case "broken", "vanished": return .orange
        case "restored": return .blue
        default: return .gray
        }
    }
}

/// 周报页（M6）：主图堆叠柱状图（X=周一至周日，Y=新增字节，堆叠=App）+
/// 副图按 category 堆叠 + 抬头汇总 + 导出 Markdown（§14）。
private struct WeeklyView: View {
    @ObservedObject var model: AppModel
    let database: Database

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeader(
                    title: "周报",
                    subtitle: "本周新增了多少足迹，分别来自哪里。"
                )

                if let report = model.weekly {
                    header(report)
                    chartSection(report)
                    categorySection(report)
                    topApps(report)
                    todaySection()
                } else {
                    EmptyState(
                        systemImage: "chart.bar.xaxis",
                        title: "正在加载周报…",
                        message: "账本记录的变化会按周汇总。"
                    )
                }
            }
            .padding(28)
        }
        .onAppear {
            model.loadWeekly(database: database)
        }
    }

    private func header(_ report: WeeklyReport) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            MetricCard(
                title: "本周新增",
                value: ByteCountFormatter.string(fromByteCount: report.totalNewBytes, countStyle: .file),
                systemImage: "arrow.down.circle"
            )
            MetricCard(title: "新装 App", value: "\(report.newInstallCount)", systemImage: "square.stack.3d.up")
            MetricCard(title: "未知项", value: "\(report.unknownCount)", systemImage: "questionmark.circle")
            MetricCard(
                title: "移除（副指标）",
                value: ByteCountFormatter.string(fromByteCount: report.removedBytes, countStyle: .file),
                systemImage: "arrow.up.circle"
            )
        }
    }

    private func chartSection(_ report: WeeklyReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("每日新增（按 App 堆叠）")
                .font(.headline)
            Chart {
                ForEach(0..<7, id: \.self) { day in
                    ForEach(appRows(report, day: day), id: \.app) { row in
                        BarMark(
                            x: .value("日", WeeklyAggregator.dayNames[day]),
                            y: .value("字节", row.bytes)
                        )
                        .foregroundStyle(by: .value("App", row.app))
                    }
                }
            }
            .chartYAxisLabel("新增字节")
            .frame(height: 220)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5))
        }
    }

    private func categorySection(_ report: WeeklyReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("每日新增（按类别堆叠）")
                .font(.headline)
            Chart {
                ForEach(0..<7, id: \.self) { day in
                    ForEach(report.dayCategoryBytes[day]?.sorted(by: { $0.key < $1.key }) ?? [], id: \.key) { category, bytes in
                        BarMark(
                            x: .value("日", WeeklyAggregator.dayNames[day]),
                            y: .value("字节", bytes)
                        )
                        .foregroundStyle(by: .value("类别", category))
                    }
                }
            }
            .frame(height: 180)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5))
        }
    }

    private func todaySection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今日明细（按字节影响排序）")
                .font(.headline)
            if model.dailyChanges.isEmpty {
                Text("今天还没有记录到变化")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.dailyChanges.prefix(12).enumerated()), id: \.offset) { _, change in
                    HStack(spacing: 8) {
                        Image(systemName: change.kind == "created" ? "plus.circle.fill" : change.kind == "removed" ? "minus.circle.fill" : "pencil.circle.fill")
                            .foregroundStyle(change.kind == "created" ? .green : change.kind == "removed" ? .red : .secondary)
                            .frame(width: 18)
                        Text(change.appBundleID.map { model.weeklyAppNames[$0] ?? $0 } ?? "未知")
                            .font(.caption)
                            .frame(width: 110, alignment: .leading)
                            .lineLimit(1)
                        Text(change.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: abs(change.sizeDelta), countStyle: .file))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5))
        }
    }

    private func topApps(_ report: WeeklyReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Top5")
                    .font(.headline)
                Spacer()
                Button("导出 Markdown") {
                    let dir = AppPaths.supportDirectory.appendingPathComponent("reports", isDirectory: true)
                    model.weeklyExportPath = WeeklyExporter.export(
                        report: report, names: model.weeklyAppNames, to: dir
                    )?.path
                }
                if let path = model.weeklyExportPath {
                    Text("已导出：\(path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            ForEach(report.topApps, id: \.bundleID) { app in
                HStack {
                    Text(model.weeklyAppNames[app.bundleID] ?? app.bundleID)
                        .font(.callout)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: app.bytes, countStyle: .file))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func appRows(_ report: WeeklyReport, day: Int) -> [(app: String, bytes: Int64)] {
        (report.dayBytes[day] ?? [:]).sorted { $0.value > $1.value }.map { (app: $0.key, bytes: $0.value) }
    }
}

/// 已记账 App 列表（M3）：图标、名称、足迹大小、状态徽标 + 行菜单（查看清单/重新追踪）。
private struct AppFootprintList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(model.apps, id: \.bundleID) { app in
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
                            .font(.body.weight(.medium))
                        Text(app.version.map { "v\($0) · \(app.bundleID)" } ?? app.bundleID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(ByteCountFormatter.string(fromByteCount: app.footprint, countStyle: .file))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    badge(for: app)

                    Menu {
                        Button("查看残留清单") {
                            model.openResiduals(app)
                        }
                        if app.state == "settled" || app.state == "verified" {
                            Button("重新追踪") {
                                model.onResumeTracking?(app.bundleID)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)
                    .fixedSize()
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .onTapGesture { model.openResiduals(app) }
                Divider()
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5))
        }
    }

    private func badge(for app: Database.AppSummary) -> some View {
        let (text, color): (String, Color) = {
            if app.state == "broken" { return ("安装未完成", .orange) }
            if app.state == "vanished" { return ("已卸载", .red) }
            if app.state == "verified" { return ("已核对", .blue) }
            if app.state == "settled" { return ("已处理", .gray) }
            if app.hasSignatureWarning { return ("签名警告", .yellow) }
            return ("正常", .green)
        }()
        return Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

/// M2 基线状态卡：扫描进度、索引规模、事件与盲区。
private struct BaselineCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: stateIcon)
                    .foregroundStyle(.secondary)
                Text("基线状态")
                    .font(.headline)
                Spacer()
                Text(stateText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 16) {
                statusRow("索引条目", "\(model.indexCount)")
                statusRow("已处理事件", "\(model.eventsProcessed)")
                statusRow("盲区", "\(model.blindSpots.count)")
                statusRow("上次落盘", model.lastFlushAt.map(Self.formatter.string) ?? "—")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5))
        }
    }

    private var stateIcon: String {
        switch model.scanState {
        case .idle: return "hourglass"
        case .scanning: return "arrow.triangle.2.circlepath"
        case .ready: return "checkmark.circle"
        }
    }

    private var stateText: String {
        switch model.scanState {
        case .idle: return "等待扫描"
        case .scanning: return "扫描中：已扫 \(model.scannedCount) 项"
        case .ready: return "就绪"
        }
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

/// 设置页（M7）：扫描根勾选、权限状态、保留策略、通知、暂停、登录自启。
private struct SettingsView: View {
    @ObservedObject var model: AppModel
    let settings: SettingsService
    let database: Database
    @State private var changesCount = 0
    @State private var changesBytes: Int64 = 0
    @State private var changesOldest: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeader(
                    title: "设置",
                    subtitle: "Ledger 只在本机工作，不发送任何数据。"
                )

                section("扫描范围") {
                    Text("勾选要记账的目录。取消勾选会立即停止监听该目录，并从账本移除它的条目。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(ScanRoots.allRoots, id: \.path) { root in
                        Toggle(root.path, isOn: Binding(
                            get: { !SettingsService.disabledRoots(database: database).contains(root.path) },
                            set: { settings.setRootEnabled(root.path, enabled: $0) }
                        ))
                        .font(.callout)
                    }
                }

                section("权限状态") {
                    let hasFDA = settings.hasFullDiskAccess()
                    HStack {
                        Label(
                            hasFDA ? "完全磁盘访问权限：已授权" : "完全磁盘访问权限：未授权",
                            systemImage: hasFDA ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(hasFDA ? .green : .orange)
                        Spacer()
                        Button("打开系统设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                    Text("盲区：\(model.blindSpots.count) 处。未授权时受保护目录无法读取，Ledger 会如实标注盲区，不假装完整。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                section("记录数据（保留策略）") {
                    Text("自动保留 30 天；超过约 500MB 时自动清理最旧记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("\(changesCount) 条 · 约 \(ByteCountFormatter.string(fromByteCount: changesBytes, countStyle: .file))")
                            .font(.callout)
                        if let oldest = changesOldest {
                            Text("最旧：\(Self.dateFormatter.string(from: oldest))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("立即清理") {
                            settings.pruneNow()
                            reloadStats()
                        }
                        .controlSize(.small)
                    }
                }

                section("通知") {
                    Toggle("卸载时通知「还有 N 处残留」", isOn: Binding(
                        get: { settings.notificationsEnabled() },
                        set: { settings.setNotificationsEnabled($0) }
                    ))
                    Text("未授权系统通知时只显示菜单栏红点，不反复请求。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                section("暂停与启动") {
                    Toggle("暂停记录（菜单栏也可切换）", isOn: Binding(
                        get: { settings.isPaused() },
                        set: { settings.setPaused($0) }
                    ))
                    Toggle("登录时自动启动 Ledger", isOn: Binding(
                        get: { settings.launchAtLoginEnabled() },
                        set: { settings.setLaunchAtLogin($0) }
                    ))
                }
            }
            .padding(28)
        }
        .onAppear(perform: reloadStats)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func reloadStats() {
        let stats = settings.changesStats()
        changesCount = stats.count
        changesBytes = stats.estimatedBytes
        changesOldest = stats.oldestTs.map { Date(timeIntervalSince1970: $0) }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct PlaceholderTab: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let emptyTitle: String
    let emptyMessage: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeader(title: title, subtitle: subtitle)
                EmptyState(
                    systemImage: systemImage,
                    title: emptyTitle,
                    message: emptyMessage
                )
            }
            .padding(28)
        }
    }
}

private struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 26, weight: .semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 38)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5))
        }
    }
}

private struct EmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5))
        }
    }
}
