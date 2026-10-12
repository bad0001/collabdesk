import SwiftUI

@main
struct CollabDeskWatchApp: App {
    @StateObject private var store = WatchDeskStore(preview: ProcessInfo.processInfo.arguments.contains("--watch-preview"))
    var body: some Scene {
        WindowGroup { WatchOverview().environmentObject(store) }
    }
}
struct WatchOverview: View {
    @EnvironmentObject var store: WatchDeskStore
    private let accent = WatchDeskStyle.accent
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("协作台").font(.headline)
                        Spacer()
                        if store.packet.isDemo {
                            Text("演示").font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(Color.white.opacity(0.07), in: Capsule())
                        }
                    }
                    if store.packet.hasData {
                        WatchSummaryPanel {
                            HStack(alignment: .center, spacing: 7) {
                                    WatchPastelIcon(symbol: "checkmark.shield", color: WatchDeskStyle.lilac)
                                    Text(store.packet.authorizationLabel).font(.caption.weight(.semibold))
                                    Spacer(minLength: 0)
                                    Text("\(store.packet.authorizations)")
                                        .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                                        .lineLimit(1).minimumScaleFactor(0.75)
                            }
                        }
                        HStack(alignment: .top, spacing: 8) {
                            metric(store.packet.inProgress, "进行中")
                            metric(store.packet.reviews, store.packet.reviewLabel)
                        }
                        HStack {
                            Label("红 \(store.packet.redAlerts)", systemImage: "exclamationmark.circle").foregroundStyle(WatchDeskStyle.rose)
                            Spacer()
                            Text("黄 \(store.packet.yellowAlerts)").foregroundStyle(WatchDeskStyle.amber)
                        }.font(.caption2.weight(.medium)).padding(.horizontal, 4)
                        if !store.packet.tasks.isEmpty {
                            Text("当前任务").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(store.packet.tasks) { task in
                                NavigationLink { WatchTaskDetail(task: task) } label: {
                                    WatchSummaryPanel {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(task.title).font(.caption.weight(.medium)).lineLimit(2)
                                                .foregroundStyle(.primary)
                                            HStack(alignment: .center) {
                                                WatchTaskStatus(status: task.status)
                                                Spacer(minLength: 0)
                                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    } else {
                        WatchSummaryPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                WatchPastelIcon(symbol: "iphone", color: WatchDeskStyle.lilac)
                                Text("先在 iPhone 打开协作台").font(.headline)
                                Text("连接并刷新后，手机会把摘要同步到这里。演示数据与真实数据分开。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if store.packet.isDemo { Text("示例数据 · 不是真实进展").font(.caption2).foregroundStyle(.secondary) }
                    else if let date = store.packet.syncedAt {
                        HStack(spacing: 6) {
                            Text(store.packet.isStale() ? "上次缓存" : "最近同步").font(.caption2).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Text(date, style: .time).font(.caption2).monospacedDigit()
                        }
                    } else { Text("尚未同步").font(.caption2).foregroundStyle(.secondary) }
                    Text("授权与审批在 iPhone 处理").font(.caption2).foregroundStyle(.secondary)
                    Button { store.refresh() } label: { if store.busy { ProgressView() } else { Label("请求手机刷新", systemImage: "arrow.clockwise") } }.disabled(store.busy)
                    Text(store.notice).font(.caption2).foregroundStyle(.secondary)
                }.padding(.horizontal, 10).padding(.bottom, 12)
            }.navigationBarTitleDisplayMode(.inline)
        }.tint(accent)
    }
    private func metric(_ count: Int, _ label: String) -> some View {
        WatchSummaryPanel {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(count)").font(.title3.weight(.semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.75)
                Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct WatchTaskDetail: View {
    let task: GlanceTask
    @State private var showsNote = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                WatchSummaryPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(task.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                        WatchTaskStatus(status: task.status)
                    }
                }
                Text(task.id).font(.caption2).monospaced().foregroundStyle(.secondary)
                Text("完整操作在 iPhone 处理").font(.caption2).foregroundStyle(.secondary)
                Button { showsNote.toggle() } label: {
                    HStack {
                        Text("摘要说明")
                        Spacer()
                        Image(systemName: showsNote ? "chevron.up" : "chevron.down")
                    }.font(.caption2)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                if showsNote {
                    Text("这是手机最近同步的任务摘要。完整资料、授权与验收请在 iPhone 查看。")
                        .font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
                }
            }.padding(.horizontal, 10).padding(.bottom, 12)
        }.navigationTitle("任务摘要")
    }
}

private enum WatchDeskStyle {
    static let accent = Color(red: 99.0 / 255, green: 102.0 / 255, blue: 241.0 / 255)
    static let surface = Color(red: 0.09, green: 0.10, blue: 0.13)
    static let lilac = Color(red: 0.76, green: 0.78, blue: 1)
    static let rose = Color(red: 1, green: 0.66, blue: 0.74)
    static let amber = Color(red: 1, green: 0.80, blue: 0.49)
}

private struct WatchSummaryPanel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(WatchDeskStyle.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct WatchPastelIcon: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol).font(.caption.weight(.semibold))
            .foregroundStyle(color).frame(width: 24, height: 24)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct WatchTaskStatus: View {
    let status: String
    var body: some View {
        Text(status).font(.caption2.weight(.medium)).foregroundStyle(WatchDeskStyle.lilac)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(WatchDeskStyle.lilac.opacity(0.10), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}
