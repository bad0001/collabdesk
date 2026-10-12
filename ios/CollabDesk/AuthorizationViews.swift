import SwiftUI

struct AuthorizationListView: View {
    @EnvironmentObject var store: DeskStore
    @State private var showHistory = false
    private var requests: [AuthorizationRequest] {
        (store.snapshot.authorizations ?? []).filter { showHistory || $0.pending }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Panel { Toggle("显示已处理记录", isOn: $showHistory).font(.subheadline) }
                ForEach(requests) { item in
                    NavigationLink { AuthorizationDetailView(authorizationID: item.id) } label: {
                        AuthorizationCard(item: item)
                    }.buttonStyle(.plain)
                }
                if requests.isEmpty { EmptyPanel(title: "暂无待处理授权", detail: "Worker 提出申请后，会按类型进入 Leader 或你的待办。", symbol: "checkmark.shield") }
                Panel {
                    DisclosureGroup("授权如何处理") {
                        Text("普通授权按 AI 选择的审批人处理；授权卡需要你在相应账号亲自操作，再回来确认。审批过程和处理者都会留痕。")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    }.font(.subheadline)
                }
            }.padding(16)
        }.background(DeskStyle.background).navigationTitle("授权中心")
            .refreshable { await store.refresh() }
    }
}

struct AuthorizationCard: View {
    let item: AuthorizationRequest
    var showsNavigation = true
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Tag(text: item.kindLabel, color: item.kind == "card" ? DeskStyle.warning : DeskStyle.accent)
                    Spacer()
                    if showsNavigation { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                }
                Text(item.subject).font(.headline).foregroundStyle(Color.primary)
                Text(item.stateLabel).font(.subheadline.weight(.medium)).foregroundStyle(item.pending ? DeskStyle.warning : DeskStyle.accent)
                Text("\(item.taskId) · \(DeskDate.display(item.createdAt))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct AuthorizationDetailView: View {
    @EnvironmentObject var store: DeskStore
    let authorizationID: Int
    @State private var action: String?
    private var item: AuthorizationRequest? { store.snapshot.authorizations?.first { $0.id == authorizationID } }
    private var history: [AuthorizationEvent] { (store.snapshot.authorizationEvents ?? []).filter { $0.authorizationId == authorizationID } }
    var body: some View {
        ScrollView {
            if let item {
                VStack(alignment: .leading, spacing: 16) {
                    AuthorizationCard(item: item, showsNavigation: false)
                    Panel {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("审批人", value: item.kind == "card" || item.userDecision ? "用户本人" : "Leader")
                            if !item.accountLabel.isEmpty { LabeledContent("需要操作的账号", value: item.accountLabel) }
                            Divider()
                            Text("申请原因与范围").font(.caption).foregroundStyle(.secondary)
                            Text(item.reason).font(.subheadline).textSelection(.enabled)
                        }
                    }
                    if item.kind == "card" {
                        Panel { GuideLine(symbol: "person.crop.circle.badge.checkmark", title: "这一步要你亲自操作", detail: "到对应账号完成授权卡操作后，回来点确认。这里不会代替你登录；Leader 只能看见并提醒，不能替你批准。不要在申请里填写密码或验证码。") }
                    } else {
                        Panel { GuideLine(symbol: "checkmark.shield", title: item.userDecision ? "由用户决定" : "由 Leader 决定", detail: "批准后 Worker 才能继续该任务；拒绝时要写明原因。平台按申请中选择的审批人路由，不自动判定敏感程度。") }
                    }
                    if item.pending {
                        if item.kind == "card" && store.snapshot.me.role == "admin" {
                            Panel {
                                VStack(alignment: .leading, spacing: 12) {
                                    Button("我已在外部完成授权") { action = "confirmed_external" }
                                        .buttonStyle(.borderedProminent).accessibilityIdentifier("confirmExternalAuthorization")
                                    Button("暂不授权") { action = "denied" }.buttonStyle(.bordered)
                                }
                            }
                        } else if item.kind == "normal" && store.snapshot.me.role == (item.userDecision ? "admin" : "leader") {
                            Panel {
                                VStack(alignment: .leading, spacing: 12) {
                                    Button("批准 Worker 继续") { action = "approved" }
                                        .buttonStyle(.borderedProminent).accessibilityIdentifier("approveNormalAuthorization")
                                    Button("拒绝并说明原因") { action = "denied" }.buttonStyle(.bordered)
                                    if !item.userDecision { Button("转交用户决定") { action = "escalate" }.buttonStyle(.bordered) }
                                }
                            }
                        }
                    }
                    if let note = item.decidedAt {
                        Panel {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("处理结果与批准范围").font(.subheadline.weight(.semibold))
                                Text(item.decisionNote).font(.subheadline).textSelection(.enabled)
                                Text("处理者：\(store.snapshot.memberName(item.decidedBy ?? "")) · \(DeskDate.display(note))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Panel {
                        DisclosureGroup("申请来源") {
                            VStack(alignment: .leading, spacing: 12) {
                                LabeledContent("申请者", value: store.snapshot.memberName(item.requesterId))
                                LabeledContent("关联任务", value: item.taskId)
                            }.font(.subheadline).padding(.top, 8)
                        }.font(.subheadline)
                    }
                    Panel {
                        DisclosureGroup("授权历史 · \(history.count)") {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(history) { event in
                                    TimelineRow(title: "\(event.actorName) · \(event.kind)", bodyText: event.body, time: event.timestamp)
                                }
                            }.padding(.top, 8)
                        }.font(.subheadline)
                    }
                }.padding(16)
                .sheet(isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } })) {
                    AuthorizationDecisionSheet(item: item, action: action ?? "denied")
                }
            } else {
                EmptyPanel(title: "申请不在当前工作区", detail: "请返回刷新；转派后只显示有权查看的记录。", symbol: "tray").padding(16)
            }
        }.background(DeskStyle.background).navigationTitle("授权申请 #\(authorizationID)")
            .refreshable { await store.refresh() }
    }
}

