import AppIntents
import SwiftUI

/// The handoff is RAM-only: no SMS, candidate or code is encoded in a URL,
/// app-group file, widget packet, clipboard listener or pending-write queue.
@MainActor final class SMSImportBridge: ObservableObject {
    static let shared = SMSImportBridge()
    @Published var candidates: [String] = []
    var capturedAt = Date()
    func clear() { candidates = [] }
}

struct ExtractSMSCodeIntent: AppIntent {
    static var title: LocalizedStringResource = "提取短信验证码"
    static var description = IntentDescription("从你交给快捷指令的文字里提取验证码候选，打开协作台由你确认来源与共享范围。不会读取短信历史或自动上传。")
    static var openAppWhenRun: Bool = true
    @Parameter(title: "短信内容") var message: String
    @Parameter(title: "收到时间（可选）") var receivedTime: Date?
    static var parameterSummary: some ParameterSummary { Summary("从 \(\.$message) 提取验证码") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let values = SMSCodeParser.candidates(in: message)
        SMSImportBridge.shared.capturedAt = receivedTime ?? Date()
        SMSImportBridge.shared.candidates = values
        let dialog: IntentDialog = values.isEmpty ? "没有找到明确标注的验证码，请在协作台手动检查。" : "候选已提取。请在协作台确认来源、账号和用途，再决定共享给哪个任务。"
        return .result(dialog: dialog)
    }
}
struct CollabDeskShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ExtractSMSCodeIntent(), phrases: ["用 \(.applicationName) 提取短信验证码"], shortTitle: "提取短信验证码", systemImageName: "key")
        AppShortcut(intent: AutomaticallyIngestSMSCodeIntent(), phrases: ["用 \(.applicationName) 自动入库短信验证码"], shortTitle: "自动入库短信验证码", systemImageName: "bolt.shield")
    }
}

/// Independent background intent; never routes through the foreground bridge,
/// DeskStore, app UI, the admin credential or the disk-backed pending queue.
struct AutomaticallyIngestSMSCodeIntent: AppIntent {
    static var title: LocalizedStringResource = "自动入库短信验证码"
    static var description = IntentDescription("启用后，从本次信息提取验证码、品牌、时间与有效期自动入库，不打开填写页、不上传完整短信。不读取短信历史。")
    static var openAppWhenRun: Bool = false
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .background }
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @Parameter(title: "短信内容") var message: String
    @Parameter(title: "收到时间（可选）") var receivedTime: Date?
    static var parameterSummary: some ParameterSummary { Summary("自动入库 \(\.$message) 中的验证码") }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let dialog: IntentDialog
        do {
            let count = try await SMSAutomaticImporter.shared.ingest(message: message, receivedTime: receivedTime)
            if count == nil { dialog = "没有发现明确标注的验证码，本次没有上传。" }
            else if count == 0 { dialog = "本次信息已处理，没有重复入库。" }
            else { dialog = "验证码已自动入库。" }
        } catch let error as SMSAutomationError {
            dialog = IntentDialog(stringLiteral: error.localizedDescription)
        } catch {
            dialog = "本次自动入库未确认，请在协作台查看结果。"
        }
        return .result(dialog: dialog)
    }
}
