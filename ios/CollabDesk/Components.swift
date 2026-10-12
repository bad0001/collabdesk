import SwiftUI

enum DeskStyle {
    // Tempo's quiet surfaces, with indigo reserved for actions rather than
    // large decoration. Status always includes a label as well as a color.
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
    static let accent = adaptive(0x6366F1, 0xB5B8FF)
    static let background = adaptive(0xF5F7FB, 0x121419)
    static let panel = adaptive(0xFFFFFF, 0x1C1F25)
    static let separator = adaptive(0xE8EBF0, 0x30343D)
    static let warning = adaptive(0x9A5700, 0xF9C568)
    static let danger = adaptive(0xC43545, 0xFF8995)
    static let success = adaptive(0x13775B, 0x6ED9B5)
    static func severity(_ value: String) -> Color { value == "red" ? danger : warning }
    static func status(_ value: TaskStatus) -> Color {
        switch value { case .completed: return success; case .needs_help: return warning; case .in_progress: return accent; case .awaiting_review: return accent; default: return .secondary }
    }
    static func age(_ value: String?) -> String {
        guard let value, let date = DeskDate.date(value) else { return "—" }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟" }
        if seconds < 86400 { return "\(seconds / 3600) 小时 \((seconds % 3600) / 60) 分钟" }
        return "\(seconds / 86400) 天 \((seconds % 86400) / 3600) 小时"
    }
    static func link(_ raw: String) -> URL? {
        guard let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

struct Panel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(DeskStyle.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.025), radius: 12, x: 0, y: 4)
    }
}

struct Tag: View {
    let text: String
    var color: Color = .secondary
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.065), in: Capsule())
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct StatusTag: View {
    let status: TaskStatus
    var body: some View { Tag(text: status.label, color: DeskStyle.status(status), symbol: status.symbol) }
}

struct SectionTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CountCell: View {
    let value: Int
    let label: String
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(value)").font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConnectionBanner: View {
    @EnvironmentObject var store: DeskStore
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(store.isDemo ? Color.secondary : DeskStyle.success).frame(width: 5, height: 5)
                Text(store.isDemo ? "本地演示" : "已连接 · \(store.snapshot.me.name)")
                Spacer(minLength: 0)
                if store.isBusy { ProgressView().controlSize(.small) }
                else if !store.isDemo, let date = store.lastRefresh {
                    Text(date, style: .time).monospacedDigit()
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.vertical, 6)
            .background(DeskStyle.background)
            if let error = store.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.circle").font(.caption)
                    if store.pendingWrite != nil {
                        Button("重试待核实写入") { Task { await store.retryPending() } }
                            .font(.caption.weight(.semibold)).disabled(store.isBusy)
                    } else {
                        Button("关闭提示") { store.error = nil }.font(.caption)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .foregroundStyle(DeskStyle.warning).background(DeskStyle.warning.opacity(0.07))
            }
        }
    }
}

struct EmptyPanel: View {
    let title: String
    let detail: String
    var symbol: String = "tray"
    var body: some View {
        Panel {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.title3).foregroundStyle(.secondary)
                Text(title).font(.subheadline.weight(.medium))
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            }.frame(maxWidth: .infinity).padding(.vertical, 12)
        }
    }
}

struct TaskCard: View {
    @EnvironmentObject var store: DeskStore
    let task: WorkTask
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                AdaptiveColumns {
                    Text(task.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    StatusTag(status: task.status)
                }
                AdaptiveColumns {
                    Label(store.snapshot.memberName(task.ownerId), systemImage: "person.crop.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    Tag(text: task.source.label)
                    Tag(text: task.category.label, symbol: task.category.symbol)
                }
                Text(task.id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let alert = store.snapshot.activeAlerts.first(where: { $0.taskId == task.id }) {
                    Label(alert.title, systemImage: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(DeskStyle.severity(alert.severity)).lineLimit(2)
                }
            }
        }
    }
}

struct AlertCard: View {
    @EnvironmentObject var store: DeskStore
    let alert: AlertRecord
    var body: some View {
        Panel {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: alert.severity == "red" ? "exclamationmark.circle.fill" : "clock.badge.exclamationmark")
                    .font(.title3).foregroundStyle(DeskStyle.severity(alert.severity)).frame(width: 24)
                VStack(alignment: .leading, spacing: 6) {
                    Text(alert.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(alert.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text([store.snapshot.memberName(alert.memberId), alert.stateLabel, alert.taskId].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

struct TimelineRow: View {
    let title: String
    let bodyText: String
    let time: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(DeskStyle.accent.opacity(0.55)).frame(width: 7, height: 7).padding(.top, 6)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.medium))
                Text(bodyText).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                Text(DeskDate.display(time)).font(.caption2).foregroundStyle(.tertiary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SoftIcon: View {
    let symbol: String
    var color: Color = DeskStyle.accent
    var size: CGFloat = 32
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(color).frame(width: size, height: size)
            .background(color.opacity(0.09), in: Circle())
            .accessibilityHidden(true)
    }
}

struct AdaptiveColumns<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder let content: Content
    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 9))
        layout { content }
    }
}
