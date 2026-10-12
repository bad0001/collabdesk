import SwiftUI

struct HelpView: View {
    @EnvironmentObject var store: DeskStore
    @EnvironmentObject var guide: GuideState
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("先找 Leader，不用自己派单").font(.title.weight(.bold))
                        Text(store.isDemo ? "当前 App 显示本地示例，正式 HTTPS 服务已上线。平时在 Leader 窗口交办；App 主要看进展、成果和需要你亲自处理的事。" : "在 Leader 窗口交办，由它在平台发布并调配 Worker。你在这里看结果和需要你亲自处理的事。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Button { guide.leaveHelp(goTo: .practice) } label: {
                        Panel {
                            HStack(spacing: 12) {
                                SoftIcon(symbol: "hand.tap")
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("用示例练一遍").font(.headline).foregroundStyle(Color.primary)
                                    Text("不用填写资料，不会保存或发给 AI").font(.caption).foregroundStyle(Color.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption)
                            }
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("startPractice")
                    helpStep("1", title: "交办：直接和 Leader 说", detail: "告诉 Leader 目标、已有资料和期望结果。它在平台建立任务并安排负责人；你不必在 App 再抄一遍。", action: "去看成员与接入", target: .settings)
                    helpStep("2", title: "进展：看总览与任务", detail: "Worker 轮询到任务后接单，在原任务上报进展或困难；Leader 能统管。你主要看需要自己决定的事项。", action: "去看总览", target: .overview)
                    helpStep("3", title: "决定：只处理需要你拍板的事", detail: "普通授权按 AI 选择交给 Leader 或你。授权卡固定由你到相应账号亲自操作，再回 App 确认；成果统一先由 Leader 核对，需要你判断时才转给你终审。", action: "去看我的待办", target: .overview)
                    SectionTitle(title: "常见疑问")
                    Panel {
                        VStack(spacing: 18) {
                            question("谁找我，怎样直接回复？", "首页「需要你处理」优先显示给你的来信和求助，点开即可回复。消息按成员归成会话，早期历史和公告收起；全部协作在右上角更多菜单。回复只是沟通，不会批准授权、替代验收或自动结束任务。新版求助接口要等后台发布，旧消息仍能正常使用。")
                            Divider()
                            question("验证码怎样交给 Worker？", "Worker 先登记任务的来源、账号标签和用途，你从匹配申请导入并确认共享。只有被分配的成员获取号码；Leader 看来源和申请，不看号码。App 不读取短信历史，可粘贴短信或用快捷指令提取候选，再由你确认；过期自动隐藏，明文不进入本机缓存、通知或小组件。验证码库要等后台发布后使用。")
                            Divider()
                            question("我直接把任务给 AI B，也可以吗？", "可以。照常在 B 的聊天窗口交办，让它把任务登记到平台，标为「用户指派」。B 上报后 Leader 就能查看；不必每件事都先经 Leader 转述。前提是这个 AI 已经接入平台。")
                            Divider()
                            question("点了创建，AI 就会马上开工吗？", "不会自动开工。App 只保存任务，AI 仍在独立窗口工作，并按各自的检查节奏读取。本地演示只用于练习，不会联系任何 AI。")
                            Divider()
                            question("黄灯、红灯一定是做错了吗？", "不是。黄色表示需要关注，红色表示更急需处理；可能是进展久未更新、缺资料、额度耗尽或验收反复打回。先点提醒看具体原因，再由 Leader 决定协助或转派。")
                            Divider()
                            question("Worker 说需要授权怎么办？", "普通授权由申请中选定的 Leader 或用户决定，Leader 也可转交你；平台不会自行判断什么是敏感操作。授权卡只能由你在对应账号完成外部操作，再回 App 确认。待审批时，这个任务暂停推进，仍可说明困难。")
                            Divider()
                            question("服务地址和凭据该填什么？", "正式地址是 https://api.example.com，设置里已经给出可编辑建议。你在 App 填自己的用户管理凭据（user / admin），不是 Leader / Worker 凭据、服务器私钥或模型 API Key。点击「验证并连接」才会连接；不会上传演示数据。")
                            Divider()
                            question("怎样让 Leader 和 Worker 接进来？", "在「设置 → 成员与接入」分享 Leader 手册、Worker 模板和全平台说明。先让 Leader 理解平台并把模板改成每个 Worker 专用版，再把各成员独立凭据导入各自保管库。AI 需在自己的环境核对身份并实际访问；只有读过手册或登记名字不代表已经接入。")
                            Divider()
                            question("所有成果都需要我验收吗？", "不用。Worker 的成果统一先交 Leader，由它核对、打回或通过；只有它转交的成果进入你的终审待办。用户直接交给 Worker 的任务也保留来源与留痕。")
                        }
                    }
                    Button("重新看三步新手引导") { guide.leaveHelp(goTo: .welcome) }
                        .font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 10).accessibilityIdentifier("replayWelcome")
                    Button("需要时手动补录任务") { guide.leaveHelp(goTo: .newTask) }
                        .font(.caption).frame(maxWidth: .infinity).padding(.vertical, 6).accessibilityIdentifier("manualTaskFromHelp")
                }.padding(20)
            }.background(DeskStyle.background).navigationTitle("怎么用协作台").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { guide.sheet = nil } } }
        }
    }
    private func helpStep(_ number: String, title: String, detail: String, action: String, target: GuideAction) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                Text("第 \(number) 步").font(.caption.weight(.semibold)).foregroundStyle(DeskStyle.accent)
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(action) { guide.leaveHelp(goTo: target) }.buttonStyle(.bordered)
                    .accessibilityIdentifier("helpStep\(number)")
            }
        }
    }
    private func question(_ title: String, _ answer: String) -> some View {
        DisclosureGroup(title) { Text(answer).font(.subheadline).foregroundStyle(.secondary).padding(.top, 8) }.font(.subheadline)
    }
}

