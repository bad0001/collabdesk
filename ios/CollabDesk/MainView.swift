import SwiftUI

struct MainView: View {
    @EnvironmentObject var guide: GuideState
    @EnvironmentObject var store: DeskStore
    @ObservedObject private var smsImport = SMSImportBridge.shared
    @State private var shortcutImport = false
    @State private var shortcutCandidates: [String] = []
    @State private var shortcutReceivedAt = Date()
    @Environment(\.scenePhase) private var phase
    var body: some View {
        TabView(selection: $guide.tab) {
            OverviewView().tag(DeskTab.overview).tabItem { Label("总览", systemImage: "square.grid.2x2") }
            TasksView().tag(DeskTab.tasks).tabItem { Label("任务", systemImage: "checklist") }
            LibrariesView().tag(DeskTab.ledger).tabItem { Label("台账",systemImage:"tablecells") }
            MessagesView().tag(DeskTab.messages).tabItem { Label("消息", systemImage: "bubble.left.and.bubble.right") }
                .badge(store.snapshot.unreadPersonalMessageCount)
            SettingsView().tag(DeskTab.settings).tabItem { Label("设置", systemImage: "slider.horizontal.3") }
        }
        .onReceive(smsImport.$candidates) { values in
            if !values.isEmpty { consumeSMSImport() }
        }
        .onChange(of: store.snapshot.me.id) { _, _ in consumeSMSImport() }
        .sheet(isPresented: $shortcutImport, onDismiss: { shortcutCandidates = [] }) { CodeImportSheet(candidates: shortcutCandidates, receivedAt: shortcutReceivedAt) }
        .onChange(of: phase) { _, value in if value != .active { shortcutCandidates = []; shortcutImport = false; smsImport.clear() } else { consumeSMSImport() } }
        .onReceive(PushManager.shared.$pendingOpen) { pending in
            if pending != nil { Task { await store.refresh(); consumePush() } }
        }
        .onChange(of:store.snapshot) { _,_ in consumePush() }
        .onOpenURL { url in
            guard let route = DeskRoute(url: url) else { return }
            guide.showWelcome = false; guide.sheet = nil; guide.destination = route
        }
        .sheet(item: $guide.destination) { route in
            NavigationStack {
                Group {
                    switch route {
                    case .authorizations: AuthorizationListView()
                    case .alerts: AlertsListView()
                    case .tasks: TasksView()
                    case .task(let id): TaskDetailView(taskID: id)
                    case .messages: MessagesView()
                    case .message(let id): MessageDetailView(messageID: id)
                    case .userRequests: UserRequestsView()
                    case .userRequest(let id): UserRequestDetailView(requestID: id)
                    }
                }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { guide.destination = nil } } }
            }
        }
        .fullScreenCover(isPresented: $guide.showWelcome, onDismiss: guide.performPendingNavigation) { WelcomeView() }
        .sheet(item: $guide.sheet, onDismiss: guide.performPendingNavigation) { sheet in
            if sheet == .help { HelpView() } else { PracticeView() }
        }
    }
    private func consumeSMSImport() {
        let values = smsImport.candidates
        guard !values.isEmpty else { return }
        // On a cold launch the configured account loads asynchronously.
        // Keep only the RAM handoff until its identity is known, not a file.
        guard !store.isDemo else { smsImport.clear(); store.error = "请先连接你的真实用户账号，再导入验证码。"; return }
        guard !store.snapshot.me.id.isEmpty else { return }
        guard store.snapshot.me.role == "admin" else { smsImport.clear(); store.error = "请用你的用户账号导入验证码。"; return }
        guard phase == .active else { return }
        shortcutReceivedAt = smsImport.capturedAt; shortcutCandidates = values
        guide.showWelcome = false; guide.sheet = nil; guide.destination = nil
        shortcutImport = true; smsImport.clear()
    }
    private func consumePush() {
        guard let pending=PushManager.shared.pendingOpen, !store.isDemo, !store.snapshot.me.id.isEmpty else { return }
        guard pending.workspaceID==store.snapshot.workspaceId else { store.error="这条提醒来自另一个平台连接，请切换到对应服务查看。"; PushManager.shared.pendingOpen=nil; return }
        if let route=DeskRoute(url:pending.url) { guide.showWelcome=false; guide.sheet=nil; guide.destination=route }
        PushManager.shared.pendingOpen=nil
    }

}

