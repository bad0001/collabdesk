import SwiftUI
import Security

struct DeskError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct PendingWrite: Codable {
    let endpoint: String
    let memberId: String
    var workspaceId: String? = nil
    let path: String
    let key: String
    let body: Data

    func matches(endpoint: String, memberId: String, workspaceId: String?) -> Bool {
        guard let saved = self.workspaceId, !saved.isEmpty,
              let current = workspaceId, !current.isEmpty else { return false }
        return self.endpoint == endpoint && self.memberId == memberId && saved == current
    }
}

private struct ResolvedPendingWrite: Codable {
    let request: PendingWrite
    let manuallyCheckedAt: String
    let note: String
}

struct IssuedCredential: Identifiable {
    let id: String
    let name: String
    let value: String
}

enum CredentialStore {
    static let service = "org.example.collabdesk.api"
    static func read() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "current", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "current"]
        let values: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw DeskError(message: "凭据保存失败，请检查设备钥匙串")
            }
        } else if status != errSecSuccess { throw DeskError(message: "凭据更新失败") }
    }
}

/// Reject redirects: an API token is never forwarded to another origin.
final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class DeskStore: ObservableObject {
    @Published var snapshot = Snapshot.empty
    @Published var isDemo = true
    @Published var isBusy = false
    @Published var error: String?
    @Published var lastRefresh: Date?
    @Published var pendingWrite: PendingWrite?
    @Published var issuedCredential: IssuedCredential?
    @Published var endpoint: String
    private var token: String
    private var etag: String?
    private let files: URL
    private let session: URLSession
    private let publishGlance: Bool
    private let defaults: UserDefaults

    init(directory: URL? = nil, defaults: UserDefaults = .standard, forceDemo: Bool = false) {
        self.defaults = defaults
        publishGlance = directory == nil
        files = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CollabDesk", isDirectory: true)
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        endpoint = defaults.string(forKey: "endpoint") ?? ""
        token = CredentialStore.read()
        if forceDemo {
            snapshot = DemoData.make()
        } else {
            isDemo = defaults.object(forKey: "demo") as? Bool ?? true
            if isDemo { snapshot = load("demo.json", as: Snapshot.self) ?? DemoData.make() }
            pendingWrite = load("pending.json", as: PendingWrite.self)
        }
        if isDemo { snapshot.seedDemoLedger() }
    }

    func syncPushDevice(enabled: Bool = true) async {
        guard !isDemo, snapshot.me.role == "admin" else { return }
        // Turning off a previously registered installation must work even when
        // APNs has not issued a fresh device token in this app session.
        guard let payload = Self.pushDevicePayload(installationID: PushManager.shared.installationID,
                                                   token: PushManager.shared.token,
                                                   environment: PushManager.shared.environment, enabled: enabled) else {
            PushManager.shared.status = "尚未取得设备标识，请先允许系统通知并检查签名"
            return
        }
        do {
            var request=URLRequest(url:try Self.validEndpoint(endpoint).appendingPathComponent("v1/push/devices"))
            request.httpMethod="POST"; request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization"); request.setValue(UUID().uuidString,forHTTPHeaderField:"Idempotency-Key")
            request.httpBody=try JSONSerialization.data(withJSONObject:payload)
            let (data,response)=try await session.data(for:request); try check(response,data:data)
            PushManager.shared.status=enabled ? "本机已登记，实际发送还需服务端 APNs 配置" : "本机平台推送已停用"
            defaults.set(!enabled,forKey:"pushOptOut")
        } catch { PushManager.shared.status="平台设备登记失败，请检查连接后重试" }
    }

    static func pushDevicePayload(installationID: String, token: String?, environment: String, enabled: Bool) -> [String: Any]? {
        var payload: [String: Any] = ["installationId": installationID, "enabled": enabled]
        if enabled {
            guard let token, !token.isEmpty else { return nil }
            payload["token"] = token
            payload["environment"] = environment
        }
        return payload
    }

    func publishSummary() {
        guard publishGlance else { return }
        GlanceBridge.shared.publish(snapshot.glance(isDemo: isDemo, syncedAt: lastRefresh))
    }

    static func validEndpoint(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host,
              !host.isEmpty, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { throw DeskError(message: "请填写不含路径、凭据或参数的服务地址") }
        // Network deployment requires HTTPS. Loopback is only for the local simulator.
        let local = ["127.0.0.1", "localhost", "[::1]"].contains(host)
        guard url.scheme == "https" || (local && url.scheme == "http") else { throw DeskError(message: "远程服务请使用 HTTPS 地址") }
        return url
    }

    func connect(address: String, credential: String) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let url = try Self.validEndpoint(address)
            let clean = credential.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { throw DeskError(message: "请输入专属 API 凭据") }
            var request = URLRequest(url: url.appendingPathComponent("v1/snapshot"))
            request.setValue("Bearer \(clean)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            try check(response, data: data)
            let result = try JSONDecoder().decode(Snapshot.self, from: data)
            guard result.schemaVersion == 2 else { throw DeskError(message: "服务版本与当前 App 不匹配") }
            let normalized = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let pending = pendingWrite, pending.endpoint != normalized || pending.memberId != result.me.id {
                throw DeskError(message: "待核实写入属于另一个账号或地址；请先恢复原连接并核实该请求。")
            }
            guard let workspace = result.workspaceId, !workspace.isEmpty else {
                throw DeskError(message: "服务缺少工作区标识，请先更新平台后连接。")
            }
            if let pending = pendingWrite, pending.workspaceId != nil,
               !pending.matches(endpoint: normalized, memberId: result.me.id, workspaceId: workspace) {
                throw DeskError(message: "待核实写入属于另一工作区，请先核对原请求。")
            }
            try CodeAutomationKeychain.reconcile(endpoint: normalized, workspaceID: workspace, memberID: result.me.id, role: result.me.role, demo: false)
            try CredentialStore.save(clean)
            endpoint = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            token = clean
            defaults.set(endpoint, forKey: "endpoint")
            defaults.set(false, forKey: "demo")
            snapshot = result
            isDemo = false
            lastRefresh = Date()
            etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
            error = nil
            publishSummary()
            if !defaults.bool(forKey:"pushOptOut") { await syncPushDevice() }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func refresh() async {
        if isDemo { _ = persistDemo(); return }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do { try await fetch(); error = nil } catch { self.error = error.localizedDescription }
    }

    private func fetch() async throws {
        let url = try Self.validEndpoint(endpoint)
        var request = URLRequest(url: url.appendingPathComponent("v1/snapshot"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 304 { lastRefresh = Date(); publishSummary(); return }
        if let status = (response as? HTTPURLResponse)?.statusCode, status == 401 || status == 403 {
            try CodeAutomationKeychain.stop()
            snapshot = .empty
            etag = nil
            publishSummary()
        }
        try check(response, data: data)
        let result = try JSONDecoder().decode(Snapshot.self, from: data)
        guard result.schemaVersion == 2 else { throw DeskError(message: "服务版本与当前 App 不匹配") }
        guard let workspace = result.workspaceId, !workspace.isEmpty else {
            throw DeskError(message: "服务缺少工作区标识，请先更新平台后同步。")
        }
        try CodeAutomationKeychain.reconcile(endpoint: endpoint, workspaceID: workspace, memberID: result.me.id, role: result.me.role, demo: false)
        if let old = snapshot.workspaceId, old != workspace {
            throw DeskError(message: "服务的工作区已变更，请核对后重新连接；原待核实请求仍保留。")
        }
        if let pending = pendingWrite, pending.workspaceId != nil,
           !pending.matches(endpoint: endpoint, memberId: result.me.id, workspaceId: workspace) {
            throw DeskError(message: "待核实写入的身份或工作区不匹配，请先核对原请求。")
        }
        snapshot = result
        etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
        lastRefresh = Date()
        publishSummary()
    }

    func useDemo() {
        guard pendingWrite == nil, !isBusy else { error = "先重试待核实的写入，再切换演示。"; return }
        do { try CodeAutomationKeychain.stop() }
        catch { self.error = "短信自动入库停用未确认，请先打开验证码库停用后切换。"; return }
        if !isDemo, snapshot.me.role == "admin", let url=try? Self.validEndpoint(endpoint) {
            var request=URLRequest(url:url.appendingPathComponent("v1/push/devices")); request.httpMethod="POST"
            request.setValue("application/json",forHTTPHeaderField:"Content-Type"); request.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization")
            request.setValue(UUID().uuidString,forHTTPHeaderField:"Idempotency-Key")
            request.httpBody=try? JSONSerialization.data(withJSONObject:["installationId":PushManager.shared.installationID,"enabled":false])
            let currentSession=session
            Task { _ = try? await currentSession.data(for:request) }
        }
        snapshot = load("demo.json", as: Snapshot.self) ?? DemoData.make()
        snapshot.seedDemoLedger()
        isDemo = true
        defaults.set(true, forKey: "demo")
        lastRefresh = nil
        etag = nil
        error = nil
        issuedCredential = nil
        publishSummary()
    }

    func registerMember(name: String, role: String) async -> Bool {
        let id = "ai-" + UUID().uuidString.lowercased().prefix(12)
        if isDemo {
            guard snapshot.me.role == "admin" else { error = "只有用户可以添加 AI。"; return false }
            let member = Member(id: id, name: name, role: role, quotaNote: "", budgetGroup: "", pollSeconds: role == "leader" ? 120 : 300)
            snapshot.members.append(member)
            return persistDemo()
        }
        return await write(path: "/v1/members", payload: ["id": id, "name": name, "role": role])
    }

    func renameMember(_ member: Member, name: String) async -> Bool {
        if isDemo {
            guard snapshot.me.role == "admin", let index = snapshot.members.firstIndex(where: { $0.id == member.id }) else { return false }
            snapshot.members[index].name = name
            snapshot.members[index].profileVersion = (snapshot.members[index].profileVersion ?? 1) + 1
            return persistDemo()
        }
        return await write(path: "/v1/members/\(member.id)/rename", payload: ["version": member.profileVersion ?? 1, "name": name])
    }

    func rotateMemberCredential(_ member: Member) async -> Bool {
        guard !isDemo else { error = "演示成员没有真实接入凭据。"; return false }
        return await write(path: "/v1/members/\(member.id)/rotate-credential", payload: ["version": member.profileVersion ?? 1])
    }

    func requestAuthorization(task: WorkTask, kind: String, subject: String, reason: String, accountLabel: String, reviewer: String = "leader") async -> Bool {
        guard snapshot.me.role == "worker", task.ownerId == snapshot.me.id else { error = "由当前负责人申请授权。"; return false }
        if isDemo {
            guard ![TaskStatus.completed, .cancelled, .awaiting_review].contains(task.status),
                  !(snapshot.authorizations ?? []).contains(where: { $0.taskId == task.id && $0.requesterId == snapshot.me.id && $0.pending }),
                  (kind != "card" || !accountLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else {
                error = "当前任务阶段已有申请，或授权卡缺少账号名称。"; return false
            }
            let stamp = DeskDate.string()
            let id = ((snapshot.authorizations ?? []).map(\.id).max() ?? 0) + 1
            let request = AuthorizationRequest(id: id, taskId: task.id, requesterId: snapshot.me.id, kind: kind,
                                               subject: subject, reason: reason, accountLabel: kind == "card" ? accountLabel : "",
                                               state: kind == "card" || reviewer == "user" ? "awaiting_user" : "pending_leader", version: 1,
                                               createdAt: stamp, updatedAt: stamp, decidedBy: nil, decidedAt: nil, decisionNote: "", reviewer: kind == "card" ? "user" : reviewer)
            snapshot.authorizations = [request] + (snapshot.authorizations ?? [])
            snapshot.authorizationEvents = [AuthorizationEvent(id: ((snapshot.authorizationEvents ?? []).map(\.id).max() ?? 0) + 1,
                                                                authorizationId: id, taskId: task.id, kind: "requested", actorId: snapshot.me.id,
                                                                actorName: snapshot.me.name, body: reason, timestamp: stamp)] + (snapshot.authorizationEvents ?? [])
            return persistDemo()
        }
        return await write(path: "/v1/authorizations", payload: ["taskId": task.id, "kind": kind, "subject": subject,
                                                                  "reason": reason, "accountLabel": kind == "card" ? accountLabel : "", "reviewer":kind == "card" ? "user" : reviewer])
    }

    func decideAuthorization(_ authorization: AuthorizationRequest, action: String, note: String) async -> Bool {
        let allowed = authorization.userDecision ? snapshot.me.role == "admin" : snapshot.me.role == "leader"
        guard allowed else { error = "当前身份没有这项审批权限。"; return false }
        guard (authorization.kind == "card" ? ["confirmed_external", "denied"] : ["approved", "denied"]).contains(action) else {
            error = "这项授权类型不支持所选操作。"; return false
        }
        if isDemo {
            guard let index = snapshot.authorizations?.firstIndex(where: { $0.id == authorization.id }),
                  snapshot.authorizations?[index].version == authorization.version,
                  snapshot.authorizations?[index].pending == true else { error = "授权申请已更新，请刷新。"; return false }
            let stamp = DeskDate.string()
            snapshot.authorizations?[index].state = action
            snapshot.authorizations?[index].version += 1
            snapshot.authorizations?[index].updatedAt = stamp
            snapshot.authorizations?[index].decidedBy = snapshot.me.id
            snapshot.authorizations?[index].decidedAt = stamp
            snapshot.authorizations?[index].decisionNote = note
            snapshot.authorizationEvents = [AuthorizationEvent(id: ((snapshot.authorizationEvents ?? []).map(\.id).max() ?? 0) + 1,
                                                                authorizationId: authorization.id, taskId: authorization.taskId,
                                                                kind: action, actorId: snapshot.me.id, actorName: snapshot.me.name,
                                                                body: note, timestamp: stamp)] + (snapshot.authorizationEvents ?? [])
            return persistDemo()
        }
        return await write(path: "/v1/authorizations/\(authorization.id)/decision",
                           payload: ["version": authorization.version, "action": action, "note": note])
    }

    func create(title: String, owner: String, source: TaskSource, category: TaskCategory, priority: String,
                details: String, acceptance: String, jobURL: String, requiresReview: Bool = true) async -> Bool {
        if isDemo {
            let stamp = DeskDate.string()
            let n = (snapshot.tasks.compactMap { Int($0.id.replacingOccurrences(of: "TASK-", with: "")) }.max() ?? 0) + 1
            let task = WorkTask(id: String(format: "TASK-%06d", n), title: title, ownerId: owner, source: source, category: category,
                                priority: priority, status: .pending, details: details, acceptance: acceptance, jobURL: jobURL, resultURL: "", version: 1,
                                createdBy: snapshot.me.id, createdAt: stamp, updatedAt: stamp, requiresReview: requiresReview)
            snapshot.tasks.insert(task, at: 0)
            addDemoEvent(task: task, kind: "created", body: "建立任务；本条仅保存在演示数据中。", notify: owner)
            return persistDemo()
        }
        return await write(path: "/v1/tasks", payload: ["title": title, "ownerId": owner, "source": source.rawValue, "category": category.rawValue,
                                                        "priority": priority, "details": details, "acceptance": acceptance, "jobURL": jobURL, "requiresReview": requiresReview])
    }

    func update(task: WorkTask, kind: String, body: String, status: TaskStatus, owner: String, resultURL: String, severity: String = "yellow") async -> Bool {
        let kind = kind == "completed" ? "submitted" : kind
        let status = kind == "submitted" ? TaskStatus.awaiting_review : status
        if isDemo {
            guard let index = snapshot.tasks.firstIndex(where: { $0.id == task.id }), snapshot.tasks[index].version == task.version else {
                error = "任务已更新，请重新打开后提交。"; return false
            }
            let latestAuthorization = snapshot.authorizations?.first { $0.taskId == task.id && $0.requesterId == snapshot.me.id }
            if snapshot.me.role == "worker" && ["accepted", "progress", "unblocked", "submitted", "completed"].contains(kind) &&
                ["pending_leader", "awaiting_user", "denied"].contains(latestAuthorization?.state ?? "") {
                error = "本任务尚未获授权，请等待审批或联系 Leader。"; return false
            }
            if ["approved","rejected"].contains(kind) {
                let reviewer = task.reviewStage == "user" ? "admin" : "leader"
                guard task.status == .awaiting_review, snapshot.me.role == reviewer else { error="请按当前阶段交给 Leader 或用户验收。"; return false }
            }
            if kind == "forward_user" && (snapshot.me.role != "leader" || task.status != .awaiting_review || task.reviewStage == "user") { error="当前成果不在 Leader 验收阶段。"; return false }
            var report = body
            if owner != task.ownerId { report = "负责人：\(snapshot.memberName(task.ownerId)) → \(snapshot.memberName(owner))。\n" + report }
            if status != task.status { report = "状态：\(task.status.label) → \(status.label)。\n" + report }
            snapshot.tasks[index].ownerId = owner
            snapshot.tasks[index].status = status
            snapshot.tasks[index].resultURL = resultURL
            snapshot.tasks[index].version += 1
            let stamp = DeskDate.string()
            snapshot.tasks[index].updatedAt = stamp
            if ["accepted", "progress", "submitted", "completed", "unblocked", "rejected"].contains(kind) {
                snapshot.tasks[index].lastProgressAt = stamp
                if status == .in_progress { snapshot.tasks[index].startedAt = task.startedAt ?? stamp }
            }
            if kind == "blocked" {
                snapshot.tasks[index].blockedSeverity = severity
                snapshot.tasks[index].blockedReason = body
            }
            if ["unblocked", "completed", "submitted", "handoff"].contains(kind) {
                snapshot.tasks[index].blockedSeverity = nil
                snapshot.tasks[index].blockedReason = nil
            }
            if kind == "handoff" && owner != task.ownerId {
                snapshot.tasks[index].startedAt = nil
                snapshot.tasks[index].lastProgressAt = nil
                let stamp = DeskDate.string()
                for i in (snapshot.authorizations ?? []).indices where snapshot.authorizations?[i].taskId == task.id &&
                    snapshot.authorizations?[i].requesterId == task.ownerId &&
                    ["pending_leader", "awaiting_user", "denied"].contains(snapshot.authorizations?[i].state ?? "") {
                    let requestID = snapshot.authorizations![i].id
                    snapshot.authorizations?[i].state = "cancelled"
                    snapshot.authorizations?[i].version += 1
                    snapshot.authorizations?[i].updatedAt = stamp
                    snapshot.authorizations?[i].decidedBy = snapshot.me.id
                    snapshot.authorizations?[i].decidedAt = stamp
                    snapshot.authorizations?[i].decisionNote = "任务已转派，旧申请终止。"
                    snapshot.authorizationEvents = [AuthorizationEvent(id: ((snapshot.authorizationEvents ?? []).map(\.id).max() ?? 0) + 1,
                                                                        authorizationId: requestID, taskId: task.id, kind: "cancelled_on_handoff",
                                                                        actorId: snapshot.me.id, actorName: snapshot.me.name,
                                                                        body: "任务已转派，旧申请终止。", timestamp: stamp)] + (snapshot.authorizationEvents ?? [])
                }
            }
            if kind == "forward_user" { snapshot.tasks[index].reviewStage = "user" }
            if kind == "submitted" {
                snapshot.tasks[index].reviewStage = "leader"
                snapshot.tasks[index].submissionSeq = (task.submissionSeq ?? 0) + 1
                snapshot.tasks[index].reviewSubmittedAt = stamp
            }
            if kind == "approved" { snapshot.tasks[index].reviewStage = "leader"; snapshot.tasks[index].rejectionStreak = 0; snapshot.tasks[index].reviewSubmittedAt = nil }
            if kind == "rejected" { snapshot.tasks[index].reviewStage = "leader"; snapshot.tasks[index].rejectionStreak = (task.rejectionStreak ?? 0) + 1; snapshot.tasks[index].reviewSubmittedAt = nil }
            if ["submitted", "completed", "approved"].contains(kind) {
                let outputKind = kind == "approved" ? "approved" : "submitted"
                if !(snapshot.demoOutputs ?? []).contains(where: { $0.taskId == task.id && $0.kind == outputKind }) {
                    snapshot.demoOutputs = (snapshot.demoOutputs ?? []) + [DemoOutput(taskId: task.id, kind: outputKind, producerId: task.ownerId, timestamp: stamp)]
                }
            }
            addDemoEvent(task: task, kind: kind, body: report, notify: owner)
            return persistDemo()
        }
        var payload: [String: Any] = ["version": task.version, "kind": kind, "body": body, "status": status.rawValue, "ownerId": owner]
        if !["read", "review", "approved", "rejected", "forward_user"].contains(kind) { payload["resultURL"] = resultURL }
        if kind == "blocked" { payload["severity"] = severity }
        return await write(path: "/v1/tasks/\(task.id)/updates", payload: payload)
    }

    func announce(title: String, body: String, kind: String) async -> Bool {
        if isDemo {
            snapshot.announcements.insert(Announcement(id: (snapshot.announcements.map(\.id).max() ?? 0) + 1, kind: kind, title: title, body: body,
                                                       actorId: snapshot.me.id, actorName: snapshot.me.name, createdAt: DeskDate.string()), at: 0)
            return persistDemo()
        }
        return await write(path: "/v1/announcements", payload: ["title": title, "body": body, "kind": kind])
    }

    func updateQuota(note: String, group: String) async -> Bool {
        if isDemo {
            snapshot.me.quotaNote = note
            snapshot.me.budgetGroup = group
            snapshot.me.quotaUpdatedAt = DeskDate.string()
            if let i = snapshot.members.firstIndex(where: { $0.id == snapshot.me.id }) { snapshot.members[i] = snapshot.me }
            return persistDemo()
        }
        return await write(path: "/v1/members/me/quota", payload: ["note": note, "budgetGroup": group])
    }

    func alertAction(_ alert: AlertRecord, action: String, note: String, minutes: Int = 30) async -> Bool {
        if isDemo {
            guard let i = snapshot.alerts?.firstIndex(where: { $0.id == alert.id }) else { return false }
            if action == "resolve", let task = snapshot.tasks.first(where: { $0.id == alert.taskId }) {
                return await update(task: task, kind: "unblocked", body: note, status: .in_progress, owner: task.ownerId, resultURL: task.resultURL)
            }
            snapshot.alerts?[i].state = action == "snooze" ? "snoozed" : "acknowledged"
            snapshot.alerts?[i].snoozedUntil = action == "snooze" ? DeskDate.string(Date().addingTimeInterval(Double(minutes * 60))) : nil
            snapshot.alerts?[i].version += 1
            snapshot.alerts?[i].updatedAt = DeskDate.string()
            appendAlertHistory(alert.id, kind: action, body: note)
            return persistDemo()
        }
        return await write(path: "/v1/alerts/\(alert.id)/actions", payload: ["version": alert.version, "action": action, "note": note, "minutes": minutes])
    }

    func sendMessage(to recipient: String, body: String) async -> Bool {
        if isDemo {
            snapshot.messages = [DirectMessage(id: ((snapshot.messages ?? []).map(\.id).max() ?? 0) + 1, senderId: snapshot.me.id,
                                               senderName: snapshot.me.name, recipientId: recipient, body: body, createdAt: DeskDate.string())] + (snapshot.messages ?? [])
            return persistDemo()
        }
        return await write(path: "/v1/messages", payload: ["recipientId": recipient, "body": body])
    }

    func readMessage(_ message: DirectMessage) async -> Bool {
        if isDemo {
            guard let index = snapshot.messages?.firstIndex(where: { $0.id == message.id }) else { return false }
            snapshot.messages?[index].readAt = DeskDate.string()
            return persistDemo()
        }
        return await write(path: "/v1/messages/\(message.id)/read", payload: [:])
    }

    private func appendAlertHistory(_ id: Int, kind: String, body: String) {
        snapshot.alertEvents = [AlertHistory(id: ((snapshot.alertEvents ?? []).map(\.id).max() ?? 0) + 1, alertId: id, kind: kind,
                                             actorId: snapshot.me.id, body: body, timestamp: DeskDate.string())] + (snapshot.alertEvents ?? [])
    }

    private func reconcileDemoAlerts() {
        // Demo-only projection; live alerts and dashboard always come from the server.
        var wanted: [(String, WorkTask, String, String)] = []
        let rules = snapshot.rules ?? AlertRules()
        for task in snapshot.openTasks {
            if let severity = task.blockedSeverity { wanted.append(("blocked", task, severity, task.blockedReason ?? "需要协助")) }
            if (task.rejectionStreak ?? 0) >= 2 { wanted.append(("rejected", task, "red", "连续两轮验收被打回，请统筹核对要求。")) }
            if task.status == .in_progress, let stamp = task.lastProgressAt, let date = DeskDate.date(stamp),
               Date().timeIntervalSince(date) >= Double(rules.staleYellowSeconds) {
                wanted.append(("stale", task, Date().timeIntervalSince(date) >= Double(rules.staleRedSeconds) ? "red" : "yellow", "任务长时间未上报实际进展，请跟进。"))
            }
        }
        var alerts = snapshot.alerts ?? []
        for (kind, task, severity, detail) in wanted {
            if let i = alerts.firstIndex(where: { $0.taskId == task.id && $0.kind == kind }) {
                let escalation = alerts[i].severity == "yellow" && severity == "red"
                let expired = alerts[i].snoozedUntil.flatMap(DeskDate.date).map { $0 <= Date() } ?? false
                if alerts[i].state == "resolved" || escalation || expired {
                    alerts[i].state = "open"; alerts[i].resolvedAt = nil; alerts[i].snoozedUntil = nil
                    alerts[i].version += 1
                    appendAlertHistory(alerts[i].id, kind: "updated", body: "异常重新打开或升级（演示）。")
                }
                alerts[i].severity = severity; alerts[i].memberId = task.ownerId
            } else {
                let id = (alerts.map(\.id).max() ?? 0) + 1
                alerts.append(AlertRecord(id: id, kind: kind, taskId: task.id, memberId: task.ownerId, severity: severity,
                                          title: kind == "blocked" ? "任务需要协助" : (kind == "rejected" ? "连续验收打回" : "进展长时间未更新"),
                                          detail: detail, state: "open", createdAt: DeskDate.string(), updatedAt: DeskDate.string(), version: 1))
                appendAlertHistory(id, kind: "opened", body: detail)
            }
        }
        for i in alerts.indices where alerts[i].state != "resolved" {
            if !wanted.contains(where: { $0.0 == alerts[i].kind && $0.1.id == alerts[i].taskId }) {
                alerts[i].state = "resolved"; alerts[i].resolvedAt = DeskDate.string(); alerts[i].version += 1
                appendAlertHistory(alerts[i].id, kind: "resolved", body: "异常条件已解除，历史保留（演示）。")
            }
        }
        snapshot.alerts = alerts
    }

    func write(path: String, payload: [String: Any]) async -> Bool {
        guard !isBusy, pendingWrite == nil else { error = "有待核实的写入，请先重试；避免重复记录。"; return false }
        guard !isDemo, let workspace = snapshot.workspaceId, !workspace.isEmpty, !snapshot.me.id.isEmpty else {
            error = "请先连接并同步真实工作区，再提交记录。"; return false
        }
        do {
            let pending = PendingWrite(endpoint: endpoint, memberId: snapshot.me.id, workspaceId: workspace, path: path, key: UUID().uuidString,
                                       body: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            try save(pending, name: "pending.json")
            pendingWrite = pending
            return await retryPending()
        } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult func retryPending() async -> Bool {
        guard let pending = pendingWrite, !isBusy else { return false }
        guard pending.endpoint == endpoint, !isDemo else { error = "待核实写入属于先前的连接，请先恢复该连接。"; return false }
        guard pending.workspaceId != nil else { error = "旧版请求缺少工作区编号，先核对原请求结果，再结束待核实；不自动重发。"; return false }
        isBusy = true
        defer { isBusy = false }
        do {
            // Verify the current actor/workspace before reusing an old idempotency key.
            try await fetch()
            guard pending.matches(endpoint: endpoint, memberId: snapshot.me.id, workspaceId: snapshot.workspaceId) else {
                throw DeskError(message: "待核实请求的身份或工作区不匹配，已保留原请求。")
            }
            let url = try Self.validEndpoint(endpoint)
            var request = URLRequest(url: url.appendingPathComponent(pending.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
            request.httpMethod = "POST"
            request.httpBody = pending.body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(pending.key, forHTTPHeaderField: "Idempotency-Key")
            let (data, response) = try await session.data(for: request)
            if let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) || (400..<500).contains(status) {
                try FileManager.default.removeItem(at: files.appendingPathComponent("pending.json"))
                pendingWrite = nil
            }
            try check(response, data: data)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let credential = json["credential"] as? String,
               let member = json["member"] as? [String: Any],
               let memberID = member["id"] as? String, let memberName = member["name"] as? String {
                issuedCredential = IssuedCredential(id: memberID, name: memberName, value: credential)
            }
            etag = nil
            do { try await fetch(); error = nil }
            catch { self.error = "记录已保存；刷新暂未成功，请下拉刷新。" }
            return true
        } catch {
            self.error = error.localizedDescription + (pendingWrite == nil ? "" : "；已保留请求编号，可重试核实。")
            return false
        }
    }

    /// Explicit user confirmation only: archive locally, never resend or change server records.
    @discardableResult func confirmPendingManuallyChecked() -> Bool {
        guard !isBusy, let pending = pendingWrite else { return false }
        do {
            let archive = ResolvedPendingWrite(request: pending, manuallyCheckedAt: DeskDate.string(),
                                               note: "用户确认已在原平台核对请求结果；仅结束本机待核实，不重发、不撤销服务端记录。")
            try save(archive, name: "pending-checked-\(UUID().uuidString).json")
            try FileManager.default.removeItem(at: files.appendingPathComponent("pending.json"))
            pendingWrite = nil
            error = nil
            return true
        } catch { self.error = "原请求仍保留：\(error.localizedDescription)"; return false }
    }

    /// Short-lived code data bypasses the disk-backed pending-write queue entirely.
    /// Verify the actor again before sending; no credentials follow redirects.
    func privateInboxRequest(path: String, method: String = "GET", payload: [String: Any]? = nil, idempotencyKey: String? = nil) async throws -> Data {
        guard !isDemo, !isBusy, pendingWrite == nil, let workspace = snapshot.workspaceId, !snapshot.me.id.isEmpty else {
            throw DeskError(message: isDemo ? "请连接真实平台后使用；验证码不进入演示数据。" : "请先完成同步或核实待提交记录。")
        }
        let actor = snapshot.me.id, origin = endpoint
        isBusy = true
        defer { isBusy = false }
        try await fetch()
        guard endpoint == origin, snapshot.me.id == actor, snapshot.workspaceId == workspace else { throw DeskError(message: "连接身份已变化，请重新打开。") }
        let url = try Self.validEndpoint(origin)
        var request = URLRequest(url: url.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let payload {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(idempotencyKey ?? UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
        }
        let (data, response) = try await session.data(for: request)
        guard endpoint == origin, snapshot.me.id == actor, snapshot.workspaceId == workspace, !isDemo else { throw DeskError(message: "连接身份已变化，结果未显示。") }
        guard let http = response as? HTTPURLResponse else { throw DeskError(message: "连接中断，请刷新后核实结果。") }
        guard (200..<300).contains(http.statusCode) else { throw InboxAPIError(status: http.statusCode) }
        return data
    }

    private func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"]
            throw DeskError(message: message ?? "服务响应异常，请检查连接地址与网络")
        }
    }
    private func addDemoEvent(task: WorkTask, kind: String, body: String, notify: String) {
        snapshot.events.insert(Activity(id: (snapshot.events.map(\.id).max() ?? 0) + 1, taskId: task.id, kind: kind, body: body,
                                        actorId: snapshot.me.id, actorName: snapshot.me.name, timestamp: DeskDate.string(), toLeader: true, notifyMemberId: notify), at: 0)
    }
    func persistDemo() -> Bool {
        reconcileDemoAlerts()
        snapshot.rebuildDemoDashboard()
        do { try save(snapshot, name: "demo.json"); error = nil; publishSummary(); return true }
        catch { self.error = "演示记录保存失败：\(error.localizedDescription)"; return false }
    }
    private func save<T: Encodable>(_ object: T, name: String) throws {
        try JSONEncoder().encode(object).write(to: files.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
    }
    private func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: files.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
