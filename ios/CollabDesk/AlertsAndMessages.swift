import SwiftUI

struct AlertsListView: View {
    @EnvironmentObject var store: DeskStore
    @State private var includeHistory = false
    var alerts: [AlertRecord] { includeHistory ? (store.snapshot.alerts ?? []) : store.snapshot.activeAlerts }
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Toggle("包含已解除提醒", isOn: $includeHistory).font(.subheadline).padding(.bottom, 4)
                ForEach(alerts) { alert in
                    NavigationLink { AlertDetailView(alertID: alert.id) } label: { AlertCard(alert: alert) }.buttonStyle(.plain)
                }
                if alerts.isEmpty { EmptyPanel(title: "暂无提醒", detail: "当前没有可显示的异常。", symbol: "checkmark.circle") }
            }.padding(16)
        }.background(DeskStyle.background).navigationTitle("异常待办").navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
    }
}

struct AlertDetailView: View {
    @EnvironmentObject var store: DeskStore
    let alertID: Int
    @State private var action: String?
    @State private var historyExpanded = false
    var alert: AlertRecord? { store.snapshot.alerts?.first { $0.id == alertID } }
    var body: some View {
        ScrollView {
            if let alert {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(alert.title).font(.title2.weight(.semibold))
                        AdaptiveColumns { Tag(text: alert.levelLabel, color: DeskStyle.severity(alert.severity), symbol: "exclamationmark.circle.fill"); Tag(text: alert.stateLabel) }
                    }
                    Panel {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(alert.detail).font(.body).textSelection(.enabled)
                            Divider()
                            Label(store.snapshot.memberName(alert.memberId), systemImage: "person.crop.circle")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text("提醒 #\(alertID)").font(.caption.monospaced()).foregroundStyle(.tertiary)
                            Text("首次出现：\(DeskDate.display(alert.createdAt))").font(.caption).foregroundStyle(.secondary)
                            if let until = alert.snoozedUntil { Text("暂缓至：\(DeskDate.display(until))").font(.caption).foregroundStyle(.secondary) }
                            if let taskID = alert.taskId, store.snapshot.tasks.contains(where: { $0.id == taskID }) {
                                NavigationLink { TaskDetailView(taskID: taskID) } label: { Label("查看任务与交接记录", systemImage: "arrow.up.right.square") }
                            }
                        }
                    }
                    if store.snapshot.me.privileged && alert.state != "resolved" {
                        Panel {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("处理提醒").font(.headline)
                                Text("已读不等于解除；转派请到任务里处理。")
                                    .font(.caption).foregroundStyle(.secondary)
                                AdaptiveColumns {
                                    Button("标记已读") { action = "acknowledge" }.buttonStyle(.bordered)
                                    Button("暂缓跟进") { action = "snooze" }.buttonStyle(.bordered)
                                }
                                if alert.kind == "blocked" {
                                    Button("问题已解决，恢复执行") { action = "resolve" }.buttonStyle(.borderedProminent)
                                }
                            }
                        }
                    }
                    Panel {
                        let history = (store.snapshot.alertEvents ?? []).filter { $0.alertId == alert.id }
                        DisclosureGroup("提醒历史 · \(history.count) 条", isExpanded: $historyExpanded) {
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(history) { event in
                                    TimelineRow(title: event.actorId.map { store.snapshot.memberName($0) } ?? "平台规则", bodyText: event.body, time: event.timestamp)
                                }
                                if history.isEmpty { Text("暂无历史").font(.subheadline).foregroundStyle(.secondary) }
                            }.padding(.top, 12)
                        }.font(.subheadline).tint(Color.secondary)
                    }
                }.padding(16)
                .sheet(isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } })) {
                    AlertActionSheet(alert: alert, action: action ?? "acknowledge")
                }
            } else { EmptyPanel(title: "记录不在当前工作区", detail: "请返回并刷新。", symbol: "tray").padding(16) }
        }.background(DeskStyle.background).navigationTitle("提醒详情").navigationBarTitleDisplayMode(.inline)
    }
}

