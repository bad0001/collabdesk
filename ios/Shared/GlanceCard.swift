import SwiftUI

/// The App preview renders this exact Widget view, rather than a separate mockup.
struct GlanceCard: View {
    let packet: GlanceSnapshot
    var expanded = false
    @Environment(\.colorScheme) private var scheme
    private var accent: Color {
        scheme == .dark
            ? Color(red: 165 / 255.0, green: 180 / 255.0, blue: 252 / 255.0)
            : Color(red: 99 / 255.0, green: 102 / 255.0, blue: 241 / 255.0)
    }
    private var reviewTint: Color { scheme == .dark ? Color(red: 0.96, green: 0.65, blue: 0.79) : Color(red: 0.78, green: 0.35, blue: 0.57) }
    private var surface: Color { scheme == .dark ? Color.white.opacity(0.045) : Color.black.opacity(0.025) }
    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 4 : 6) {
            HStack(spacing: 5) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(accent)
                    .frame(width: 18, height: 18)
                    .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text("协作台").font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary)
                Spacer(minLength: 4)
                Text(packet.isDemo ? "演示" : "手机同步")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(surface, in: Capsule())
            }
            if packet.hasData {
                HStack(alignment: .top, spacing: expanded ? 14 : 9) {
                    metric(packet.authorizations, packet.authorizationLabel, symbol: "hand.raised.fill", tint: accent, prominent: true)
                    metric(packet.reviews, packet.reviewLabel, symbol: "checkmark.seal.fill", tint: reviewTint)
                    if expanded { metric(packet.inProgress, "进行中", symbol: "checklist", tint: accent) }
                }
                if expanded, let task = packet.tasks.first, let url = DeskRoute.task(task.id).url {
                    Link(destination: url) {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.text.fill").font(.system(size: 9)).foregroundStyle(reviewTint)
                            Text(task.title).lineLimit(1).font(.system(size: 11, weight: .medium))
                            Spacer(minLength: 4)
                            Text(task.status).font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(.horizontal, 7).padding(.vertical, 3)
                            .background(surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }.foregroundStyle(.primary)
                }
                HStack(spacing: 7) {
                    Text("红 \(packet.redAlerts)").foregroundStyle(packet.redAlerts > 0 ? .red : .secondary)
                    Text("黄 \(packet.yellowAlerts)").foregroundStyle(packet.yellowAlerts > 0 ? .orange : .secondary)
                    if !expanded { Spacer(minLength: 0); Text("执行 \(packet.inProgress)") }
                }.font(.system(size: 11, weight: .medium))
            } else {
                Text("先打开 iPhone App").font(.subheadline.weight(.semibold))
                Text("连接并刷新后显示摘要").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if packet.isDemo { Text("示例数据 · 不是真实进展") }
                else if let date = packet.syncedAt {
                    Text(packet.isStale() ? "缓存 ·" : "更新")
                    Text(date, style: .time)
                } else { Text("尚未同步") }
            }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(DeskRoute.authorizations.url)
    }
    private func metric(_ value: Int, _ label: String, symbol: String, tint: Color, prominent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(size: prominent ? (expanded ? 24 : 30) : (expanded ? 21 : 24), weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.75)
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(tint)
                Text(label).foregroundStyle(.secondary)
            }.font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.85)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
