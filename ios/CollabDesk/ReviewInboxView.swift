import SwiftUI
struct ReviewInboxView: View {
    @EnvironmentObject var store: DeskStore
    var tasks: [WorkTask] { store.snapshot.me.role == "admin" ? store.snapshot.userReviewInbox : store.snapshot.leaderReviewInbox }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing:16) {
            SectionTitle(title: "待验收成果", subtitle: "\(tasks.count) 项待处理")
            ForEach(tasks) { task in NavigationLink { TaskDetailView(taskID:task.id) } label: { TaskCard(task:task) }.buttonStyle(.plain) }
            if tasks.isEmpty { EmptyPanel(title:"暂无待验收成果",detail:"有成果提交或转交后会出现在这里。",symbol:"checkmark.seal") }
            Panel {
                DisclosureGroup("验收说明") {
                    Text(store.snapshot.me.role == "admin" ? "这里只放 Leader 转交、需要你拍板的成果；常规验收由 Leader 完成。" : "先核对 Worker 成果，再决定直接通过、打回或转交用户。")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                }.font(.subheadline)
            }
        }.padding(16) }.background(DeskStyle.background).navigationTitle(store.snapshot.me.role == "admin" ? "用户终审" : "Leader 验收")
            .refreshable { await store.refresh() }
    }
}
