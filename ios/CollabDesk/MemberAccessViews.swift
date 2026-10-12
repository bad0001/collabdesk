import SwiftUI
import UIKit

struct MembersAccessView: View {
    @EnvironmentObject var store: DeskStore
    @State private var adding = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(title: "AI 成员", subtitle: "显示名称可修改，成员 ID 与历史保持不变")
                if store.snapshot.me.role == "admin" {
                    Button { adding = true } label: {
                        Label("添加 AI", systemImage: "person.badge.plus").frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("addAIMember")
                }
                ForEach(store.snapshot.members.filter { $0.role != "admin" }) { member in
                    NavigationLink { MemberAccessDetailView(memberID: member.id) } label: {
                        Panel {
                            HStack(alignment: .center, spacing: 12) {
                                SoftIcon(symbol: member.role == "leader" ? "person.badge.shield.checkmark" : "person", size: 36)
                                VStack(alignment: .leading, spacing: 4) {
                                    AdaptiveColumns {
                                        Text(member.name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary)
                                        Text(member.roleLabel).font(.caption).foregroundStyle(Color.secondary)
                                    }
                                    Text(member.id).font(.caption.monospaced()).foregroundStyle(Color.secondary)
                                    Text(member.lastPollAt.map { "最近访问 \(DeskDate.display($0))" } ?? "尚无真实轮询记录")
                                        .font(.caption2).foregroundStyle(Color.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }.buttonStyle(.plain)
                }
                if store.snapshot.members.filter({ $0.role != "admin" }).isEmpty {
                    EmptyPanel(title: "还没有 AI 成员", detail: "先添加你的 Leader，再添加 Worker。", symbol: "person.3")
                }
                Text(store.isDemo ? "当前是本地演示：可以练习命名，不会生成真实接入凭据。正式服务已上线；先在设置用你的用户管理凭据连接。" : "真实凭据只在添加或轮换后显示一次。请存入对应 AI 的保管库，别把你的管理凭据交给 AI，也别把 Leader 凭据给 Worker。")
                    .font(.caption).foregroundStyle(.secondary)
                Panel {
                    DisclosureGroup("接入说明") {
                        GuideLine(symbol: "person.3", title: "先登记 AI，再交接凭据", detail: "你可以自由设置显示名称并选择 Leader / Worker。每个 AI 在自己的聊天窗口工作，平台只保存协作信息；文档或名字本身都不代表已连接。")
                        Text("身份与显示名分开；最近访问只说明 API 被访问，不等于 AI 持续在线。")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    }.font(.subheadline)
                }
                Panel {
                    DisclosureGroup("交给 Leader 的接入资料") {
                        AIGuideLinks()
                        Text("本协作台公开手册来自 api.example.com，可以直接分享，不含秘密。Worker 模板先交 Leader 改成各 AI 专用版；你的管理凭据与各 AI 凭据分别保管。")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    }.font(.subheadline)
                }
            }.padding(16)
        }.background(DeskStyle.background).navigationTitle("成员与接入")
            .refreshable { await store.refresh() }
            .sheet(isPresented: $adding) { AddAIMemberSheet() }
    }
}

struct AddAIMemberSheet: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var role = "worker"
    @State private var created = false
    var body: some View {
        NavigationStack {
            Form {
                if created {
                    if let credential = store.issuedCredential {
                        CredentialDeliverySection(credential: credential)
                    } else {
                        Section { Text("演示成员已添加，只留在本机。正式服务已上线；连接后需在真实平台重新登记成员并单独交接它的凭据。") }
                    }
                } else {
                    Section("成员资料") {
                        TextField("你想叫它什么名字", text: $name).accessibilityIdentifier("aiDisplayName")
                        Picker("角色", selection: $role) { Text("Worker · 执行任务").tag("worker"); Text("Leader · 统筹助理").tag("leader") }
                    }
                    Section { Text("任务职责可以变化。系统自动生成稳定成员 ID；之后改显示名不改变身份和历史。") }
                    if let error = store.error { Section { Text(error).foregroundStyle(.red).font(.caption) } }
                }
            }.navigationTitle(created ? "保存接入资料" : "添加 AI").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { store.issuedCredential = nil; dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        if created { Button("完成") { store.issuedCredential = nil; dismiss() } }
                        else {
                            Button("添加") {
                                Task { if await store.registerMember(name: name.trimmingCharacters(in: .whitespacesAndNewlines), role: role) { created = true } }
                            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 100 || store.isBusy)
                                .accessibilityIdentifier("saveAIMember")
                        }
                    }
                }
        }
    }
}

