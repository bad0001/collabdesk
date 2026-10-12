import WidgetKit
import SwiftUI

struct DeskEntry: TimelineEntry {
    let date: Date
    let packet: GlanceSnapshot
}
struct DeskProvider: TimelineProvider {
    func placeholder(in context: Context) -> DeskEntry { DeskEntry(date: .now, packet: .preview()) }
    func getSnapshot(in context: Context, completion: @escaping (DeskEntry) -> Void) {
        completion(DeskEntry(date: .now, packet: context.isPreview ? .preview() : (GlanceCache.shared()?.read() ?? .empty())))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<DeskEntry>) -> Void) {
        let packet = GlanceCache.shared()?.read() ?? .empty()
        completion(Timeline(entries: [DeskEntry(date: .now, packet: packet)], policy: .after(Date().addingTimeInterval(900))))
    }
}
struct DeskWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    let entry: DeskEntry
    var body: some View {
        GlanceCard(packet: entry.packet, expanded: family == .systemMedium)
            .containerBackground(for: .widget) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(scheme == .dark ? Color(red: 28 / 255.0, green: 31 / 255.0, blue: 37 / 255.0) : Color.white)
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.035), lineWidth: 0.75)
                    }
            }
            .privacySensitive()
    }
}
@main
struct CollabDeskWidgets: Widget {
    let kind = "CollabDeskOverview"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DeskProvider()) { DeskWidgetView(entry: $0) }
            .configurationDisplayName("协作概况")
            .description("授权待办、异常与任务摘要；显示手机最近同步的数据。")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