struct AlertActionSheet: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) var dismiss
    let alert: AlertRecord
    let action: String
    @State private var note = ""
    @State private var minutes = 30
    var title: String { ["acknowledge": "标记已读", "snooze": "暂缓跟进", "resolve": "恢复执行"][action] ?? "处理异常" }
    var body: some View {
        NavigationStack {
            Form {
                Section { Text(alert.title).font(.headline); Text(alert.detail).font(.subheadline).foregroundStyle(.secondary) }
                Section("处理说明（会留痕）") { TextField("说明处理意见或问题如何解决", text: $note, axis: .vertical).lineLimit(4...8).accessibilityIdentifier("alertNote") }
                if action == "snooze" {
                    Section { Picker("稍后再提醒", selection: $minutes) { Text("15 分钟").tag(15); Text("30 分钟").tag(30); Text("1 小时").tag(60); Text("2 小时").tag(120) } }
                }
                if let error = store.error { Section { Text(error).foregroundStyle(DeskStyle.danger).font(.caption) } }
            }.scrollContentBackground(.hidden).background(DeskStyle.background)
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("确认") { Task { if await store.alertAction(alert, action: action, note: note, minutes: minutes) { dismiss() } } }.disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isBusy) }
                }
        }
    }
}

private struct MessageComposeContext: Identifiable {
    let id = UUID()
    var recipientID: String? = nil
    var replyTo: DirectMessage? = nil
}

struct MessagesView: View {
    @EnvironmentObject var store: DeskStore
    @State private var composing: MessageComposeContext?
    @State private var category = "messages"
    @State private var includeAll = false
    @State private var announcementsExpanded = false
    @State private var rulesExpanded = false
    private var conversations: [MessageConversation] { store.snapshot.conversations(includeAll: includeAll) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("消息分类", selection: $category) {
                        Text("会话").tag("messages"); Text("公告").tag("announcements")
                    }.pickerStyle(.segmented).accessibilityIdentifier("messageCategory")
                    if category == "messages" {
                        if includeAll && store.snapshot.me.privileged {
                            HStack { Text("全部协作").font(.caption).foregroundStyle(.secondary); Spacer(); Button("返回我的会话") { includeAll = false }.font(.caption) }
                        }
                        if conversations.isEmpty {
                            EmptyPanel(title: "这里很安静", detail: "AI 给你的消息会按成员归在一起。", symbol: "bubble.left.and.bubble.right")
                        }
                        ForEach(conversations) { conversation in
                            Panel {
                                VStack(alignment: .leading, spacing: 10) {
                                    NavigationLink { ConversationDetailView(conversationID: conversation.id, includeAll: includeAll) } label: {
                                        HStack(spacing: 12) {
                                            SoftIcon(symbol: "bubble.left.and.bubble.right", size: 38)
                                            VStack(alignment: .leading, spacing: 6) {
                                                HStack {
                                                    Text(conversation.title(in: store.snapshot)).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                                    Spacer(minLength: 4)
                                                    if conversation.unread(for: store.snapshot.me.id) > 0 { Tag(text: "\(conversation.unread(for: store.snapshot.me.id)) 未读", color: DeskStyle.accent) }
                                                }
                                                Text(conversation.latest.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                                Text(DeskDate.display(conversation.latest.createdAt)).font(.caption2).foregroundStyle(.tertiary)
                                            }
                                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                        }
                                    }.buttonStyle(.plain).accessibilityIdentifier("conversation-\(conversation.latest.id)")
                                    if let incoming = conversation.messages.first(where: { store.snapshot.replyRecipient(for: $0) != nil }), let recipientID = store.snapshot.replyRecipient(for: incoming) {
                                        HStack { Spacer(); Button("快速回复") { composing = MessageComposeContext(recipientID: recipientID, replyTo: incoming) }.font(.caption.weight(.semibold)).accessibilityIdentifier("reply-message-\(incoming.id)") }
                                    }
                                }
                            }
                        }
                    } else {
                        announcementGroup(title: "公告", kind: "announcement", expanded: $announcementsExpanded)
                        announcementGroup(title: "协作规则", kind: "rule", expanded: $rulesExpanded)
                    }
                }.padding(18)
            }.scrollIndicators(.hidden).background(DeskStyle.background).navigationTitle("消息").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("新消息", systemImage: "square.and.pencil") { composing = MessageComposeContext() }
                            if store.snapshot.me.privileged {
                                Button(includeAll ? "只看我的会话" : "查看全部协作", systemImage: "person.2") { includeAll.toggle(); category = "messages" }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("消息更多操作")
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) { ConnectionBanner() }
                .refreshable { await store.refresh() }
                .sheet(item: $composing) { context in ComposeSheet(initialRecipient: context.recipientID, replyTo: context.replyTo) }
        }
    }
    private func announcementGroup(title: String, kind: String, expanded: Binding<Bool>) -> some View {
        let values = store.snapshot.announcements.filter { $0.kind == kind || (kind == "announcement" && $0.kind != "rule") }
        return Panel {
            DisclosureGroup(isExpanded: expanded) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(values) { item in
                        DisclosureGroup {
                            Text(item.body).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 8)
                            Text("\(item.actorName) · \(DeskDate.display(item.createdAt))").font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
                        } label: { Text(item.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary) }
                    }
                    if values.isEmpty { Text("暂无内容").font(.subheadline).foregroundStyle(.secondary) }
                }.padding(.top, 12)
            } label: { HStack { SoftIcon(symbol: kind == "rule" ? "text.badge.checkmark" : "megaphone", size: 34); Text(title).font(.headline); Spacer(); Text("\(values.count)").font(.subheadline).foregroundStyle(.secondary) } }
        }
    }
}

