import SwiftUI
import UIKit
import UserNotifications

struct PushOpen { let url: URL; let workspaceID: String }

extension Notification.Name { static let deskPushOpened = Notification.Name("deskPushOpened") }

enum PushPermissionState: Equatable {
    case unknown, notAsked, denied, allowed, quiet, temporary
    var label: String {
        switch self {
        case .unknown: return "待检查"
        case .notAsked: return "尚未询问"
        case .denied: return "未允许"
        case .allowed: return "已允许"
        case .quiet: return "暂时允许 · 安静递送"
        case .temporary: return "临时允许"
        }
    }
    var allowsRegistration: Bool { self == .allowed || self == .quiet || self == .temporary }
    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notAsked
        case .denied: self = .denied
        case .authorized: self = .allowed
        case .provisional: self = .quiet
        case .ephemeral: self = .temporary
        @unknown default: self = .unknown
        }
    }
}

@MainActor final class PushManager: ObservableObject {
    static let shared = PushManager()
    @Published var status = "尚未开启系统提醒"
    @Published var token: String?
    @Published var pendingOpen: PushOpen?
    @Published var permission = PushPermissionState.unknown
    @Published var lockScreenSetting = "待检查"
    @Published var soundSetting = "待检查"
    var installationID: String {
        if let id=UserDefaults.standard.string(forKey:"pushInstallationID") { return id }
        let id=UUID().uuidString; UserDefaults.standard.set(id,forKey:"pushInstallationID"); return id
    }
    var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }
    func refreshPermissionState() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        permission = PushPermissionState(settings.authorizationStatus)
        lockScreenSetting = Self.settingLabel(settings.lockScreenSetting)
        soundSetting = Self.settingLabel(settings.soundSetting)
    }
    private static func settingLabel(_ setting: UNNotificationSetting) -> String {
        switch setting {
        case .enabled: return "已开启"
        case .disabled: return "未开启"
        case .notSupported: return "系统未支持"
        @unknown default: return "待检查"
        }
    }
    func requestPermission() async {
        do {
            let accepted=try await UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.badge,.sound])
            await refreshPermissionState()
            if accepted { status="已允许提醒，正在登记设备"; UIApplication.shared.registerForRemoteNotifications() }
            else { status="通知权限未开启，可到系统设置调整" }
        } catch { status="通知权限申请失败，请在系统设置检查" }
    }
    func restoreRegistration() async {
        await refreshPermissionState()
        if permission.allowsRegistration { UIApplication.shared.registerForRemoteNotifications() }
        else { status="系统提醒尚未允许" }
    }
}
final class DeskAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,didFinishLaunchingWithOptions launchOptions:[UIApplication.LaunchOptionsKey:Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate=self; return true
    }
    func application(_ application:UIApplication,didRegisterForRemoteNotificationsWithDeviceToken deviceToken:Data) {
        let token=deviceToken.map { String(format:"%02x",$0) }.joined()
        Task { @MainActor in PushManager.shared.token=token; PushManager.shared.status="设备凭据已取得，等待平台登记" }
    }
    func application(_ application:UIApplication,didFailToRegisterForRemoteNotificationsWithError error:Error) {
        Task { @MainActor in PushManager.shared.status="设备推送登记失败，请检查开发者签名与网络" }
    }
    func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification,withCompletionHandler completionHandler:@escaping (UNNotificationPresentationOptions)->Void) { completionHandler([.banner,.sound,.list]) }
    func userNotificationCenter(_ center:UNUserNotificationCenter,didReceive response:UNNotificationResponse,withCompletionHandler completionHandler:@escaping ()->Void) {
        if let route=response.notification.request.content.userInfo["route"] as? String,let url=URL(string:route),DeskRoute(url:url) != nil {
            if let workspace=response.notification.request.content.userInfo["workspaceId"] as? String { Task { @MainActor in PushManager.shared.pendingOpen=PushOpen(url:url,workspaceID:workspace) } }
        }
        completionHandler()
    }
}
struct PushSettingsView: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var manager = PushManager.shared
    @AppStorage("pushOptOut") private var optedOut = false
    private var canRegister: Bool { !store.isDemo && store.snapshot.me.role == "admin" }
    var body: some View {
        Form {
            Section("推送准备情况") {
                LabeledContent("此设备的平台提醒", value: optedOut ? "已停用" : "允许登记")
                LabeledContent("系统通知权限", value: manager.permission.label)
                LabeledContent("锁屏显示", value: manager.lockScreenSetting)
                LabeledContent("声音", value: manager.soundSetting)
                LabeledContent("设备标识", value: manager.token == nil ? "尚未取得" : "已取得")
                if let status = store.snapshot.pushStatus {
                    LabeledContent("服务器推送配置", value: status.configured ? "已配置" : "待配置")
                    if !status.configured {
                        Text(status.configProblem ?? "服务器尚未配置 Apple 推送密钥；设备登记后也暂时收不到锁屏提醒。")
                            .font(.caption).foregroundStyle(DeskStyle.warning)
                    }
                } else {
                    Text(store.isDemo ? "演示模式不登记真实设备。" : "刷新后查看服务器推送配置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(manager.status).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button(optedOut ? "重新开启平台提醒" : "开启锁屏与声音提醒") {
                    Task {
                        optedOut = false
                        await manager.requestPermission()
                        if manager.permission.allowsRegistration, manager.token != nil { await store.syncPushDevice() }
                        await store.refresh()
                    }
                }.disabled(!canRegister || store.isBusy)
                Button("打开系统通知设置") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button("停用本机的平台推送") { Task { await store.syncPushDevice(enabled: false); await store.refresh() } }
                    .disabled(!canRegister || optedOut || store.isBusy)
            }
            Section("会提醒你的事") {
                Label("Worker 找你的问题或资料请求", systemImage: "hand.raised")
                Label("直接发给你的消息", systemImage: "bubble.left.and.bubble.right")
                Label("需要你亲自处理的授权", systemImage: "checkmark.shield")
                Label("Leader 转交的用户终审", systemImage: "checkmark.seal")
                Text("Worker 与 Leader 的内部交流、普通审批与常规验收不打扰你。锁屏只显示概括提醒，点击后查看消息或办理事项。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let status = store.snapshot.pushStatus {
                Section("发送记录") {
                    LabeledContent("登记设备", value: String(status.registeredDevices))
                    LabeledContent("等待发送", value: String(status.queued))
                    LabeledContent("Apple 已接受", value: String(status.acceptedByAPNs))
                    LabeledContent("发送失败", value: String(status.failed))
                    Text(status.deliveryNote).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("系统权限、专注模式、通知摘要和网络会影响提醒显示。Apple 接受不等于手机已显示；请在系统设置允许锁屏、横幅与声音。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.error { Text(error).foregroundStyle(DeskStyle.danger).font(.caption) }
        }.navigationTitle("系统提醒").navigationBarTitleDisplayMode(.inline)
            .task { await manager.refreshPermissionState() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await manager.refreshPermissionState() } } }
            .refreshable { await manager.refreshPermissionState(); await store.refresh() }
    }
}
