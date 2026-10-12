import SwiftUI

struct CodeVaultView: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.scenePhase) private var phase
    @State private var vault: CodeVaultResponse?
    @State private var status: String?
    @State private var importing = false
    @State private var importRequest: CodeRequestMetadata?
    @State private var clock = Date()
    @State private var selection: CodeAssignment?
    @State private var revealedID: String?
    @State private var revealedValue = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("短期、按任务共享").font(.subheadline.weight(.medium)); Spacer()
                    if !store.isDemo && store.snapshot.me.role == "admin" {
                        NavigationLink { SMSAutomationSettingsView() } label: { Label("自动入库", systemImage: "bolt.shield") }.font(.subheadline.weight(.semibold)).accessibilityIdentifier("smsAutomationSettings")
                        Menu {
                            Button("手动导入") { importRequest = nil; importing = true }
                        } label: { Image(systemName: "ellipsis.circle").font(.title3) }.accessibilityIdentifier("importVerificationCode")
                    }
                }
                if store.isDemo { Button("练习本机提取") { importRequest = nil; importing = true }.buttonStyle(.bordered).accessibilityIdentifier("practiceSMSExtraction") }
                if let status { EmptyPanel(title: "验证码库暂未就绪", detail: status, symbol: "key") }
                if let vault {
                    let codes = vault.codes.filter { $0.usable(at: clock) }
                    ForEach(codes) { code in
                        Panel {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack { Text(code.service.isEmpty ? "来源未知" : code.service).font(.headline); Spacer(); Tag(text: code.stateLabel, color: DeskStyle.accent) }
                                Text(code.accountLabel.isEmpty ? code.purposeLabel : "\(code.accountLabel) · \(code.purposeLabel)").font(.subheadline).foregroundStyle(.secondary)
                                if code.importMethod == "automatic" { Text(code.timeSource == "received" ? "自动入库 · 收到时间" : "自动入库 · 提取时间").font(.caption).foregroundStyle(.secondary) }
                                if let expires = DeskDate.date(code.expiresAt) { HStack { Text("剩余").font(.caption).foregroundStyle(.secondary); Text(expires, style: .timer).font(.caption.monospacedDigit()).foregroundStyle(DeskStyle.warning) } }
                                if let member = code.assignedMemberId { Text("已给 \(store.snapshot.memberName(member)) · \(code.taskId ?? "")").font(.caption).foregroundStyle(.secondary) }
                                if revealedID == code.id && !revealedValue.isEmpty { Text(revealedValue).font(.title2.monospacedDigit().weight(.semibold)).privacySensitive() }
                                HStack {
                                    if store.snapshot.me.role == "admin" {
                                        Button(revealedID == code.id ? "收起号码" : "查看号码") { Task { await reveal(code) } }.font(.caption)
                                    }
                                    Spacer()
                                    if code.state == "available" && store.snapshot.me.privileged {
                                        Menu("按申请分发") {
                                            let matches = vault.codeRequests.filter { $0.state == "waiting" && $0.matches(code) }
                                            ForEach(matches) { request in Button("\(request.requesterName) · \(request.taskId)") { selection = CodeAssignment(code: code, request: request) } }
                                            if matches.isEmpty { Text("暂无匹配的任务申请") }
                                        }.font(.caption.weight(.medium))
                                    }
                                }.disabled(store.isBusy)
                            }
                        }
                    }
                    if codes.isEmpty { EmptyPanel(title: "没有有效验证码", detail: "过期与已替换的号码不会出现在这里。", symbol: "key") }
                    let requests = vault.codeRequests.filter { $0.state == "waiting" }
                    if !requests.isEmpty {
                        SectionTitle(title: "等验证码的任务")
                        ForEach(requests) { request in
                            Panel { VStack(alignment: .leading, spacing: 8) { HStack { Text(request.requesterName).font(.subheadline.weight(.semibold)); Spacer(); Tag(text: request.taskId) }; Text("\(request.service) · \(request.accountLabel)").font(.subheadline); Text(request.purpose).font(.caption).foregroundStyle(.secondary); if store.snapshot.me.role == "admin" { Button("为这个任务导入") { importRequest = request; importing = true }.font(.caption.weight(.semibold)) } } }
                        }
                    }
                }
                Panel { DisclosureGroup("导入与分发说明") {
                    Text("启用自动入库并换用新快捷指令动作后，不用逐条填写。来源和用途缺失时标为未知；AI 先查看标签，按正式任务申请领取，不向所有成员公开号码。默认 5 分钟，最多 15 分钟，自收到或提取时间计时；完整短信和发件人不上传。仍可通过右上角菜单手动导入。").font(.caption).foregroundStyle(.secondary).padding(.top, 10)
                }.font(.subheadline) }
            }.padding(18)
        }.background(DeskStyle.background).navigationTitle("验证码库").navigationBarTitleDisplayMode(.inline)
            .task { await load() }.refreshable { await load() }
            .task { while !Task.isCancelled { clock = Date(); do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return } } }
            .task(id: revealedID) {
                guard let id = revealedID, let stamp = vault?.codes.first(where: { $0.id == id })?.expiresAt, let expires = DeskDate.date(stamp) else { return }
                let seconds = min(900, max(0, expires.timeIntervalSinceNow))
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
                if revealedID == id { revealedValue = ""; revealedID = nil }
            }
            .sheet(isPresented: $importing, onDismiss: { Task { await load() } }) { CodeImportSheet(request: importRequest) }
            .confirmationDialog("将这个验证码交给该任务？", isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } }), titleVisibility: .visible) {
                if let selection { Button("给 \(selection.request.requesterName)") { Task { await assign(selection) } } }
            } message: { if let selection { Text("\(selection.code.service) · \(selection.code.accountLabel)\n\(selection.request.taskId) · \(selection.request.purpose)\n其他 Worker 不会取得这个号码。") } }
            .onChange(of: phase) { _, value in if value != .active { revealedValue = ""; revealedID = nil; SMSImportBridge.shared.clear() } }
            .onChange(of: store.endpoint) { _, _ in vault = nil; revealedValue = ""; revealedID = nil }
            .onChange(of: store.snapshot.me.id) { _, _ in vault = nil; revealedValue = ""; revealedID = nil }
            .onDisappear { revealedValue = ""; revealedID = nil }
    }
    private func load() async {
        do { vault = try await store.loadCodeVault(); status = nil }
        catch { vault = nil; status = error.localizedDescription }
    }
    private func assign(_ item: CodeAssignment) async {
        selection = nil
        do { try await store.assignVerificationCode(item.code, to: item.request); await load() }
        catch { status = error.localizedDescription }
    }
    private func reveal(_ code: VerificationCodeMetadata) async {
        if revealedID == code.id { revealedID = nil; revealedValue = ""; return }
        do {
            struct Value: Decodable { var code: String; var expiresAt: String }
            let value = try JSONDecoder().decode(Value.self, from: await store.privateInboxRequest(path: "/v1/codes/\(code.id)/value"))
            guard phase == .active, DeskDate.date(value.expiresAt).map({ $0 > Date() }) == true else { return }
            revealedID = code.id; revealedValue = value.code
        } catch { revealedID = nil; revealedValue = ""; status = error.localizedDescription }
    }
}
private struct CodeAssignment { let code: VerificationCodeMetadata; let request: CodeRequestMetadata }

