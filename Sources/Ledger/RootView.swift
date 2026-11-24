import SwiftUI
import Charts

struct RootView: View {
    @ObservedObject var model: AppModel
    let database: Database

    var body: some View {
        TabView {
            OverviewView(model: model)
                .tabItem { Label("概览", systemImage: "square.grid.2x2") }

            PendingView(model: model)
                .tabItem { Label("待处理", systemImage: "tray") }

            WeeklyView(model: model, database: database)
                .tabItem { Label("周报", systemImage: "chart.bar.xaxis") }

            SettingsView(model: model)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeader(
                    title: "概览",
                    subtitle: "安装时记账，卸载时对账。"
                )

                HStack(spacing: 12) {
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
                            message: "新安装的 App 稳定后，会在这里留下完整足迹。"
                        )
                    } else {
                        AppFootprintList(apps: model.apps) { app in
                            model.openResiduals(app)
                        }
                    }
                }
            }
            .padding(28)
        }
    }
}

/// 待处理页（M4）：vanished、broken 按残留大小降序；vanished 带「只是移动了它？」撤销入口。
private struct PendingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeader(
                    title: "待处理",
                    subtitle: "已从应用程序文件夹消失、或安装未完成的 App。"
                )

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
            .padding(28)
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
        HStack(spacing: 12) {
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

/// 已记账 App 列表（M3）：图标、名称、足迹大小、状态徽标。
private struct AppFootprintList: View {
    let apps: [Database.AppSummary]
    let onOpen: (Database.AppSummary) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(apps, id: \.bundleID) { app in
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
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .onTapGesture { onOpen(app) }
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

/// M2 版设置页：真实展示扫描状态与盲区；勾选/保留策略/暂停等 M7 接入。
private struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeader(
                    title: "设置",
                    subtitle: "Ledger 只在本机工作，不发送任何数据。"
                )

                VStack(alignment: .leading, spacing: 12) {
                    Text("扫描范围")
                        .font(.headline)
                    Text("17 个扫描根：~/Library 与 /Library 下的常见应用数据目录。扫描只读取元数据（大小、修改时间、inode），不读文件内容。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("盲区（未观测目录）")
                        .font(.headline)
                    if model.blindSpots.isEmpty {
                        Text("没有盲区：所有扫描根均可读。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("以下目录无法读取，账本在这些范围内不完整：")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ForEach(model.blindSpots, id: \.self) { spot in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "eye.slash")
                                    .foregroundStyle(.orange)
                                Text(spot)
                                    .font(.callout)
                                    .textSelection(.enabled)
                            }
                        }
                        Text("授权「完全磁盘访问权限」可补全盲区（系统设置 → 隐私与安全性 → 完全磁盘访问权限）。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(28)
        }
    }
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