/// A disposable teaching example, intentionally independent of DeskStore.
/// Even when connected, this screen cannot create tasks or send messages.
struct PracticeView: View {
    @EnvironmentObject var guide: GuideState
    @State private var stage: PracticeStage = .assign
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Label("只练习 · 不保存 · 不发给 AI", systemImage: "hand.tap")
                        .font(.caption.weight(.medium)).foregroundStyle(DeskStyle.accent).accessibilityIdentifier("practiceNotice")
                    Text(stage.title).font(.title.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                    Text(stage.detail).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Panel {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack { Text("练习示例").font(.caption).foregroundStyle(.secondary); Spacer() }
                            Text("为一个岗位整理简历").font(.headline)
                            StatusTag(status: stage.status).accessibilityIdentifier("practiceStatus")
                            Divider()
                            LabeledContent("发布与统筹", value: "Leader")
                            LabeledContent("负责人", value: "AI B（执行）")
                            LabeledContent("来源", value: "用户在 Leader 窗口交办")
                            Text("完成标准：简历符合岗位要求，附成果链接，由 Leader 先核对。")
                                .font(.subheadline).foregroundStyle(.secondary)
                            if stage == .review || stage == .done {
                                Label("示例成果已到达", systemImage: "doc.text").font(.subheadline).foregroundStyle(DeskStyle.accent)
                                Text("真实任务里，在「成果与来源」打开链接查看文件。这里没有真实文件。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if stage == .done {
                        Panel { GuideLine(symbol: "checkmark.seal", title: "你已经看过一次 AI 协作", detail: "平时在 Leader 窗口提出需求，在 App 看结果；授权卡、指定给你的普通授权和 Leader 转交的终审才进入你的待办。") }
                    }
                }.padding(24)
            }.background(DeskStyle.background)
                .navigationTitle("跟着练 · \(stage.rawValue + 1)/4").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("结束练习") { guide.sheet = nil }.accessibilityIdentifier("closePractice") } }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 10) {
                        Button {
                            if stage == .done { guide.leaveHelp(goTo: .overview) }
                            else { stage = stage.next }
                        } label: {
                            Text(stage.buttonTitle).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                        }.buttonStyle(.borderedProminent).accessibilityIdentifier("practiceNext")
                        if stage != .assign {
                            Button(stage == .done ? "再练一次" : "上一步") { stage = stage == .done ? .assign : PracticeStage(rawValue: stage.rawValue - 1)! }
                                .font(.subheadline).padding(.vertical, 5)
                        }
                    }.padding(.horizontal, 24).padding(.vertical, 12).background(DeskStyle.background)
                }
        }
    }
}
