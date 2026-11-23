import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            OverviewView()
                .tabItem { Label("概览", systemImage: "square.grid.2x2") }

            PlaceholderTab(
                title: "待处理",
                subtitle: "已从应用程序文件夹消失、但仍有足迹留在本机的 App。",
                systemImage: "tray",
                emptyTitle: "没有待处理项",
                emptyMessage: "App 被卸载后，它的残留会在这里等待你核对。"
            )
            .tabItem { Label("待处理", systemImage: "tray") }

            PlaceholderTab(
                title: "周报",
                subtitle: "本周新增了多少足迹，分别来自哪里。",
                systemImage: "chart.bar.xaxis",
                emptyTitle: "还没有追踪数据",
                emptyMessage: "账本开始记录变化后，这里会按周汇总。"
            )
            .tabItem { Label("周报", systemImage: "chart.bar.xaxis") }

            PlaceholderTab(
                title: "设置",
                subtitle: "Ledger 只在本机工作，不发送任何数据。",
                systemImage: "gearshape",
                emptyTitle: "设置项正在准备中",
                emptyMessage: "扫描范围、权限、保留策略与暂停记录将在后续阶段接入。"
            )
            .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .frame(minWidth: 780, minHeight: 520)
    }
}

private struct OverviewView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeader(
                    title: "概览",
                    subtitle: "安装时记账，卸载时对账。"
                )

                HStack(spacing: 12) {
                    MetricCard(title: "已记录 App", value: "0", systemImage: "square.stack.3d.up")
                    MetricCard(title: "未知项", value: "0", systemImage: "questionmark.circle")
                    MetricCard(title: "今日新增", value: "0 B", systemImage: "arrow.down.circle")
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("App 足迹")
                        .font(.headline)
                    EmptyState(
                        systemImage: "book.closed",
                        title: "还没有记账记录",
                        message: "新安装的 App 稳定后，会在这里留下完整足迹。"
                    )
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
