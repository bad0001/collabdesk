import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var store: DeskStore
    @EnvironmentObject var guide: GuideState
    @State private var showInbox: DeskRoute?
    @State private var teamExpanded = false
    @State private var seenChangeIDs: Set<String> = []
    @State private var changeNotice = false
    @State private var initializedNotice = false
    private var rows: [WorkerRow] { store.snapshot.dashboard ?? [] }
    private var workingRows: [WorkerRow] { rows.filter { $0.openTasks > 0 || $0.redAlerts + $0.yellowAlerts > 0 } }
    private var quietRows: [WorkerRow] { rows.filter { $0.openTasks == 0 && $0.redAlerts + $0.yellowAlerts == 0 } }
    private var reviewCount: Int { store.snapshot.me.role == "admin" ? store.snapshot.userReviewInbox.count : store.snapshot.leaderReviewInbox.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if store.snapshot.me.role == "admin" { userAttention } else { summary }
                    authorizationAttention
                    reviewAttention
                    if !store.snapshot.inboxAlerts.isEmpty { attention }
                    if store.snapshot.me.privileged {
                        Panel { DisclosureGroup("团队进展 · \(workingRows.count) 位协作中", isExpanded: $teamExpanded) { team.padding(.top, 12) }.font(.subheadline.weight(.medium)).accessibilityIdentifier("teamProgressCollapse") }
                    } else { myTasks }
                    if store.snapshot.me.role == "admin" {
                        NavigationLink { CodeVaultView() } label: {
                            Panel { HStack(spacing: 12) { SoftIcon(symbol: "key", color: DeskStyle.success, size: 34); Text("验证码库").font(.subheadline.weight(.medium)).foregroundStyle(.primary); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) } }
                        }.buttonStyle(.plain).accessibilityIdentifier("openCodeVault")
                        summary
                    }
                    if let announcement = store.snapshot.announcements.first {
                        Panel {
                            DisclosureGroup {
                                Text(announcement.body).font(.subheadline).foregroundStyle(.secondary)
                                    .textSelection(.enabled).padding(.top, 8)
                                Text("\(announcement.actorName) · \(DeskDate.display(announcement.createdAt))")
                                    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("公告与规则").font(.caption).foregroundStyle(Color.secondary)
                                        Text(announcement.title).font(.subheadline.weight(.medium)).foregroundStyle(Color.primary)
                                    }
                                } icon: { SoftIcon(symbol: "text.badge.checkmark") }
                            }.accessibilityIdentifier("latestAgreement")
                        }
                    }
                }.padding(.horizontal, 18).padding(.vertical, 12)
            }
            .scrollIndicators(.hidden).background(DeskStyle.background)
            .navigationTitle("协作台").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { guide.sheet = .help } label: { Image(systemName: "questionmark.circle") }
                        .accessibilityLabel("怎么用协作台").accessibilityIdentifier("openHelp")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { ConnectionBanner() }
            .refreshable { await store.refresh() }
            .sheet(item: $showInbox) { route in NavigationStack {
                Group { if case .userRequest(let id) = route { UserRequestDetailView(requestID: id) } else if case .message(let id) = route { MessageDetailView(messageID: id) } else { UserRequestsView() } }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showInbox = nil } } }
            } }
            .onChange(of: store.snapshot.inboxChangeIDs, initial: true) { _, ids in
                if initializedNotice && !ids.subtracting(seenChangeIDs).isEmpty { changeNotice = true }
                seenChangeIDs.formUnion(ids); initializedNotice = true
            }
        }
    }

    private var userAttention: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(title: "需要你处理")
                NavigationLink { UserRequestsView() } label: { Text("求助 \(store.snapshot.activeUserRequests.count)").font(.caption.weight(.medium)) }
            }
            if changeNotice {
                HStack { Label("有新的事情找你", systemImage: "bubble.left.and.bubble.right.fill").font(.caption.weight(.medium)); Spacer(); Button { changeNotice = false } label: { Image(systemName: "xmark") }.accessibilityLabel("收起新请求提示") }
                    .foregroundStyle(DeskStyle.accent).padding(12).background(DeskStyle.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            }
            ForEach(Array(store.snapshot.activeUserRequests.prefix(3))) { item in
                Button { showInbox = .userRequest(item.id) } label: { UserRequestCard(item: item) }.buttonStyle(.plain).accessibilityIdentifier("home-request-\(item.id)")
            }
            ForEach(Array(store.snapshot.incomingAttention.prefix(3))) { message in
                Button { showInbox = .message(message.id) } label: {
                    Panel {
                        HStack(alignment: .top, spacing: 12) {
                            SoftIcon(symbol: "bubble.left", size: 38)
                            VStack(alignment: .leading, spacing: 7) {
                                HStack { Text("\(message.senderName) 给你留言").font(.subheadline.weight(.semibold)); Spacer(); Tag(text: "未读", color: DeskStyle.accent) }
                                Text(message.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                Text("查看 / 直接回复").font(.caption).foregroundStyle(DeskStyle.accent)
                            }
                        }.foregroundStyle(.primary)
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("home-message-\(message.id)")
            }
            if store.snapshot.activeUserRequests.isEmpty && store.snapshot.incomingAttention.isEmpty && store.snapshot.userAuthorizationInbox.isEmpty && reviewCount == 0 {
                Panel { HStack(spacing: 12) { SoftIcon(symbol: "checkmark", color: DeskStyle.success, size: 38); VStack(alignment: .leading, spacing: 5) { Text("暂时不用你操心").font(.subheadline.weight(.medium)); Text("有需要会在这里等你。").font(.caption).foregroundStyle(.secondary) } } }
            }
            if store.snapshot.incomingAttention.count > 3 {
                NavigationLink { MessagesView() } label: { Text("还有 \(store.snapshot.incomingAttention.count - 3) 条来信").font(.caption) }
            }
        }
    }

    @ViewBuilder private var authorizationAttention: some View {
        let requests = store.snapshot.me.role == "admin" ? store.snapshot.userAuthorizationInbox : store.snapshot.leaderAuthorizationInbox
        if !requests.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle(title: store.snapshot.me.role == "admin" ? "待你授权" : "待审批")
                    NavigationLink { AuthorizationListView() } label: { Text("全部 \(requests.count)").font(.caption.weight(.medium)) }
                }
                ForEach(Array(requests.prefix(2))) { request in
                    NavigationLink { AuthorizationDetailView(authorizationID: request.id) } label: { AuthorizationCard(item: request) }
                        .buttonStyle(.plain)
                }
            }.accessibilityIdentifier("authorizationInbox")
        }
    }

    private var summary: some View {
        Panel {
            AdaptiveColumns {
                CountCell(value: store.snapshot.openTasks.count, label: "未完成")
                CountCell(value: reviewCount, label: store.snapshot.me.role == "admin" ? "待你终审" : "待验收")
                CountCell(value: store.snapshot.inboxAlerts.count, label: "需关注", color: store.snapshot.inboxAlerts.isEmpty ? .primary : DeskStyle.warning)
            }
        }.accessibilityIdentifier("overviewSummary")
    }

    @ViewBuilder private var reviewAttention: some View {
        if reviewCount > 0 {
            NavigationLink { ReviewInboxView() } label: {
                Panel {
                    HStack(spacing: 12) {
                        SoftIcon(symbol: "checkmark.seal", color: DeskStyle.accent)
                        Text(store.snapshot.me.role == "admin" ? "待你终审的成果" : "待验收任务")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Spacer(minLength: 6)
                        Text("\(reviewCount)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }.buttonStyle(.plain).accessibilityIdentifier("reviewQueue")
        }
    }

    private var attention: some View {
        VStack(spacing: 12) {
            HStack {
                SectionTitle(title: "需要关注")
                NavigationLink { AlertsListView() } label: {
                    Label("全部", systemImage: "chevron.right").font(.caption.weight(.medium))
                }.accessibilityLabel("全部异常待办")
            }
            if store.snapshot.inboxAlerts.isEmpty {
                Panel {
                    HStack(spacing: 12) {
                        SoftIcon(symbol: "checkmark", color: DeskStyle.success)
                        Text("暂时没有异常待办").font(.subheadline.weight(.medium))
                    }
                }
            }
            ForEach(Array(store.snapshot.inboxAlerts.prefix(2))) { alert in
                NavigationLink { AlertDetailView(alertID: alert.id) } label: { AlertCard(alert: alert) }.buttonStyle(.plain)
            }
        }
    }

    private var team: some View {
        VStack(spacing: 12) {
            HStack {
                SectionTitle(title: "团队进展")
                NavigationLink { MembersView() } label: {
                    Text("全部 \(rows.count)").font(.caption.weight(.medium))
                }.accessibilityIdentifier("allMembers")
            }
            ForEach(Array(workingRows.prefix(3))) { row in
                NavigationLink { MemberDetailView(memberID: row.memberId) } label: { MemberSummaryRow(row: row) }.buttonStyle(.plain)
            }
            if !quietRows.isEmpty {
                Panel {
                    DisclosureGroup("暂无任务的成员 · \(quietRows.count)") {
                        VStack(spacing: 10) {
                            ForEach(quietRows) { row in
                                NavigationLink { MemberDetailView(memberID: row.memberId) } label: {
                                    HStack { Text(row.name); Spacer(); Text(row.participationLabel).foregroundStyle(.secondary) }
                                        .font(.subheadline).padding(.vertical, 8)
                                }
                            }
                        }.padding(.top, 8)
                    }.font(.subheadline).accessibilityIdentifier("quietMembers")
                }
            }
            if rows.isEmpty { EmptyPanel(title: "等待第一位协作成员", detail: "成员登记后，会在这里汇总进展。", symbol: "person.2") }
        }
    }

    private var myTasks: some View {
        VStack(spacing: 12) {
            SectionTitle(title: "我的任务")
            ForEach(Array(store.snapshot.openTasks.prefix(3))) { task in
                NavigationLink { TaskDetailView(taskID: task.id) } label: { TaskCard(task: task) }.buttonStyle(.plain)
            }
            if store.snapshot.openTasks.isEmpty {
                EmptyPanel(title: "目前没有待办任务", detail: "接到任务后会显示在这里。", symbol: "checklist")
            }
        }
    }
}

struct MemberSummaryRow: View {
    let row: WorkerRow
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 10) {
                    SoftIcon(symbol: row.role == "leader" ? "person.badge.shield.checkmark" : "person", size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text(row.participationLabel).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    if row.redAlerts > 0 { Tag(text: "\(row.redAlerts) 红", color: DeskStyle.danger, symbol: "exclamationmark.circle.fill") }
                    else if row.yellowAlerts > 0 { Tag(text: "\(row.yellowAlerts) 黄", color: DeskStyle.warning, symbol: "clock") }
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).padding(.top, 8)
                }
                AdaptiveColumns {
                    compactStat(row.openTasks, "手头任务")
                    compactStat(row.awaitingReview, "待验收")
                    compactStat(row.submitted24h, "24h 产出")
                }
                if let title = row.oldestTaskTitle {
                    Text("最久 · \(DeskStyle.age(row.oldestStartedAt)) · \(title)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }
    private func compactStat(_ value: Int, _ title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(value)").font(.system(.subheadline, design: .rounded, weight: .semibold)).monospacedDigit().foregroundStyle(.primary)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkerCard: View {
    let row: WorkerRow
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text(row.name).font(.title2.weight(.semibold)); Spacer(); Tag(text: row.participationLabel, color: DeskStyle.accent) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), alignment: .leading)], alignment: .leading, spacing: 18) {
                    CountCell(value: row.openTasks, label: "手头任务")
                    CountCell(value: row.awaitingReview, label: "待验收")
                    CountCell(value: row.submitted24h, label: "24h 首次提交")
                    CountCell(value: row.approved24h, label: "24h 验收通过")
                }
                Divider()
                Text(row.oldestTaskTitle.map { "最久进行中：\($0)\n已进行 \(DeskStyle.age(row.oldestStartedAt))" } ?? "暂无进行中的任务")
                    .font(.subheadline).foregroundStyle(.secondary)
                if row.awaitingReview > 0 { Text("最长待验收 \(DeskStyle.age(row.oldestReviewAt))").font(.caption).foregroundStyle(DeskStyle.accent) }
                if row.redAlerts + row.yellowAlerts > 0 {
                    Label("\(row.redAlerts) 条红色 · \(row.yellowAlerts) 条黄色提醒", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(row.redAlerts > 0 ? DeskStyle.danger : DeskStyle.warning)
                }
            }
        }
    }
}

struct MembersView: View {
    @EnvironmentObject var store: DeskStore
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                SectionTitle(title: "成员工作负载")
                ForEach(store.snapshot.dashboard ?? []) { row in
                    NavigationLink { MemberDetailView(memberID: row.memberId) } label: { MemberSummaryRow(row: row) }.buttonStyle(.plain)
                }
            }.padding(18)
        }.background(DeskStyle.background).navigationTitle("成员统管").navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
    }
}

struct TaskQueueView: View {
    @EnvironmentObject var store: DeskStore
    let title: String
    let status: TaskStatus
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(store.snapshot.tasks.filter { $0.status == status }) { task in
                    NavigationLink { TaskDetailView(taskID: task.id) } label: { TaskCard(task: task) }.buttonStyle(.plain)
                }
                if !store.snapshot.tasks.contains(where: { $0.status == status }) {
                    EmptyPanel(title: "这里已经处理完了", detail: "新的任务会自动归入对应状态。", symbol: "checkmark.seal")
                }
            }.padding(18)
        }.background(DeskStyle.background).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
    }
}
