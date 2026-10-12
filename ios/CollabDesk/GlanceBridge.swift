import Foundation
import WidgetKit
import WatchConnectivity

extension Snapshot {
    func glance(isDemo: Bool, syncedAt: Date?, publishedAt: Date = Date()) -> GlanceSnapshot {
        guard !me.id.isEmpty else { return .empty(at: publishedAt) }
        let authorizationCount = me.role == "admin" ? userAuthorizationInbox.count :
            (me.role == "leader" ? leaderAuthorizationInbox.count : (authorizations ?? []).filter { $0.pending && $0.requesterId == me.id }.count)
        let picked = openTasks.sorted { a, b in
            if a.priority != b.priority { return a.priority == "high" }
            return a.updatedAt > b.updatedAt
        }.prefix(3)
        return GlanceSnapshot(schemaVersion: GlanceSnapshot.schema, publishedAt: publishedAt, syncedAt: isDemo ? nil : syncedAt,
                              mode: isDemo ? "demo" : "live", role: me.role, authorizations: authorizationCount,
                              inProgress: tasks.filter { $0.status == .in_progress }.count,
                              reviews: me.role == "admin" ? userReviewInbox.count : leaderReviewInbox.count,
                              redAlerts: inboxAlerts.filter { $0.severity == "red" }.count,
                              yellowAlerts: inboxAlerts.filter { $0.severity == "yellow" }.count,
                              tasks: picked.map { GlanceTask(id: $0.id, title: String($0.title.prefix(120)), status: $0.status.label) })
    }
}

@MainActor final class GlanceBridge: NSObject, WCSessionDelegate {
    static let shared = GlanceBridge()
    private var packet = GlanceSnapshot.empty()
    private var started = false
    var refresh: (() async -> Void)?
    var cacheStatus = "尚未发布摘要"
    func start() {
        guard !started else { return }; started = true
        if WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
    }
    func publish(_ value: GlanceSnapshot) {
        start(); packet = value
        if let cache = GlanceCache.shared() {
            do { try cache.write(value); cacheStatus = "小组件摘要已更新"; WidgetCenter.shared.reloadTimelines(ofKind: "CollabDeskOverview") }
            catch { cacheStatus = "摘要写入失败，请重新打开 App" }
        } else { cacheStatus = "App Group 尚未就绪，请检查 Xcode 签名配置" }
        sendLatest()
    }
    private func sendLatest() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isPaired,
              WCSession.default.isWatchAppInstalled, let data = try? packet.encoded() else { return }
        do { try WCSession.default.updateApplicationContext(["glance": data]) }
        catch { /* Keep local cache; next activation/refresh sends the latest snapshot. */ }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.sendLatest() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["request"] as? String == "refresh-glance" else { replyHandler(["error": "unknown_request"]); return }
        Task { @MainActor in
            await self.refresh?()
            if let data = try? self.packet.encoded() { replyHandler(["glance": data]) }
            else { replyHandler(["error": "snapshot_unavailable"]) }
        }
    }
}
