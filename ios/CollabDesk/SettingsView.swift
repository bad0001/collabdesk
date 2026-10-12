import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: DeskStore
    @EnvironmentObject var guide: GuideState
    @State private var address = ""
    @State private var credential = ""
    @State private var initializedAddress = false
    @State private var confirmPendingCheck = false
    @FocusState private var focusedField: ConnectionField?
    private enum ConnectionField: Hashable { case address, credential }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(store.isDemo ? "本地演示" : (store.lastRefresh == nil ? "真实服务 · 待同步" : "已连接服务"), systemImage: store.isDemo ? "square.stack.3d.up" : (store.lastRefresh == nil ? "clock" : "checkmark.shield"))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(store.isDemo ? "所有示例只保存在本机。连接真实服务时不会上传这些数据。" : "当前身份：\(store.snapshot.me.name) · \(store.snapshot.me.roleLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                    if !store.isDemo, let refreshed = store.lastRefresh {
                        Text("最近同步 \(refreshed.formatted(date: .abbreviated, time: .shortened)) · 不代表 AI 持续在线")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("当前连接") }
                Section {
                    TextField(ConnectionGuide.suggestedAddress, text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("serverAddress").focused($focusedField, equals: .address)
                        .submitLabel(.next).onSubmit { focusedField = .credential }
                    SecureField("你的用户管理凭据", text: $credential).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("apiCredential").focused($focusedField, equals: .credential)
                        .submitLabel(.done).onSubmit { focusedField = nil }
                    Button { focusedField = nil; Task { if await store.connect(address: address, credential: credential) { credential = "" } } } label: {
                        HStack { Text("验证并连接"); Spacer(); if store.isBusy { ProgressView() } }
                    }.disabled(store.isBusy || address.isEmpty || credential.isEmpty).accessibilityIdentifier("connectServer")
                    if !store.isDemo, store.lastRefresh != nil {
                        Label("已连接服务", systemImage: "checkmark.shield")
                            .foregroundStyle(DeskStyle.accent).accessibilityIdentifier("connectedStatus")
                    }
                    if let error = store.error { Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("connectionError") }
                    DisclosureGroup("连接说明与凭据安全") {
                        Text("正式 HTTPS 服务已上线，地址可以编辑；点击验证才会连接。你在 App 使用自己的用户管理凭据（user / admin），不要填 Leader 或 Worker 的成员凭据，也不是服务器私钥或模型 API Key。凭据保存在本机钥匙串；演示数据不会上传。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.font(.subheadline)
                } header: { Text("连接真实协作台") } footer: { Text("使用你自己的 user / admin 管理凭据。演示数据不会上传。") }
                if let pending = store.pendingWrite {
                    Section("待核实请求") {
                        Text("请求编号：\(pending.key)").font(.caption).textSelection(.enabled)
                        Text(pending.workspaceId == nil ? "旧版请求没有工作区编号，不自动重发。先在原平台核对是否已保存。" : "请求绑定原成员和工作区。重试前会刷新身份，并沿用原编号避免重复记录。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("刷新核对并重试") { Task { await store.retryPending() } }
                            .disabled(store.isBusy || pending.workspaceId == nil)
                        Button("已核对原请求，结束待核实") { confirmPendingCheck = true }.disabled(store.isBusy)
                    }
                }
                Section("协作管理") {
                    NavigationLink { MembersAccessView() } label: { Label("成员与接入", systemImage: "person.3") }
                        .accessibilityIdentifier("membersAccess")
                    NavigationLink { AuthorizationListView() } label: { Label("授权中心", systemImage: "checkmark.shield") }
                        .accessibilityIdentifier("authorizationCenter")
                }
                Section("设备与提醒") {
                    NavigationLink { SMSAutomationSettingsView() } label: { Label("短信自动入库", systemImage: "bolt.shield") }
                    NavigationLink { PushSettingsView() } label: { Label("锁屏与系统提醒",systemImage:"bell.badge") }
                    NavigationLink { GlanceSettingsView() } label: { Label("小组件与 Watch", systemImage: "applewatch") }
                        .accessibilityIdentifier("glanceSettings")
                }
                Section("使用帮助") {
                    Button { guide.sheet = .help } label: { Label("怎么用协作台", systemImage: "questionmark.circle") }
                        .accessibilityIdentifier("settingsHelp")
                    Button { guide.showWelcome = true } label: { Label("重新看新手引导", systemImage: "sparkles") }
                        .accessibilityIdentifier("settingsWelcome")
                }
                Section("说明与资料") {
                    DisclosureGroup("给 AI 的接入资料") {
                        AIGuideLinks()
                        Text("本协作台的公开手册来自 api.example.com，不含凭据。先把 Leader 手册和 Worker 模板交给 Leader，由它为每个 Worker 写专用版；各成员凭据单独存入对应保管库。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("提醒规则") {
                        let rules = store.snapshot.rules ?? AlertRules()
                        LabeledContent("无进展黄灯", value: "\(rules.staleYellowSeconds / 3600) 小时")
                        LabeledContent("无进展红灯", value: "\(rules.staleRedSeconds / 3600) 小时")
                        LabeledContent("漏轮询黄 / 红", value: "\(rules.heartbeatYellowMisses) / \(rules.heartbeatRedMisses) 次")
                        LabeledContent("网络宽限", value: "\(rules.heartbeatGraceSeconds) 秒")
                        Text("规则修改会留痕。固定轮询模式才检查漏心跳；按更新唤醒的成员，静默待命不算失联。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("平台如何协作") {
                        Label("信息协作，不代替 AI 执行", systemImage: "text.bubble")
                        Label("完成不自动转派，已读不代表验收", systemImage: "person.crop.circle.badge.checkmark")
                        Label("只统计平台中已经登记的工作", systemImage: "tray.full")
                        Text("AI 在各自窗口工作，通过 REST API 交流。检查频率由各自环境配置；平台不运行模型。当前匿名更新信号未开启，不要把访问凭据放进无密钥 hook。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !store.isDemo {
                    Section { Button("切换到本地演示") { store.useDemo() }.disabled(store.isBusy || store.pendingWrite != nil) }
                }
                Section {
                    LabeledContent("版本", value: "0.5.5 · 自动入库")
                    Text("小组件与 Watch 使用手机的只读摘要；数据时间会明确显示。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = store.error { Section { DisclosureGroup("详细连接提示") { Text(error).font(.caption).foregroundStyle(.red) } } }
            }.scrollContentBackground(.hidden).background(DeskStyle.background).navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    if !initializedAddress {
                        address = ConnectionGuide.addressSuggestion(existing: store.endpoint)
                        initializedAddress = true
                    }
                }
                .onChange(of: store.endpoint) { _, endpoint in
                    if !endpoint.isEmpty { address = endpoint }
                }
                .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成输入") { focusedField = nil } } }
                .confirmationDialog("已在原平台核对请求结果？", isPresented: $confirmPendingCheck, titleVisibility: .visible) {
                    Button("已核对，保留本机归档并结束待核实") { store.confirmPendingManuallyChecked() }
                    Button("还没有，继续保留", role: .cancel) { }
                } message: { Text("这只结束本机的待核实状态，不重发、不撤销任何服务端记录。请先按请求编号或任务历史核对；原请求会保留在本机受保护归档。") }
        }
    }
}