struct ConversationDetailView: View {
    @EnvironmentObject var store: DeskStore
    let conversationID: String
    var includeAll = false
    @State private var historyExpanded = false
    private var conversation: MessageConversation? { store.snapshot.conversations(includeAll: includeAll).first { $0.id == conversationID } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let conversation {
                    ForEach(Array(conversation.messages.prefix(3))) { message in compactMessage(message) }
                    if conversation.messages.count > 3 {
                        Panel {
                            DisclosureGroup("更早的消息 · \(conversation.messages.count - 3)", isExpanded: $historyExpanded) {
                                VStack(spacing: 12) { ForEach(Array(conversation.messages.dropFirst(3))) { message in compactMessage(message) } }.padding(.top, 12)
                            }.font(.subheadline)
                        }
                    }
                } else { EmptyPanel(title: "暂未找到会话", detail: "下拉刷新后再查看。", symbol: "bubble.left") }
            }.padding(18)
        }.background(DeskStyle.background).navigationTitle(conversation?.title(in: store.snapshot) ?? "会话").navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
    }
    private func compactMessage(_ message: DirectMessage) -> some View {
        NavigationLink { MessageDetailView(messageID: message.id) } label: {
            Panel {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(message.senderId == store.snapshot.me.id ? "我" : message.senderName).font(.subheadline.weight(.semibold)); Spacer(); if message.recipientId == store.snapshot.me.id && message.readAt == nil { Tag(text: "未读", color: DeskStyle.accent) } }
                    Text(message.body).font(.body).lineLimit(3).foregroundStyle(.primary)
                    HStack { Text(DeskDate.display(message.createdAt)).font(.caption).foregroundStyle(.tertiary); Spacer(); Text("查看 / 回复").font(.caption).foregroundStyle(DeskStyle.accent) }
                }
            }
        }.buttonStyle(.plain).accessibilityIdentifier("message-\(message.id)")
    }
}

