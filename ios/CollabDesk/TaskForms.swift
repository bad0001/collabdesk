import SwiftUI

struct CreateTaskSheet: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) var dismiss
    var showGuidance = false
    @State private var title = ""
    @State private var owner = ""
    @State private var source: TaskSource = .user
    @State private var category: TaskCategory = .other
    @State private var highPriority = false
    @State private var requiresReview = true
    @State private var details = ""
    @State private var acceptance = ""
    @State private var jobURL = ""
    var eligible: [Member] { store.snapshot.me.privileged ? store.snapshot.members : [store.snapshot.me] }
    var invalid: Bool { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 200 || owner.isEmpty || (!jobURL.isEmpty && DeskStyle.link(jobURL) == nil) }
    var body: some View {
        NavigationStack {
            Form {
                if showGuidance {
                    Section {
                        DisclosureGroup("何时使用手动补录") {
                            Text(store.snapshot.me.privileged ? "日常在 Leader 的聊天窗口交办，由它在平台发布和指派；只有需要补记时才使用这里。" : "把你收到的任务登记在自己名下；用户直接交办的，来源选「用户指派」。")
                                .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 4)
                        }.font(.subheadline).tint(Color.secondary)
                        Text(store.isDemo ? "现在创建的是本地演示任务，不会发给真实 AI。" : "点「创建」后才保存到平台；AI 按各自节奏读取。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("要做什么") {
                    TextField("任务标题", text: $title, axis: .vertical).lineLimit(1...3).accessibilityIdentifier("taskTitle")
                    Picker("负责人", selection: $owner) { ForEach(eligible) { Text($0.name).tag($0.id) } }
                    Picker("来源", selection: $source) {
                        ForEach(TaskSource.allCases.filter { $0 != .leader || store.snapshot.me.privileged }) { Text($0.label).tag($0) }
                    }
                    Picker("类别", selection: $category) { ForEach(TaskCategory.allCases) { Text($0.label).tag($0) } }
                }
                Section("资料和标准") {
                    TextField("岗位资料、上下文与所需材料", text: $details, axis: .vertical).lineLimit(3...6)
                    TextField("怎样才算完成", text: $acceptance, axis: .vertical).lineLimit(2...5)
                    TextField("岗位原始链接（选填）", text: $jobURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Toggle("优先处理", isOn: $highPriority)
                    Label("提交后先由 Leader 验收",systemImage:"checkmark.seal")
                } footer: { Text("成果先交 Leader，由它验收或转交你终审。") }
                Section {
                    DisclosureGroup("平台记录说明") {
                        Text("任务编号、记录者和时间由平台自动生成。来源声明与登记身份分别保留。")
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
                    }.font(.subheadline).tint(Color.secondary)
                }
                if let error = store.error { Section { Text(error).font(.caption).foregroundStyle(DeskStyle.danger) } }
            }.scrollContentBackground(.hidden).background(DeskStyle.background)
                .navigationTitle("新建任务").navigationBarTitleDisplayMode(.inline)
                .onAppear { owner = eligible.first(where: { $0.role == "leader" })?.id ?? eligible.first?.id ?? "" }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("创建") { Task { if await store.create(title: title, owner: owner, source: source, category: category, priority: highPriority ? "high" : "normal", details: details, acceptance: acceptance, jobURL: jobURL, requiresReview: requiresReview) { dismiss() } } }
                            .disabled(invalid || store.isBusy).accessibilityIdentifier("createTaskConfirm")
                    }
                }
        }
    }
}