struct CodeImportSheet: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var text = ""
    @FocusState private var smsFocused: Bool
    @State private var candidates: [String] = []
    @State private var chosenCode = ""
    @State private var service = ""
    @State private var account = ""
    @State private var purpose = ""
    @State private var minutes = 5
    @State private var shareConfirmed = false
    @State private var confirmation = false
    @State private var status: String?
    @State private var importKey = UUID().uuidString
    @State private var receivedAt: Date
    private let requestedBy: CodeRequestMetadata?
    init(candidates: [String] = [], receivedAt: Date = Date(), request: CodeRequestMetadata? = nil) {
        _candidates = State(initialValue: candidates); _chosenCode = State(initialValue: candidates.count == 1 ? candidates[0] : "")
        _receivedAt = State(initialValue: receivedAt); requestedBy = request
        _service = State(initialValue: request?.service ?? ""); _account = State(initialValue: request?.accountLabel ?? ""); _purpose = State(initialValue: request?.purpose ?? "")
    }
    private var valid: Bool {
        guard !chosenCode.isEmpty, shareConfirmed else { return false }
        let cleanService = service.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPurpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleanService.isEmpty && !cleanAccount.isEmpty && !cleanPurpose.isEmpty
    }
    private var canSubmit: Bool { valid && !store.isBusy && !store.isDemo && store.snapshot.me.role == "admin" }
    private var submitTitle: String { requestedBy.map { "导入并交给 \($0.requesterName)" } ?? "导入并允许按匹配任务分发" }
    var body: some View {
        NavigationStack {
            formContent
                .scrollContentBackground(.hidden).background(DeskStyle.background)
                .navigationTitle("导入验证码").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消", action: cancel) }
                    ToolbarItem(placement: .confirmationAction) { Button("确认导入") { confirmation = true }.disabled(!canSubmit) }
                }
                .confirmationDialog("确认这个号码的共享范围？", isPresented: $confirmation, titleVisibility: .visible) {
                    Button(submitTitle) { Task { await submit() } }
                } message: { Text("\(service) · \(account)\n用途：\(purpose)\n\(minutes) 分钟内有效。不会向所有 Worker 展示号码。") }
                .onChange(of: phase) { _, value in if value != .active { clear() } }
                .onChange(of: store.endpoint) { _, _ in cancel() }
                .onChange(of: store.snapshot.me.id) { _, _ in cancel() }
                .onDisappear(perform: clear)
        }
    }
    private var formContent: some View {
        Form {
            if store.isDemo { Section { Text("演示只练习本机提取，不上传任何号码。").font(.caption).foregroundStyle(.secondary) } }
            if let request = requestedBy {
                Section("这次交给") {
                    Text("\(request.requesterName) · \(request.taskId)").font(.subheadline.weight(.semibold))
                    Text("按这条申请填写来源与用途，导入后定向分发。").font(.caption).foregroundStyle(.secondary)
                }
            }
            extractionSection
            metadataSection
            if let status { Section { Text(status).font(.caption).foregroundStyle(DeskStyle.warning) } }
        }
    }
    private var extractionSection: some View {
        Section("本机提取") {
            TextField("粘贴包含“验证码”的短信", text: $text, axis: .vertical)
                .lineLimit(3...5).focused($smsFocused).privacySensitive().accessibilityIdentifier("smsImportText")
            Button("提取候选", action: extract).disabled(text.isEmpty)
            ForEach(candidates, id: \.self) { value in
                Button { choose(value) } label: { SMSCandidateRow(value: value, selected: chosenCode == value) }
            }
            if candidates.count > 1 {
                Text("发现多个候选，请手动选择；不会自动挑一个上传。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var metadataSection: some View {
        Section {
            TextField("来源 / 服务，例如招聘网站", text: $service).disabled(requestedBy != nil)
            TextField("账号标签，例如我的求职账号", text: $account).disabled(requestedBy != nil)
            TextField("用途，例如登录（需与申请一致）", text: $purpose).disabled(requestedBy != nil)
            DatePicker("收到 / 提取时间", selection: $receivedAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
            Picker("有效期", selection: $minutes) {
                Text("5 分钟").tag(5)
                Text("10 分钟").tag(10)
                Text("15 分钟").tag(15)
            }
            Toggle("允许按匹配的任务申请共享", isOn: $shareConfirmed)
        } header: { Text("由你核对，不自动猜测") }
          footer: { Text("只上传选中号码和以上标签，不上传完整短信。相同来源、账号、用途只保留最新有效码。Worker 仍需任务申请和定向领取；来源不明请先核实。") }
    }
    private func cancel() { clear(); dismiss() }
    private func extract() {
        smsFocused = false
        receivedAt = Date()
        candidates = SMSCodeParser.candidates(in: text)
        chosenCode = candidates.count == 1 ? candidates[0] : ""
        text = ""; importKey = UUID().uuidString
        status = candidates.isEmpty ? "未找到明确验证码，请检查文字。" : nil
    }
    private func choose(_ value: String) { chosenCode = value; importKey = UUID().uuidString }
    private func clear() { text = ""; candidates = []; chosenCode = ""; SMSImportBridge.shared.clear() }
    private func submit() async {
        let code = chosenCode
        do {
            let imported = try await store.importVerificationCode(code: code, service: service, account: account, purpose: purpose, expiresIn: minutes * 60, receivedAt: receivedAt, key: importKey)
            if let request = requestedBy {
                clear()
                do { try await store.assignVerificationCode(imported, to: request) }
                catch { status = "号码已入库，分发尚未确认。请刷新验证码库后核实。"; return }
            }
            clear(); dismiss()
        } catch { clear(); status = error.localizedDescription + " 刷新验证码库后再决定是否重新导入。" }
    }
}

private struct SMSCandidateRow: View {
    let value: String
    let selected: Bool
    var body: some View {
        HStack {
            Text(value).monospacedDigit().privacySensitive()
            Spacer()
            Image(systemName: "checkmark.circle.fill").opacity(selected ? 1 : 0)
        }
    }
}
