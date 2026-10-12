import SwiftUI

struct CodeAutomationInstallation: Decodable {
    let installationId: String
    let enabled: Bool
    let scope: String
    let enabledAt: String
    let disabledAt: String?
}
private struct CodeAutomationEnableResponse: Decodable {
    let credential: String
    let installation: CodeAutomationInstallation
}
private struct CodeAutomationStatusResponse: Decodable { let installations: [CodeAutomationInstallation] }

extension DeskStore {
    func enableSMSAutomation() async throws {
        guard !isDemo, snapshot.me.role == "admin", let workspace = snapshot.workspaceId else { throw SMSAutomationError.badConnection }
        let origin = try CodeAutomationBinding.origin(endpoint), actor = snapshot.me.id
        let installation = try CodeAutomationKeychain.installationID()
        let data = try await privateInboxRequest(path: "/v1/codes/automation/enable", method: "POST", payload: ["installationId": installation])
        let result = try JSONDecoder().decode(CodeAutomationEnableResponse.self, from: data)
        guard result.installation.installationId == installation, result.installation.enabled,
              result.installation.scope == "code-ingest" else { throw SMSAutomationError.invalidCredential }
        let binding = CodeAutomationBinding(endpoint: origin, workspaceID: workspace, memberID: actor, installationID: installation)
        guard binding.matches(endpoint: endpoint, workspaceID: snapshot.workspaceId, memberID: snapshot.me.id, role: snapshot.me.role, demo: isDemo) else { throw SMSAutomationError.bindingChanged }
        try CodeAutomationKeychain.save(CodeAutomationCredential(binding: binding, credential: result.credential, enabledAt: result.installation.enabledAt))
    }
    func disableSMSAutomation() async throws {
        let value = try CodeAutomationKeychain.read()
        // Stop locally first. A failed revoke never leaves automatic uploading on.
        try CodeAutomationKeychain.stop()
        guard let value, value.binding.matches(endpoint: endpoint, workspaceID: snapshot.workspaceId, memberID: snapshot.me.id, role: snapshot.me.role, demo: isDemo) else { return }
        _ = try await privateInboxRequest(path: "/v1/codes/automation/disable", method: "POST", payload: ["installationId": value.binding.installationID])
    }
    func SMSAutomationStatus() async throws -> Bool {
        guard !isDemo else { return false }
        guard let value = try CodeAutomationKeychain.read() else { return false }
        guard value.binding.matches(endpoint: endpoint, workspaceID: snapshot.workspaceId, memberID: snapshot.me.id, role: snapshot.me.role, demo: isDemo) else { try CodeAutomationKeychain.stop(); return false }
        let response = try JSONDecoder().decode(CodeAutomationStatusResponse.self, from: await privateInboxRequest(path: "/v1/codes/automation/status"))
        guard response.installations.contains(where: { $0.installationId == value.binding.installationID && $0.enabled && $0.scope == "code-ingest" }) else { try CodeAutomationKeychain.stop(); return false }
        return true
    }
}

struct SMSAutomationSettingsView: View {
    @EnvironmentObject var store: DeskStore
    @State private var enabled = false
    @State private var loading = false
    @State private var confirmation = false
    @State private var notice: String?
    var body: some View {
        Form {
            Section {
                HStack { Label("短信自动入库", systemImage: "bolt.shield"); Spacer(); if loading { ProgressView() } else { Text(enabled ? "已启用" : "未启用").foregroundStyle(enabled ? DeskStyle.accent : .secondary) } }
                Text("识别验证码、短信品牌、用途与有效期，不用逐条填写。未写明的来源与用途标为未知，由 AI 按任务挑选；号码不向所有成员公开。").font(.caption).foregroundStyle(.secondary)
                if !store.isDemo, store.snapshot.me.role == "admin" {
                    if enabled { Button("停用自动入库", role: .destructive) { Task { await disable() } } }
                    else { Button("启用自动入库") { confirmation = true }.accessibilityIdentifier("enableSMSAutomation") }
                } else { Text("连接你的用户管理账号后启用；演示模式不会上传。").font(.caption).foregroundStyle(.secondary) }
                if let notice { Text(notice).font(.caption).foregroundStyle(DeskStyle.warning) }
            }.disabled(loading || store.isBusy)
            Section("快捷指令 · 只设置一次") {
                Text("在“信息”自动化里，把动作换成协作台的“自动入库短信验证码”，将“短信内容”绑定本次快捷指令输入。").font(.subheadline)
                Text("选择“立即运行”可省去逐次询问；继续选择“确认后运行”则每次由系统询问。动作本身不打开填写页。").font(.caption).foregroundStyle(.secondary)
                Text("收到时间可选；没有传入时标记提取时间。首次设置后用一条新的信息检查。锁屏调度和网络仍由 iOS 管理，重启后先解锁一次。").font(.caption).foregroundStyle(.secondary)
            }
            if !store.isDemo {
                Section("当前绑定") {
                    LabeledContent("用户", value: store.snapshot.me.name)
                    Text(store.endpoint).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("共享范围") {
                Text("只传候选数字、品牌标签、用途、时间及有效期，短信正文和发件人号码不上传。后台使用仅能入库的独立设备凭据，不使用你的管理密钥。").font(.caption).foregroundStyle(.secondary)
                Text("默认 5 分钟，短信注明更短有效期时从其时间计算，最长 15 分钟。掉网不保存短信、不自动重试。切换账号、地址或演示模式会停止本机自动上传。").font(.caption).foregroundStyle(.secondary)
            }
        }.scrollContentBackground(.hidden).background(DeskStyle.background)
            .navigationTitle("短信自动入库").navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .confirmationDialog("启用本机短信自动入库？", isPresented: $confirmation, titleVisibility: .visible) {
                Button("同意并启用") { Task { await enable() } }
            } message: {
                Text("后续交给这个快捷指令动作的新短信会自动提取验证码并通过 HTTPS 上传到当前协作台。AI 看标签并按任务申请领取；完整短信不上传。只对当前用户、工作区和本机生效，可随时停用。启用后仍需在快捷指令选择新动作。").privacySensitive()
            }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do { enabled = try await store.SMSAutomationStatus(); notice = nil }
        catch { enabled = (try? CodeAutomationKeychain.read()) != nil; notice = "状态同步未确认；本机状态见上方，可先停用再检查。" }
    }
    private func enable() async {
        loading = true; defer { loading = false }
        do { try await store.enableSMSAutomation(); enabled = true; notice = "已启用。请将快捷指令换成“自动入库短信验证码”；以后不用填来源或用途。" }
        catch { enabled = (try? CodeAutomationKeychain.read()) != nil; notice = "启用未确认，请核对平台连接后重新启用。" }
    }
    private func disable() async {
        loading = true; defer { loading = false }
        do { try await store.disableSMSAutomation(); enabled = false; notice = "本机已停止自动上传。" }
        catch { enabled = (try? CodeAutomationKeychain.read()) != nil; notice = enabled ? "本机停用未确认，请重试。" : "本机已停止自动上传；服务端撤销暂未确认，恢复连接后可重新启用。" }
    }
}