struct UpdateTaskSheet: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) var dismiss
    let task: WorkTask
    @State private var kind = "progress"
    @State private var bodyText = ""
    @State private var owner = ""
    @State private var status: TaskStatus = .in_progress
    @State private var resultURL = ""
    @State private var severity = "yellow"
    var authorizationBlocked: Bool {
        let latest = store.snapshot.authorizations?.first { $0.taskId == task.id && $0.requesterId == store.snapshot.me.id }
        return store.snapshot.me.role == "worker" && ["pending_leader", "awaiting_user", "denied"].contains(latest?.state ?? "")
    }
    var choices: [(String, String)] {
        var options: [(String, String)] = []
        if task.status == .awaiting_review {
            let reviewer = task.reviewStage == "user" ? "admin" : "leader"
            if store.snapshot.me.role == reviewer { options += [("approved", "验收通过"), ("rejected", "打回并说明原因")] }
            if store.snapshot.me.role == "leader" && reviewer == "leader" { options.append(("forward_user","转交用户终审")) }
        } else if task.status != .completed && task.status != .cancelled {
            if !authorizationBlocked {
                options += [("progress", "记录进展"), ("accepted", "接单 / 开始工作")]
                options.append(("submitted", "提交成果，先由 Leader 核对"))
                if task.status == .needs_help { options.append(("unblocked", "问题解决，恢复执行")) }
            }
            options.append(("blocked", "遇到困难，需要协助"))
            if store.snapshot.me.privileged { options.append(("handoff", "转派负责人")) }
        }
        options += [("question", "提问 / 补充说明"), ("read", "标记已读")]
        if store.snapshot.me.privileged { options.append(("review", "验过留痕（不改状态）")) }
        return options
    }
    var desiredStatus: TaskStatus {
        switch kind {
        case "accepted", "unblocked", "rejected": return .in_progress
        case "blocked": return .needs_help
        case "completed", "approved": return .completed
        case "submitted", "forward_user": return .awaiting_review
        case "handoff": return owner == task.ownerId ? task.status : .pending
        case "progress": return status
        default: return task.status
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(task.title).font(.headline)
                        StatusTag(status: task.status)
                        Text("\(task.id) · 版本 \(task.version)").font(.caption.monospaced()).foregroundStyle(.tertiary)
                    }.padding(.vertical, 4)
                }
                if authorizationBlocked {
                    Section {
                        Label("授权尚未通过", systemImage: "hourglass")
                            .font(.subheadline.weight(.medium))
                        Text("授权通过前暂停接单与推进；仍可提问或说明阻碍。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if task.status == .awaiting_review {
                    Section {
                        Label(task.reviewStage == "user" ? "待用户终审" : "待 Leader 验收", systemImage: "checkmark.seal")
                            .font(.subheadline.weight(.medium))
                        Text("Worker 成果先交 Leader；转交后才由用户终审。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("处理方式") {
                    Picker("操作", selection: $kind) { ForEach(choices, id: \.0) { Text($0.1).tag($0.0) } }.accessibilityIdentifier("updateKind")
                    if kind == "handoff" {
                        Picker("新负责人", selection: $owner) { ForEach(store.snapshot.members) { Text($0.name).tag($0.id) } }
                        Text("保留原始来源和历史；交接后由新负责人接单。").font(.caption).foregroundStyle(.secondary)
                    }
                    if kind == "blocked" {
                        Picker("影响程度", selection: $severity) { Text("黄色 · 需要协助").tag("yellow"); Text("红色 · 当前做不下去").tag("red") }
                    }
                    if kind == "progress" {
                        Picker("任务状态", selection: $status) { ForEach([TaskStatus.pending, .in_progress, .needs_help, .cancelled]) { Text($0.label).tag($0) } }
                    }
                }
                Section {
                    TextField("做了什么、遇到什么问题、下一步需要什么", text: $bodyText, axis: .vertical).lineLimit(4...8).accessibilityIdentifier("progressBody")
                } header: { Text("具体说明（必填）") }
                if ["progress", "submitted", "completed"].contains(kind) {
                    Section("成果") { TextField("成果链接（选填）", text: $resultURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled() }
                }
                Section {
                    DisclosureGroup("记录规则") {
                        Text("提交后会留下身份、时间和类型；轮询和已读不会刷新任务进展计时。")
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
                    }.font(.subheadline).tint(Color.secondary)
                }
                if let error = store.error { Section { Text(error).font(.caption).foregroundStyle(DeskStyle.danger) } }
            }.scrollContentBackground(.hidden).background(DeskStyle.background)
                .navigationTitle("更新任务").navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    owner = task.ownerId; resultURL = task.resultURL
                    status = task.status == .pending ? .in_progress : task.status
                    kind = authorizationBlocked || task.status == .awaiting_review || task.status == .completed || task.status == .cancelled ? "question" : "progress"
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { Task { if await store.update(task: task, kind: kind, body: bodyText, status: desiredStatus, owner: kind == "handoff" ? owner : task.ownerId, resultURL: resultURL, severity: severity) { dismiss() } } }
                            .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isBusy || (!resultURL.isEmpty && DeskStyle.link(resultURL) == nil))
                            .accessibilityIdentifier("saveProgress")
                    }
                }
        }
    }
}