struct MemberDetailView: View {
    @EnvironmentObject var store: DeskStore
    let memberID: String
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let row = store.snapshot.dashboard?.first(where: { $0.memberId == memberID }) { WorkerCard(row: row) }
                if let member = store.snapshot.members.first(where: { $0.id == memberID }) {
                    Panel {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("额度与参与状态").font(.headline)
                                Spacer(minLength: 8)
                                Tag(text: "成员自报")
                            }
                            Text(member.quotaNote.isEmpty ? "额度尚未上报" : member.quotaNote)
                                .font(.subheadline).foregroundStyle(.primary).textSelection(.enabled)
                            Text("最近 AI 访问：\(member.lastPollAt.map(DeskDate.display) ?? "尚未登记")")
                                .font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup("查看登记信息") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("这是成员自报信息，不是平台测量的余额。更新：\(member.quotaUpdatedAt.map(DeskDate.display) ?? "暂无")")
                                    if !member.budgetGroup.isEmpty { Text("共享额度组：\(member.budgetGroup)") }
                                    Text(member.heartbeatMode == "event_driven" ? "按更新唤醒 · 不按固定轮询判断失联" : "心跳约定：\(member.pollSeconds / 60) 分钟")
                                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                            }.font(.subheadline).tint(Color.secondary)
                        }
                    }
                }
                SectionTitle(title: "当前任务")
                ForEach(store.snapshot.openTasks.filter { $0.ownerId == memberID }) { task in
                    NavigationLink { TaskDetailView(taskID: task.id) } label: { TaskCard(task: task) }.buttonStyle(.plain)
                }
            }.padding(16)
        }.background(DeskStyle.background).navigationTitle(store.snapshot.memberName(memberID)).navigationBarTitleDisplayMode(.inline)
    }
}

struct TasksView: View {
    @EnvironmentObject var store: DeskStore
    @EnvironmentObject var guide: GuideState
    @State private var guidedCreation = false
    @State private var query = ""
    @State private var filter = "open"
    @State private var newTask = false
    var filtered: [WorkTask] {
        store.snapshot.tasks.filter { task in
            let match = query.isEmpty || [task.title, task.id, store.snapshot.memberName(task.ownerId)].contains { $0.localizedCaseInsensitiveContains(query) }
            let included = filter == "all" || (filter == "open" && task.status != .completed && task.status != .cancelled) || (filter == "review" && task.status == .awaiting_review) || (filter == "completed" && task.status == .completed)
            return match && included
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Picker("任务筛选", selection: $filter) {
                        Text("未完成").tag("open"); Text("待验收").tag("review"); Text("已完成").tag("completed"); Text("全部").tag("all")
                    }.pickerStyle(.segmented).padding(.bottom, 4)
                    if filtered.isEmpty { EmptyPanel(title: "暂无任务", detail: "试试其他筛选条件。", symbol: "checklist") }
                    ForEach(filtered) { task in
                        NavigationLink { TaskDetailView(taskID: task.id) } label: { TaskCard(task: task) }.buttonStyle(.plain)
                    }
                }.padding(16)
            }
            .background(DeskStyle.background).navigationTitle("任务").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索任务、编号或负责人")
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("手动补录任务", systemImage: "square.and.pencil") { newTask = true }
                        .accessibilityIdentifier("manualTaskEntry")
                } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("任务更多操作")
            } }
            .safeAreaInset(edge: .top, spacing: 0) { ConnectionBanner() }
            .refreshable { await store.refresh() }
            .sheet(isPresented: $newTask, onDismiss: { guidedCreation = false }) { CreateTaskSheet(showGuidance: guidedCreation) }
            .onChange(of: guide.newTaskRequested, initial: true) { _, requested in
                if requested {
                    guide.newTaskRequested = false
                    guidedCreation = true
                    newTask = true
                }
            }
        }
    }
}

