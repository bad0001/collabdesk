import Foundation

enum TaskStatus: String, Codable, CaseIterable, Identifiable {
    case pending, in_progress, needs_help, awaiting_review, completed, cancelled
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pending: return "待处理"
        case .in_progress: return "进行中"
        case .needs_help: return "待协助"
        case .awaiting_review: return "待验收"
        case .completed: return "已完成"
        case .cancelled: return "已取消"
        }
    }
    var symbol: String {
        switch self {
        case .pending: return "circle.dashed"
        case .in_progress: return "circle.lefthalf.filled"
        case .needs_help: return "exclamationmark.bubble"
        case .awaiting_review: return "checkmark.seal"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "minus.circle"
        }
    }
}

enum TaskSource: String, Codable, CaseIterable, Identifiable {
    case user, leader, `self`
    var id: String { rawValue }
    var label: String { switch self { case .user: return "用户指派"; case .leader: return "Leader 指派"; case .self: return "自主登记" } }
}

enum TaskCategory: String, Codable, CaseIterable, Identifiable {
    case research, communication, resume, application, other
    var id: String { rawValue }
    var label: String {
        switch self { case .research: return "岗位收集"; case .communication: return "招聘沟通"; case .resume: return "简历"; case .application: return "网申"; case .other: return "其他" }
    }
    var symbol: String {
        switch self { case .research: return "magnifyingglass"; case .communication: return "bubble.left.and.bubble.right"; case .resume: return "doc.text"; case .application: return "paperplane"; case .other: return "square.grid.2x2" }
    }
}

struct Member: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var role: String
    var profileVersion: Int? = nil
    var quotaNote: String
    var quotaUpdatedAt: String?
    var budgetGroup: String
    var pollSeconds: Int
    var participation: String? = "idle"
    var lastPollAt: String? = nil
    var heartbeatMode: String? = nil
    var participationLabel: String { ["active": "协作中", "resting": "休息中", "idle": "未启动"][participation ?? "idle"] ?? "未知" }
    var privileged: Bool { role == "admin" || role == "leader" }
    var roleLabel: String { role == "admin" ? "用户" : (role == "leader" ? "统筹" : "协作成员") }
}

struct WorkTask: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    var ownerId: String
    let source: TaskSource
    var category: TaskCategory
    var priority: String
    var status: TaskStatus
    var details: String
    var acceptance: String
    var jobURL: String
    var resultURL: String
    var version: Int
    let createdBy: String
    let createdAt: String
    var updatedAt: String
    var requiresReview: Bool? = false
    var lastProgressAt: String? = nil
    var startedAt: String? = nil
    var reviewSubmittedAt: String? = nil
    var submissionSeq: Int? = 0
    var rejectionStreak: Int? = 0
    var blockedSeverity: String? = nil
    var blockedReason: String? = nil
    var reviewStage: String? = "leader"
    var needsReview: Bool { true }
}

struct Activity: Codable, Identifiable, Equatable {
    let id: Int
    var taskId: String?
    var kind: String
    var body: String
    var actorId: String
    var actorName: String
    var timestamp: String
    var toLeader: Bool
    var notifyMemberId: String?
    var label: String {
        ["created": "建立任务", "accepted": "接单", "progress": "进展", "question": "提问",
         "completed": "完成汇报", "review": "验过留痕", "read": "已读", "handoff": "交接",
         "blocked": "受阻上报", "unblocked": "恢复执行", "submitted": "提交验收", "approved": "验收通过", "rejected": "验收打回", "resumed_clock": "恢复计时", "forward_user":"转交用户终审"][kind] ?? kind
    }
}

struct Announcement: Codable, Identifiable, Equatable {
    let id: Int
    var kind: String
    var title: String
    var body: String
    var actorId: String
    var actorName: String
    var createdAt: String
}

