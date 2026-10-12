import SwiftUI

enum DeskTab: Hashable { case overview, tasks, ledger, messages, settings }
enum GuideSheet: String, Identifiable { case help, practice; var id: String { rawValue } }
enum GuideAction { case overview, tasks, newTask, messages, settings, practice, welcome }

/// Help has its own local state. Opening, skipping and practising never writes
/// business records, changes credentials, switches workspaces or calls an API.
@MainActor final class GuideState: ObservableObject {
    static let welcomeKey = "guide.welcomeSeen.v1"
    @Published var tab: DeskTab = .overview
    @Published var showWelcome: Bool
    @Published var sheet: GuideSheet?
    @Published var newTaskRequested = false
    @Published var destination: DeskRoute?
    private(set) var pending: GuideAction?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, skipAutomaticWelcome: Bool = false) {
        self.defaults = defaults
        showWelcome = !defaults.bool(forKey: Self.welcomeKey) && !skipAutomaticWelcome
    }

    func finishWelcome(goTo action: GuideAction? = nil) {
        defaults.set(true, forKey: Self.welcomeKey)
        pending = action
        showWelcome = false
    }

    func leaveHelp(goTo action: GuideAction) {
        pending = action
        sheet = nil
    }

    // Run after the previous modal finishes dismissing, so a new sheet isn't
    // lost by presenting over the still-closing welcome/help sheet.
    func performPendingNavigation() {
        guard let action = pending else { return }
        pending = nil
        switch action {
        case .overview: tab = .overview
        case .tasks: tab = .tasks
        case .newTask: tab = .tasks; newTaskRequested = true
        case .messages: tab = .messages
        case .settings: tab = .settings
        case .practice: sheet = .practice
        case .welcome: showWelcome = true
        }
    }
}

enum PracticeStage: Int, CaseIterable {
    case assign, working, review, done
    var status: TaskStatus {
        switch self { case .assign: return .pending; case .working: return .in_progress; case .review: return .awaiting_review; case .done: return .completed }
    }
    var title: String {
        switch self {
        case .assign: return "Leader 已安排负责人"
        case .working: return "Worker 接单并汇报"
        case .review: return "Leader 核对成果"
        case .done: return "你看结论与待办"
        }
    }
    var detail: String {
        switch self {
        case .assign: return "你在 Leader 的聊天窗口提出需求。Leader 在平台写清任务、完成标准并指派 AI B；你不必自己填写任务卡。"
        case .working: return "AI B 轮询到分给自己的任务，接单后在原窗口工作；进展和困难登记在同一任务里，Leader 会看到。"
        case .review: return "AI B 提交成果，Leader 先核对并决定通过、打回或转派。只有需要你判断的事项才交给你。"
        case .done: return "你在 App 看结果与真正需要你处理的事。授权卡由你到相应账号操作；普通授权按选定的 Leader 或用户处理，成果则先由 Leader 核对。"
        }
    }
    var buttonTitle: String {
        switch self {
        case .assign: return "模拟 Worker 接单"
        case .working: return "模拟 Worker 汇报成果"
        case .review: return "模拟 Leader 核对"
        case .done: return "返回总览"
        }
    }
    var next: PracticeStage { PracticeStage(rawValue: rawValue + 1) ?? .done }
}
