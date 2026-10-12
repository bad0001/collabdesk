import SwiftUI

struct GlanceSettingsView: View {
    @EnvironmentObject var store: DeskStore
    @EnvironmentObject var guide: GuideState
    var packet: GlanceSnapshot { store.snapshot.glance(isDemo: store.isDemo, syncedAt: store.lastRefresh) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(title: "桌面速览")
                GlanceCard(packet: packet).padding(16).frame(width: 170, height: 170).background(DeskStyle.panel, in: RoundedRectangle(cornerRadius: 22))
                    .shadow(color: .black.opacity(0.025), radius: 12, x: 0, y: 4)
                    .accessibilityIdentifier("smallWidgetPreview")
                GlanceCard(packet: packet, expanded: true).padding(16).frame(height: 170).background(DeskStyle.panel, in: RoundedRectangle(cornerRadius: 22))
                    .shadow(color: .black.opacity(0.025), radius: 12, x: 0, y: 4)
                    .accessibilityIdentifier("mediumWidgetPreview")
                Panel { VStack(alignment: .leading, spacing: 10) {
                    DisclosureGroup("添加到桌面") {
                        Text("长按 iPhone 桌面空白处 → 编辑 → 添加小组件 → 搜索“协作台” → 选择小号或中号。点击组件可进入授权中心或对应任务。")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    }.font(.subheadline)
                    Button("打开授权中心") { guide.destination = .authorizations }.accessibilityIdentifier("glanceOpenAuthorizations")
                } }
                Panel {
                    DisclosureGroup("在 Watch 查看") {
                        Text("安装配套 Watch App，打开手机协作台并刷新。手表显示待授权、异常和最多三项任务；可请求手机刷新，手机暂未连通时保留缓存。这里不进行审批或编辑台账。")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    }.font(.subheadline)
                }
                Panel { VStack(alignment: .leading, spacing: 10) {
                    Text("以手机最近同步为准，不保证实时更新。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(GlanceBridge.shared.cacheStatus).font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("数据与提醒是两回事") {
                        Text("摘要显示最近同步时间，不保证实时更新；后台刷新由系统安排。锁屏推送是另外的 APNs 通道，目前还在待配置阶段。演示摘要明确标为演示，不会上传到服务。")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    }.font(.subheadline)
                } }
            }.padding(16)
        }.background(DeskStyle.background).navigationTitle("小组件与 Watch").navigationBarTitleDisplayMode(.inline)
    }
}