struct AuthorizationDecisionSheet: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) private var dismiss
    let item: AuthorizationRequest
    let action: String
    @State private var note = ""
    private var title: String {
        switch action { case "confirmed_external": return "确认外部授权"; case "approved": return "批准普通授权"; case "escalate": return "转交用户决定"; default: return "拒绝授权" }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section { Text(item.subject).font(.headline); Text(item.kindLabel).foregroundStyle(.secondary) }
                if action == "confirmed_external" {
                    Section { Text("请先在「\(item.accountLabel)」对应的外部账号亲自完成授权卡操作。此处只记录你的确认，不会帮你登录或判断外部操作是否成功。") }
                }
                Section("处理说明（留痕）") {
                    TextField("说明批准范围、外部完成情况或拒绝原因", text: $note, axis: .vertical).lineLimit(4...8)
                        .accessibilityIdentifier("authorizationDecisionNote")
                }
                if let error = store.error { Text(error).foregroundStyle(.red).font(.caption) }
            }.scrollContentBackground(.hidden).background(DeskStyle.background)
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("确认") { Task { if await (action == "escalate" ? store.escalateAuthorization(item,note:note) : store.decideAuthorization(item, action: action, note: note)) { dismiss() } } }
                            .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isBusy)
                            .accessibilityIdentifier("saveAuthorizationDecision")
                    }
                }
        }
    }
}

struct AuthorizationRequestSheet: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) private var dismiss
    let task: WorkTask
    @State private var kind = "normal"
    @State private var reviewer = "leader"
    @State private var subject = ""
    @State private var reason = ""
    @State private var accountLabel = ""
    var body: some View {
        NavigationStack {
            Form {
                Section { Text(task.title).font(.headline); Text(task.id).font(.caption.monospaced()).foregroundStyle(.secondary) }
                Section("申请类型") {
                    Picker("类型", selection: $kind) { Text("普通授权 · 选择审批人").tag("normal"); Text("授权卡 · 用户亲自操作").tag("card") }
                    if kind == "normal" { Picker("谁来决定",selection:$reviewer) { Text("Leader").tag("leader"); Text("用户 · 需本人决定").tag("user") } }
                    Text(kind == "card" ? "授权卡会出现在用户待办；Leader 只有查看和提醒权限。" : "普通授权交给你选定的 Leader 或用户；平台不判断内容是否敏感。通过前，本任务暂停推进。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("要授权什么") {
                    TextField("具体操作或范围", text: $subject).accessibilityIdentifier("authorizationSubject")
                    TextField("为什么需要、准备如何使用", text: $reason, axis: .vertical).lineLimit(3...6)
                    if kind == "card" { TextField("需要用户登录的账号名称（不填密码）", text: $accountLabel).accessibilityIdentifier("authorizationAccount") }
                }
                Section { Text("只写账号名称和操作说明，不填写密码、验证码或卡号。申请、处理身份和时间都会保留。") }
                if let error = store.error { Text(error).foregroundStyle(.red).font(.caption) }
            }.scrollContentBackground(.hidden).background(DeskStyle.background)
                .navigationTitle("申请授权").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("提交") { Task { if await store.requestAuthorization(task: task, kind: kind, subject: subject, reason: reason, accountLabel: accountLabel, reviewer:reviewer) { dismiss() } } }
                            .disabled(subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (kind == "card" && accountLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || store.isBusy)
                            .accessibilityIdentifier("submitAuthorizationRequest")
                    }
                }
        }
    }
}