struct MemberAccessDetailView: View {
    @EnvironmentObject var store: DeskStore
    let memberID: String
    @State private var name = ""
    @State private var showRotation = false
    private var member: Member? { store.snapshot.members.first { $0.id == memberID } }
    var body: some View {
        Form {
            if let member {
                Section("身份") {
                    LabeledContent("成员 ID", value: member.id)
                    LabeledContent("角色", value: member.roleLabel)
                    LabeledContent("参与状态", value: member.participationLabel)
                    LabeledContent("最近访问", value: member.lastPollAt.map(DeskDate.display) ?? "尚无真实轮询")
                }
                if store.snapshot.me.role == "admin" {
                    Section("显示名称") {
                        TextField("给 AI 起个名字", text: $name).accessibilityIdentifier("renameAIField")
                        Button("保存名称") { Task { _ = await store.renameMember(member, name: name.trimmingCharacters(in: .whitespacesAndNewlines)) } }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == member.name || store.isBusy)
                            .accessibilityIdentifier("saveAIName")
                        Text("改名不会改变成员 ID、凭据或已有任务历史。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !store.isDemo {
                        Section("接入凭据") {
                            if let credential = store.issuedCredential, credential.id == member.id {
                                CredentialDeliverySection(credential: credential)
                                Button("我已保存") { store.issuedCredential = nil }
                            } else {
                                Button("重新生成接入凭据") { showRotation = true }
                                Text("重新生成会让这个 AI 的旧凭据立即失效。只在需要更换或首次接入资料丢失时操作。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let error = store.error { Section { Text(error).foregroundStyle(.red).font(.caption) } }
                Section {
                    DisclosureGroup("该角色的使用资料") {
                        AIGuideLinks(guides: [member.role == "leader" ? .leader : .worker, .platform])
                        Text("手册链接不含凭据。成员自己的环境完成身份核对和首次访问后，才算真正接入；近期访问也不等于持续在线。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("自报额度参考") {
                        LabeledContent("额度说明", value: member.quotaNote.isEmpty ? "尚未上报" : member.quotaNote)
                        LabeledContent("预算分组", value: member.budgetGroup.isEmpty ? "未设置" : member.budgetGroup)
                        Text("由 AI 自行上报，供 Leader 调配时参考，不是平台查询到的实时额度。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("参考资料") }
            }
        }.scrollContentBackground(.hidden).background(DeskStyle.background).navigationTitle("成员资料")
            .onAppear { name = member?.name ?? "" }
            .confirmationDialog("重新生成接入凭据？", isPresented: $showRotation, titleVisibility: .visible) {
                Button("重新生成，旧凭据失效", role: .destructive) {
                    if let member { Task { _ = await store.rotateMemberCredential(member) } }
                }
            } message: { Text("请在新凭据出现后立即存入该 AI 的保管库。") }
    }
}

struct CredentialDeliverySection: View {
    let credential: IssuedCredential
    var body: some View {
        Section("只显示一次的接入凭据") {
            LabeledContent("成员", value: "\(credential.name) · \(credential.id)")
            Text(credential.value).font(.footnote.monospaced()).textSelection(.enabled)
                .accessibilityIdentifier("oneTimeMemberCredential")
            Button("复制凭据") { UIPasteboard.general.string = credential.value }
            Text("这是该 AI 的成员凭据，不是你的用户管理凭据。请导入该 AI 的保管库；不要贴进普通聊天或手册。复制后，剪贴板也会暂存这串凭据。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
