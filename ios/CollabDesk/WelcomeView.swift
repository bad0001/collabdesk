import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var store: DeskStore
    @EnvironmentObject var guide: GuideState
    @State private var step = 0
    private var title: String {
        if step == 0 { return "你交办，AI 协作" }
        if step == 1 { return "只记住这三个地方" }
        return store.isDemo ? "先用示例熟悉一下" : "现在，开始你的协作"
    }
    private var subtitle: String {
        if step == 0 { return "先在 Leader 的聊天窗口交办。\n这个平台让 AI 之间交换进展，不用你逐项派单。" }
        if step == 1 { return "平时你主要看结果和待办。\n成员接入放在设置里。" }
        return store.isDemo ? "当前是本地演示，不是真实工作进度。\n正式服务已上线，你可以先练习再连接。" : "你已选择真实服务。\n记录会同步，但不会替 AI 自动开工。"
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 6) {
                        ForEach(0..<3) { index in Capsule().fill(index == step ? DeskStyle.accent : DeskStyle.accent.opacity(0.12)).frame(height: 4) }
                    }.accessibilityHidden(true)
                    SoftIcon(symbol: ["person.3.sequence.fill", "square.grid.2x2", "hand.tap"][step], size: 68)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(title).font(.largeTitle.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("welcomeTitle")
                        Text(subtitle).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Panel {
                        VStack(alignment: .leading, spacing: 22) {
                            if step == 0 {
                                GuideLine(symbol: "person.crop.circle", title: "你：在 Leader 窗口交办", detail: "说清目标和资料，不用先打开 App 填任务卡。")
                                GuideLine(symbol: "person.badge.shield.checkmark", title: "Leader：发布与统筹", detail: "在平台指派任务、处理交给它的授权、先核对所有成果；只把需要你决定的事交给你。")
                                GuideLine(symbol: "checklist", title: "Worker：接单与汇报", detail: "轮询自己名下的任务，完成后在平台向 Leader 汇报。")
                            } else if step == 1 {
                                GuideLine(symbol: "square.grid.2x2", title: "总览：看需你处理的事", detail: "授权卡、指定给你的普通授权、Leader 转交的终审优先展示；其他进展与异常往下看。")
                                GuideLine(symbol: "checklist", title: "任务：核对进展和留痕", detail: "点开任务能看到负责人、来源、成果、授权与完整历史。")
                                GuideLine(symbol: "person.3", title: "设置：成员与接入", detail: "添加 AI、给它起名字、选择角色，再把各自凭据放进保管库。")
                            } else {
                                GuideLine(symbol: "hand.tap", title: "先看 AI 怎么协作", detail: "模拟 Leader 指派、Worker 汇报、Leader 核对。练习不保存，也不发给任何 AI。")
                                GuideLine(symbol: "questionmark.circle", title: "忘了也没关系", detail: "总览右上角「？」或「设置 → 怎么用协作台」都能重新查看。")
                                if store.isDemo {
                                    GuideLine(symbol: "network", title: "正式服务已经上线", detail: "设置里可编辑 HTTPS 地址，再填你自己的用户管理凭据。AI 用各自独立凭据；不用服务器私钥。")
                                } else {
                                    GuideLine(symbol: "person.crop.circle.badge.checkmark", title: "真实操作按身份留痕", detail: "Leader 发布后由已接入的 Worker 按自己的检查节奏读取，不是实时派工。")
                                }
                            }
                        }
                    }
                }.padding(24)
            }.background(DeskStyle.background)
                .navigationTitle("快速上手 · \(step + 1)/3").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("稍后再看") { guide.finishWelcome() }.accessibilityIdentifier("skipWelcome")
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 12) {
                        Button {
                            if step < 2 { step += 1 } else { guide.finishWelcome(goTo: .practice) }
                        } label: {
                            Text(step < 2 ? "下一步" : "带我练一遍").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                        }.buttonStyle(.borderedProminent).accessibilityIdentifier("welcomeNext")
                        if step == 2 {
                            Button("先进入总览") { guide.finishWelcome(goTo: .overview) }.font(.subheadline).padding(.vertical, 5)
                        } else if step > 0 {
                            Button("上一步") { step -= 1 }.font(.subheadline).padding(.vertical, 5)
                        }
                    }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 12).background(DeskStyle.background)
                }
        }.interactiveDismissDisabled()
    }
}

struct GuideLine: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SoftIcon(symbol: symbol, size: 34)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary)
                Text(detail).font(.subheadline).foregroundStyle(Color.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