struct TaskDetailView: View {
    @EnvironmentObject var store: DeskStore
    let taskID: String
    @State private var update = false
    @State private var requestAuthorization = false
    @State private var olderHistory = false
    var task: WorkTask? { store.snapshot.tasks.first { $0.id == taskID } }
    var body: some View {
        ScrollView {
            if let task {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(task.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                        AdaptiveColumns {
                            StatusTag(status: task.status)
                            Label(store.snapshot.memberName(task.ownerId), systemImage: "person.crop.circle")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text("\(task.id) · 版本 \(task.version)").font(.caption.monospaced()).foregroundStyle(.tertiary)
                    }
                    if task.status == .awaiting_review { Panel { GuideLine(symbol:"checkmark.seal",title:task.reviewStage == "user" ? "待用户终审" : "待 Leader 验收",detail:"Worker 先向 Leader 提交；只有 Leader 转交后才进入你的终审待办。") } }
                    textPanel("任务资料", task.details.isEmpty ? "暂无补充资料" : task.details)
                    textPanel("完成标准", task.acceptance.isEmpty ? "尚未填写；可通过进展记录补充约定。" : task.acceptance)
                    Panel {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("成果与来源").font(.headline)
                            if let url = DeskStyle.link(task.resultURL) { Link(destination: url) { Label("查看成果链接", systemImage: "doc.text") } }
                            else { Text("暂未附成果链接").font(.subheadline).foregroundStyle(.secondary) }
                            if let url = DeskStyle.link(task.jobURL) { Link(destination: url) { Label("打开岗位原始链接", systemImage: "link") } }
                            DisclosureGroup("验收与登记信息") {
                                VStack(alignment: .leading, spacing: 8) {
                                    AdaptiveColumns { Tag(text: task.source.label); Tag(text: task.category.label) }
                                    Text("Worker 提交后先由 Leader 核对；需要你决定的成果才转交用户终审。")
                                    Text("来源：\(task.source.label)，由 \(store.snapshot.memberName(task.createdBy)) 登记。来源声明与记录者身份分别保留。")
                                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                            }.font(.subheadline).tint(Color.secondary)
                        }
                    }
                    let linkedRecords = (store.snapshot.records ?? []).filter { $0.taskIds.contains(task.id) }
                    if !linkedRecords.isEmpty {
                        SectionTitle(title:"关联台账")
                        ForEach(linkedRecords) { r in NavigationLink { RecordPageView(recordID:r.id) } label: { Panel { Label(r.title,systemImage:"doc.text").font(.subheadline).foregroundStyle(.primary) } }.buttonStyle(.plain) }
                    }
                    Button { update = true } label: {
                        Label("记录进展 / 处理任务", systemImage: "square.and.pencil")
                            .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("recordProgress")
                    let approvals = (store.snapshot.authorizations ?? []).filter { $0.taskId == task.id }
                    let latestOwnApproval = approvals.first { $0.requesterId == store.snapshot.me.id }
                    if store.snapshot.me.role == "worker" && task.ownerId == store.snapshot.me.id && task.status != .completed && task.status != .cancelled && task.status != .awaiting_review {
                        if let current = latestOwnApproval, current.pending {
                            Panel { GuideLine(symbol: "hourglass", title: current.stateLabel, detail: "授权前先暂停本任务的下一步；可以继续补充问题或说明阻碍。") }
                        } else {
                            Button(latestOwnApproval?.state == "denied" ? "重新申请授权" : "需要授权才能继续") { requestAuthorization = true }
                                .buttonStyle(.bordered).accessibilityIdentifier("requestAuthorization")
                        }
                    }
                    if !approvals.isEmpty {
                        SectionTitle(title: "授权申请", subtitle: "授权卡由用户亲自操作；其他申请按所选审批人处理")
                        ForEach(approvals) { item in
                            NavigationLink { AuthorizationDetailView(authorizationID: item.id) } label: { AuthorizationCard(item: item) }.buttonStyle(.plain)
                        }
                    }
                    ForEach(store.snapshot.activeAlerts.filter { $0.taskId == task.id }) { alert in
                        NavigationLink { AlertDetailView(alertID: alert.id) } label: { AlertCard(alert: alert) }.buttonStyle(.plain)
                    }
                    SectionTitle(title: "任务历史")
                    Panel {
                        let history = store.snapshot.events.filter { $0.taskId == task.id }
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(Array(history.prefix(3))) { event in
                                TimelineRow(title: "\(event.actorName) · \(event.label)", bodyText: event.body, time: event.timestamp)
                            }
                            if history.count > 3 {
                                DisclosureGroup("更早的 \(history.count - 3) 条记录", isExpanded: $olderHistory) {
                                    VStack(spacing: 18) {
                                        ForEach(Array(history.dropFirst(3))) { event in
                                            TimelineRow(title: "\(event.actorName) · \(event.label)", bodyText: event.body, time: event.timestamp)
                                        }
                                    }.padding(.top, 14)
                                }.font(.subheadline).tint(Color.secondary).accessibilityIdentifier("olderHistory")
                            }
                            if history.isEmpty { Text("暂无记录").foregroundStyle(.secondary) }
                        }
                    }
                }.padding(16)
                .sheet(isPresented: $update) { UpdateTaskSheet(task: task) }
                .sheet(isPresented: $requestAuthorization) { AuthorizationRequestSheet(task: task) }
            } else {
                EmptyPanel(title: "任务不在当前工作区", detail: "请返回并刷新列表。", symbol: "arrow.right.arrow.left").padding(16)
            }
        }.background(DeskStyle.background).navigationTitle("任务详情").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { if task != nil { Button("更新") { update = true } } } }
            .refreshable { await store.refresh() }
    }
    private func textPanel(_ title: String, _ body: String) -> some View {
        Panel { VStack(alignment: .leading, spacing: 10) { Text(title).font(.headline); Text(body).font(.subheadline).foregroundStyle(.primary).textSelection(.enabled) } }
    }
}