struct Snapshot: Codable, Equatable {
    var schemaVersion: Int
    var workspaceId: String? = nil
    var me: Member
    var members: [Member]
    var tasks: [WorkTask]
    var events: [Activity]
    var announcements: [Announcement]
    var alerts: [AlertRecord]? = []
    var alertEvents: [AlertHistory]? = []
    var dashboard: [WorkerRow]? = []
    var rules: AlertRules? = nil
    var messages: [DirectMessage]? = []
    var userRequests: [UserRequest]? = nil
    var authorizations: [AuthorizationRequest]? = []
    var authorizationEvents: [AuthorizationEvent]? = []
    var libraries: [RecordLibrary]? = []
    var records: [LedgerRecord]? = []
    var recordEvents: [RecordHistory]? = []
    var pushStatus: PushStatus? = nil
    var backupStatus: BackupStatus? = nil
    var demoOutputs: [DemoOutput]? = []
    var activeAlerts: [AlertRecord] { (alerts ?? []).filter { $0.state != "resolved" }.sorted { a, b in
        if a.severity != b.severity { return a.severity == "red" }
        return a.id > b.id
    } }
    var inboxAlerts: [AlertRecord] { activeAlerts.filter { $0.state != "snoozed" } }
    static var empty: Snapshot {
        Snapshot(schemaVersion: 2, me: Member(id: "", name: "", role: "worker", quotaNote: "", budgetGroup: "", pollSeconds: 300), members: [], tasks: [], events: [], announcements: [])
    }
    func memberName(_ id: String) -> String { members.first { $0.id == id }?.name ?? id }
    var openTasks: [WorkTask] { tasks.filter { $0.status != .completed && $0.status != .cancelled } }
    var needsHelp: [WorkTask] { tasks.filter { $0.status == .needs_help } }
    var userReviewInbox: [WorkTask] { me.role == "admin" ? tasks.filter { $0.status == .awaiting_review && $0.reviewStage == "user" } : [] }
    var leaderReviewInbox: [WorkTask] { tasks.filter { $0.status == .awaiting_review && ($0.reviewStage ?? "leader") == "leader" } }
    var userAuthorizationInbox: [AuthorizationRequest] { me.role == "admin" ? (authorizations ?? []).filter { $0.state == "awaiting_user" } : [] }
    var leaderAuthorizationInbox: [AuthorizationRequest] { me.role == "leader" ? (authorizations ?? []).filter { $0.state == "pending_leader" } : [] }
    /// Personal communication is separate from privileged oversight visibility.
    var personalMessages: [DirectMessage] {
        (messages ?? []).filter { $0.senderId == me.id || $0.recipientId == me.id }
    }
    var unreadPersonalMessageCount: Int {
        (messages ?? []).filter { $0.recipientId == me.id && $0.readAt == nil }.count
    }
    func visibleMessages(includeAll: Bool) -> [DirectMessage] {
        let visible = includeAll && me.privileged ? (messages ?? []) : personalMessages
        return visible.sorted { $0.id > $1.id }
    }
    var messageRecipients: [Member] {
        members.filter { $0.id != me.id && (me.privileged || $0.privileged) }
    }
    func preferredMessageRecipient(_ proposedID: String?) -> String {
        if let proposedID {
            return messageRecipients.contains(where: { $0.id == proposedID }) ? proposedID : ""
        }
        return messageRecipients.first?.id ?? ""
    }
    func replyRecipient(for message: DirectMessage) -> String? {
        guard message.recipientId == me.id, message.senderId != me.id,
              messageRecipients.contains(where: { $0.id == message.senderId }) else { return nil }
        return message.senderId
    }
}