struct MessageDetailView: View {
    @EnvironmentObject var store: DeskStore
    let messageID: Int
    @State private var composing: MessageComposeContext?
    private var message: DirectMessage? { store.snapshot.messages?.first { $0.id == messageID } }
    var body: some View {
        ScrollView {
            if let message {
                VStack(alignment: .leading, spacing: 16) {
                    Panel {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(message.senderName).font(.title2.weight(.semibold))
                            Text("发给 \(store.snapshot.memberName(message.recipientId))").font(.subheadline).foregroundStyle(.secondary)
                            Divider()
                            Text(message.body).font(.body).textSelection(.enabled)
                            Text(DeskDate.display(message.createdAt)).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Tag(text: message.readAt == nil ? "未读" : "已读")
                                Spacer()
                                if message.recipientId == store.snapshot.me.id && message.readAt == nil {
                                    Button("标记已读") { Task { await store.readMessage(message) } }.font(.subheadline).disabled(store.isBusy)
                                }
                            }
                        }
                    }
                    if let recipientID = store.snapshot.replyRecipient(for: message) {
                        Button { composing = MessageComposeContext(recipientID: recipientID, replyTo: message) } label: {
                            Label("回复 \(message.senderName)", systemImage: "arrowshape.turn.up.left")
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                        }.buttonStyle(.borderedProminent).disabled(store.isBusy)
                            .accessibilityIdentifier("reply-message-detail")
                    }
                    Text("消息 #\(messageID) · 身份与时间由平台记录")
                        .font(.caption).foregroundStyle(.tertiary)
                }.padding(16)
            } else {
                EmptyPanel(title: "这条消息暂未找到", detail: "请刷新当前工作区；消息内容以平台最新记录为准。", symbol: "bubble.left")
                    .padding(16)
            }
        }.background(DeskStyle.background).navigationTitle("消息详情").navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
            .sheet(item: $composing) { context in ComposeSheet(initialRecipient: context.recipientID, replyTo: context.replyTo) }
    }
}

struct ComposeSheet: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) var dismiss
    let initialRecipient: String?
    let replyTo: DirectMessage?
    @State private var kind = "message"
    @State private var recipient = ""
    @State private var title = ""
    @State private var bodyText = ""
    @State private var initialized = false
    init(initialRecipient: String? = nil, replyTo: DirectMessage? = nil) {
        self.initialRecipient = initialRecipient
        self.replyTo = replyTo
    }
    var recipients: [Member] { store.snapshot.messageRecipients }
    private var validRecipient: Bool { recipients.contains { $0.id == recipient } }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if replyTo == nil {
                        Picker("类型", selection: $kind) {
                            Text("定向消息").tag("message")
                            if store.snapshot.me.privileged { Text("公告").tag("announcement"); Text("规则").tag("rule") }
                        }
                    }
                    if kind == "message" {
                        Picker("发给", selection: $recipient) { ForEach(recipients) { Text($0.name).tag($0.id) } }
                            .accessibilityIdentifier("messageRecipient")
                    } else { TextField("标题", text: $title) }
                } footer: { Text(kind == "message" ? "发送给所选成员；Leader 与用户具有协作统管权限。" : "所有协作成员可查看公告与规则。") }
                if let replyTo {
                    Section("回复参考 · \(replyTo.senderName)") {
                        Text(replyTo.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
                        Text("原消息 #\(replyTo.id)").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Section("内容") {
                    TextField("填写消息，身份和时间由平台记录", text: $bodyText, axis: .vertical)
                        .lineLimit(6...12).accessibilityIdentifier("messageBody")
                }
                if let error = store.error { Section { Text(error).font(.caption).foregroundStyle(DeskStyle.danger) } }
            }.scrollContentBackground(.hidden).background(DeskStyle.background)
                .navigationTitle(replyTo == nil ? "发布消息" : "回复消息").navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    guard !initialized else { return }
                    recipient = store.snapshot.preferredMessageRecipient(initialRecipient)
                    initialized = true
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("发送") {
                            Task {
                                let success = kind == "message" ? await store.sendMessage(to: recipient, body: bodyText) : await store.announce(title: title, body: bodyText, kind: kind)
                                if success { dismiss() }
                            }
                        }.disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (kind != "message" && title.isEmpty) || (kind == "message" && !validRecipient) || store.isBusy)
                            .accessibilityIdentifier("sendMessage")
                    }
                }
        }
    }
}
