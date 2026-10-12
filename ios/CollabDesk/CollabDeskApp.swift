import SwiftUI

@main
struct CollabDeskApp: App {
    @UIApplicationDelegateAdaptor(DeskAppDelegate.self) private var appDelegate
    @ObservedObject private var push=PushManager.shared
    @StateObject private var store: DeskStore
    @StateObject private var guide: GuideState
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        let directory = testing ? FileManager.default.temporaryDirectory.appendingPathComponent("UITests-\(UUID().uuidString)") : nil
        let defaults = testing ? UserDefaults(suiteName: "CollabDesk-QA-\(UUID().uuidString)")! : .standard
        _store = StateObject(wrappedValue: DeskStore(directory: directory, defaults: defaults, forceDemo: testing))
        _guide = StateObject(wrappedValue: GuideState(defaults: defaults, skipAutomaticWelcome: testing && ProcessInfo.processInfo.arguments.contains("--skip-welcome")))
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(store)
                .environmentObject(guide)
                .tint(DeskStyle.accent)
                .task {
                    GlanceBridge.shared.start()
                    GlanceBridge.shared.refresh = { [weak store] in await store?.refresh() }
                    await store.refresh()
                    if !store.isDemo { await push.restoreRegistration() }
                }
                .onChange(of:push.token) { _,value in if value != nil && !UserDefaults.standard.bool(forKey:"pushOptOut") { Task { await store.syncPushDevice() } } }
                .onChange(of:store.isDemo) { _,demo in if !demo { Task { await push.restoreRegistration(); if push.token != nil && !UserDefaults.standard.bool(forKey:"pushOptOut") { await store.syncPushDevice() } } } }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await store.refresh() } }
                }
        }
    }
}