struct AuthorizationRequest: Codable, Identifiable, Equatable {
    let id: Int
    var taskId: String
    var requesterId: String
    var kind: String
    var subject: String
    var reason: String
    var accountLabel: String
    var state: String
    var version: Int
    var createdAt: String
    var updatedAt: String
    var decidedBy: String?
    var decidedAt: String?
    var decisionNote: String
    var reviewer: String? = nil
    var userDecision: Bool { kind == "card" || reviewer == "user" }
    var kindLabel: String { kind == "card" ? "授权卡 · 需用户操作" : (userDecision ? "普通授权 · 用户决定" : "普通授权 · Leader 审批") }
    var stateLabel: String {
        ["pending_leader": "待 Leader 审批", "awaiting_user": "待用户授权", "approved": "已批准",
         "confirmed_external": "用户已确认外部授权", "denied": "已拒绝", "cancelled": "已随转派终止"][state] ?? state
    }
    var pending: Bool { state == "pending_leader" || state == "awaiting_user" }
}

struct AuthorizationEvent: Codable, Identifiable, Equatable {
    let id: Int
    var authorizationId: Int
    var taskId: String
    var kind: String
    var actorId: String
    var actorName: String
    var body: String
    var timestamp: String
}

enum DeskDate {
    static func string(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
    static func date(_ value: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func display(_ value: String) -> String {
        guard let date = date(value) else { return value }
        return date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().hour().minute())
    }
}

struct AlertRecord: Codable, Identifiable, Equatable {
    let id: Int
    var kind: String
    var taskId: String?
    var memberId: String
    var severity: String
    var title: String
    var detail: String
    var state: String
    var createdAt: String
    var updatedAt: String
    var snoozedUntil: String?
    var resolvedAt: String?
    var version: Int
    var levelLabel: String { severity == "red" ? "红色 · 需处理" : "黄色 · 需关注" }
    var stateLabel: String { ["open": "待处理", "acknowledged": "已读待处理", "snoozed": "已暂缓", "resolved": "已解除"][state] ?? state }
}

struct AlertHistory: Codable, Identifiable, Equatable {
    let id: Int
    var alertId: Int
    var kind: String
    var actorId: String?
    var body: String
    var timestamp: String
}

struct WorkerRow: Codable, Identifiable, Equatable {
    var id: String { memberId }
    var memberId: String
    var name: String
    var role: String
    var participation: String
    var lastPollAt: String?
    var openTasks: Int
    var inProgress: Int
    var needsHelp: Int
    var awaitingReview: Int
    var oldestTaskId: String?
    var oldestTaskTitle: String?
    var oldestStartedAt: String?
    var oldestReviewAt: String?
    var submitted24h: Int
    var approved24h: Int
    var redAlerts: Int
    var yellowAlerts: Int
    var heartbeatMode: String? = nil
    var participationLabel: String { ["active": heartbeatMode == "event_driven" ? "按更新唤醒" : "协作中", "resting": "休息中", "idle": "未启动"][participation] ?? "状态未知" }
}

struct AlertRules: Codable, Equatable {
    var version: Int = 1
    var staleYellowSeconds: Int = 7200
    var staleRedSeconds: Int = 14400
    var heartbeatYellowMisses: Int = 2
    var heartbeatRedMisses: Int = 4
    var heartbeatGraceSeconds: Int = 60
}

struct DirectMessage: Codable, Identifiable, Equatable {
    let id: Int
    var senderId: String
    var senderName: String
    var recipientId: String
    var body: String
    var createdAt: String
    var readAt: String?
}

struct DemoOutput: Codable, Equatable {
    let taskId: String
    let kind: String
    let producerId: String
    let timestamp: String
}

extension Snapshot {
    mutating func rebuildDemoDashboard() {
        let cutoff = Date().addingTimeInterval(-86400)
        dashboard = members.filter { $0.role != "admin" }.map { member in
            let own = openTasks.filter { $0.ownerId == member.id }
            let running = own.filter { $0.status == .in_progress }.sorted { ($0.startedAt ?? $0.createdAt) < ($1.startedAt ?? $1.createdAt) }
            let waiting = own.filter { $0.status == .awaiting_review }
            let alerts = activeAlerts.filter { $0.memberId == member.id }
            let outputs = (demoOutputs ?? []).filter { $0.producerId == member.id && (DeskDate.date($0.timestamp) ?? .distantPast) > cutoff }
            return WorkerRow(memberId: member.id, name: member.name, role: member.role, participation: member.participation ?? "idle", lastPollAt: member.lastPollAt,
                             openTasks: own.count, inProgress: running.count, needsHelp: own.filter { $0.status == .needs_help }.count,
                             awaitingReview: waiting.count, oldestTaskId: running.first?.id, oldestTaskTitle: running.first?.title,
                             oldestStartedAt: running.first?.startedAt, oldestReviewAt: waiting.compactMap(\.reviewSubmittedAt).sorted().first,
                             submitted24h: Set(outputs.filter { $0.kind == "submitted" }.map(\.taskId)).count,
                             approved24h: Set(outputs.filter { $0.kind == "approved" }.map(\.taskId)).count,
                             redAlerts: alerts.filter { $0.severity == "red" }.count, yellowAlerts: alerts.filter { $0.severity == "yellow" }.count)
        }.sorted { a, b in
            if a.redAlerts != b.redAlerts { return a.redAlerts > b.redAlerts }
            if a.yellowAlerts != b.yellowAlerts { return a.yellowAlerts > b.yellowAlerts }
            return a.memberId < b.memberId
        }
    }
}

enum DemoData {
    static func make() -> Snapshot {
        let stamp = DeskDate.string()
        let earlier = DeskDate.string(Date().addingTimeInterval(-7800))
        let members = [
            Member(id: "user", name: "我", role: "admin", quotaNote: "", budgetGroup: "", pollSeconds: 300),
            Member(id: "leader", name: "Leader", role: "leader", quotaNote: "尚未上报", budgetGroup: "", pollSeconds: 120, participation: "active", lastPollAt: stamp),
            Member(id: "b", name: "AI B", role: "worker", quotaNote: "尚未上报", budgetGroup: "", pollSeconds: 300, participation: "active", lastPollAt: stamp),
            Member(id: "c", name: "AI C", role: "worker", quotaNote: "尚未上报", budgetGroup: "", pollSeconds: 300, participation: "active", lastPollAt: stamp)
        ]
        let tasks = [
            WorkTask(id: "TASK-000004", title: "核对岗位清单与申请优先级", ownerId: "b", source: .leader, category: .research, priority: "normal", status: .awaiting_review,
                     details: "演示任务：岗位清单已整理，等待核对。", acceptance: "每个岗位有原始来源；优先级符合用户偏好。", jobURL: "", resultURL: "", version: 2, createdBy: "leader", createdAt: earlier, updatedAt: stamp,
                     requiresReview: true, reviewSubmittedAt: earlier, submissionSeq: 1),
            WorkTask(id: "TASK-000003", title: "补充网申需要的项目经历", ownerId: "c", source: .leader, category: .application, priority: "high", status: .needs_help,
                     details: "演示任务：整理申请表里的项目职责、结果与时间。缺少的信息先向 Leader 提问。", acceptance: "项目经历真实、时间一致；提交前由用户确认。", jobURL: "", resultURL: "", version: 2, createdBy: "leader", createdAt: earlier, updatedAt: stamp,
                     blockedSeverity: "red", blockedReason: "缺少项目起止时间，需要用户补充后继续。"),
            WorkTask(id: "TASK-000002", title: "为产品岗位整理一版简历", ownerId: "b", source: .user, category: .resume, priority: "normal", status: .in_progress,
                     details: "演示任务：用户直接交给 AI B。根据岗位要求梳理相关经历，保留原始信息，不自动投递。", acceptance: "提供成果链接，说明改动与待补充信息。完成后向 Leader 汇报。", jobURL: "", resultURL: "", version: 2, createdBy: "b", createdAt: earlier, updatedAt: earlier,
                     lastProgressAt: earlier, startedAt: earlier),
            WorkTask(id: "TASK-000001", title: "整理本周感兴趣的岗位", ownerId: "leader", source: .user, category: .research, priority: "normal", status: .completed,
                     details: "演示任务：汇总岗位要求、原始链接和申请进度。", acceptance: "每条岗位可追溯到原始来源。", jobURL: "", resultURL: "", version: 2, createdBy: "user", createdAt: earlier, updatedAt: stamp)
        ]
        let events = [
            Activity(id: 4, taskId: "TASK-000004", kind: "submitted", body: "岗位清单已整理，请核对申请优先级。", actorId: "b", actorName: "AI B", timestamp: stamp, toLeader: true, notifyMemberId: "leader"),
            Activity(id: 3, taskId: "TASK-000003", kind: "blocked", body: "缺少项目起止时间，需要用户补充后继续。", actorId: "c", actorName: "AI C", timestamp: stamp, toLeader: true, notifyMemberId: "leader"),
            Activity(id: 2, taskId: "TASK-000002", kind: "accepted", body: "已接到用户直接指派，开始梳理简历。", actorId: "b", actorName: "AI B", timestamp: earlier, toLeader: true, notifyMemberId: "leader"),
            Activity(id: 1, taskId: "TASK-000001", kind: "completed", body: "岗位已整理；下一步负责人由 Leader 决定。", actorId: "leader", actorName: "Leader", timestamp: stamp, toLeader: true, notifyMemberId: "user")
        ]
        var result = Snapshot(schemaVersion: 2, me: members[0], members: members, tasks: tasks, events: events,
                              announcements: [Announcement(id: 1, kind: "rule", title: "各自工作，统一留痕", body: "用户可直接交办；完成后记录成果并汇报 Leader。后续交接由 Leader 安排，平台只记录信息。", actorId: "leader", actorName: "Leader", createdAt: stamp)])
        result.rules = AlertRules()
        result.alerts = [
            AlertRecord(id: 2, kind: "blocked", taskId: "TASK-000003", memberId: "c", severity: "red", title: "AI C 需要协助", detail: "缺少项目起止时间，需要用户补充后继续。", state: "open", createdAt: stamp, updatedAt: stamp, version: 1),
            AlertRecord(id: 1, kind: "stale", taskId: "TASK-000002", memberId: "b", severity: "yellow", title: "简历任务有一阵没更新", detail: "超过 2 小时未上报实际进展，请 Leader 跟进。", state: "open", createdAt: stamp, updatedAt: stamp, version: 1)
        ]
        result.alertEvents = result.alerts?.map { AlertHistory(id: $0.id, alertId: $0.id, kind: "opened", body: "演示：建立异常待办。", timestamp: stamp) }
        result.messages = [DirectMessage(id: 1, senderId: "leader", senderName: "Leader", recipientId: "user", body: "需要你确认一段项目经历的时间。补齐后再安排后续网申，不自动提交。", createdAt: stamp)]
        result.authorizations = [AuthorizationRequest(id: 1, taskId: "TASK-000003", requesterId: "c", kind: "card",
                                                       subject: "继续处理招聘账号里的申请步骤", reason: "演示：该账号出现授权卡提示，需要用户亲自登录完成。",
                                                       accountLabel: "招聘账号 A", state: "awaiting_user", version: 1,
                                                       createdAt: stamp, updatedAt: stamp, decidedBy: nil, decidedAt: nil, decisionNote: "")]
        result.authorizationEvents = [AuthorizationEvent(id: 1, authorizationId: 1, taskId: "TASK-000003", kind: "requested",
                                                         actorId: "c", actorName: "AI C", body: "演示：需要用户亲自处理授权卡。", timestamp: stamp)]
        result.demoOutputs = [DemoOutput(taskId: "TASK-000004", kind: "submitted", producerId: "b", timestamp: stamp),
                              DemoOutput(taskId: "TASK-000001", kind: "submitted", producerId: "leader", timestamp: stamp)]
        result.rebuildDemoDashboard()
        return result
    }
}
