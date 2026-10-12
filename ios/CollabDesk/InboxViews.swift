import SwiftUI

struct UserRequestCard: View {
    let item: UserRequest
    var body: some View {
        Panel {
            HStack(alignment: .top, spacing: 12) {
                SoftIcon(symbol: item.kind == "code" ? "key" : "hand.raised", color: DeskStyle.accent, size: 38)
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text("\(item.requesterName) 找你").font(.subheadline.weight(.semibold)); Spacer(); Tag(text: item.kindLabel, color: DeskStyle.accent) }
                    Text(item.subject).font(.subheadline).lineLimit(1)
                    HStack { Text(item.stateLabel).font(.caption).foregroundStyle(.secondary); Spacer(); Text("查看 / 回复").font(.caption).foregroundStyle(DeskStyle.accent) }
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).padding(.top, 7)
            }.foregroundStyle(.primary)
        }
    }
}

struct UserRequestsView: View {
    @EnvironmentObject var store: DeskStore
    @State private var historyExpanded = false
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if store.snapshot.userRequests == nil {
                    EmptyPanel(title: "求助中心待后台更新", detail: "现有来信在消息会话里，仍可直接回复。", symbol: "bubble.left")
                } else {
                    ForEach(store.snapshot.activeUserRequests) { item in
                        NavigationLink { UserRequestDetailView(requestID: item.id) } label: { UserRequestCard(item: item) }.buttonStyle(.plain)
                    }
                    if store.snapshot.activeUserRequests.isEmpty { EmptyPanel(title: "都处理好了", detail: "Worker 需要你时，会在这里留下请求。", symbol: "checkmark.circle") }
                    let history = (store.snapshot.userRequests ?? []).filter { !$0.active }
                    if !history.isEmpty {
                        Panel { DisclosureGroup("已处理 · \(history.count)", isExpanded: $historyExpanded) {
                            VStack(spacing: 12) { ForEach(history) { item in NavigationLink { UserRequestDetailView(requestID: item.id) } label: { UserRequestCard(item: item) }.buttonStyle(.plain) } }.padding(.top, 10)
                        }.font(.subheadline) }
                    }
                }
            }.padding(18)
        }.background(DeskStyle.background).navigationTitle("找我的事").navigationBarTitleDisplayMode(.inline).refreshable { await store.refresh() }
    }
}

struct UserRequestDetailView: View {
    @EnvironmentObject var store: DeskStore
    let requestID: Int
    @State private var response = ""
    @State private var confirmResolution = false
    private var item: UserRequest? { store.snapshot.userRequests?.first { $0.id == requestID } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let item {
                    Panel {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text("\(item.requesterName) 找你").font(.headline); Spacer(); Tag(text: item.kindLabel) }
                            Text(item.subject).font(.title3.weight(.semibold))
                            Text(item.body).font(.body).textSelection(.enabled)
                            HStack { Tag(text: item.stateLabel); Spacer(); Text(DeskDate.display(item.createdAt)).font(.caption).foregroundStyle(.secondary) }
                            if let taskID = item.taskId { NavigationLink { TaskDetailView(taskID: taskID) } label: { Label(taskID, systemImage: "checklist").font(.subheadline) } }
                        }
                    }
                    if !item.responseBody.isEmpty {
                        Panel { VStack(alignment: .leading, spacing: 9) { Text("你的回复").font(.headline); Text(item.responseBody).textSelection(.enabled); if let stamp = item.responseAt { Text(DeskDate.display(stamp)).font(.caption).foregroundStyle(.secondary) } } }
                    }
                    if item.active && store.snapshot.me.role == "admin" {
                        if item.kind == "code" {
                            NavigationLink { CodeVaultView() } label: { Label("到验证码库按申请分发", systemImage: "key").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                        } else {
                            Panel {
                                VStack(alignment: .leading, spacing: 12) {
                                    TextField("直接回复这个 Worker", text: $response, axis: .vertical).lineLimit(3...7).accessibilityIdentifier("userRequestReply")
                                    Button("发送回复") { Task { if await store.replyUserRequest(item, body: response) { response = "" } } }.buttonStyle(.borderedProminent).disabled(response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isBusy)
                                    Text("回复会留痕；不等于批准授权或完成验收。").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button("这件事已解决") { confirmResolution = true }.buttonStyle(.bordered).disabled(store.isBusy)
                    }
                    if let error = store.error { Text(error).font(.caption).foregroundStyle(DeskStyle.danger) }
                } else { EmptyPanel(title: "暂未找到请求", detail: "下拉刷新；旧后台可先在消息会话回复。", symbol: "bubble.left") }
            }.padding(18)
        }.background(DeskStyle.background).navigationTitle("请求详情").navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
            .confirmationDialog("确认这件事已经解决？", isPresented: $confirmResolution, titleVisibility: .visible) {
                Button("标记已解决") { if let item { Task { await store.resolveUserRequest(item) } } }
            } message: { Text("仅结束这条求助；任务、授权、验收仍按各自流程处理。") }
    }
}
