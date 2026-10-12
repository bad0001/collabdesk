import Foundation
import SwiftUI
import WatchConnectivity

@MainActor final class WatchDeskStore: NSObject, ObservableObject, WCSessionDelegate {
    @Published var packet: GlanceSnapshot
    @Published var notice = "摘要来自 iPhone；不是实时在线状态"
    @Published var busy = false
    private let cache: GlanceCache
    private let preview: Bool
    private var timeout: Task<Void, Never>?
    init(preview: Bool = false) {
        self.preview = preview
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        cache = GlanceCache(file: folder.appendingPathComponent("CollabDesk/glance.json"))
        packet = preview ? .preview() : (cache.read() ?? .empty(at: Date(timeIntervalSince1970: 0)))
        super.init()
        if !preview && WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
    }
    func receive(_ data: Data) {
        guard let incoming = try? GlanceSnapshot.decode(data), incoming.isNewer(than: packet) else { return }
        do { try cache.write(incoming) } catch { notice = "已收到摘要，但本地保存失败" }
        packet = incoming; busy = false; timeout?.cancel()
        notice = incoming.isDemo ? "这是手机的演示数据" : "摘要来自 iPhone；不是实时在线状态"
    }
    func refresh() {
        guard !preview else { notice = "演示模式不连接真实 iPhone"; return }
        guard !busy else { return }
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            notice = "iPhone 暂未连通，显示上次缓存"; return
        }
        busy = true; notice = "正在请求手机同步…"
        WCSession.default.sendMessage(["request": "refresh-glance"], replyHandler: { reply in
            Task { @MainActor in
                if let data = reply["glance"] as? Data { self.receive(data) }
                else { self.busy = false; self.notice = "手机未返回摘要，保留缓存" }
            }
        }, errorHandler: { _ in
            Task { @MainActor in self.busy = false; self.notice = "手机同步未完成，保留缓存" }
        })
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, self?.busy == true else { return }
            self?.busy = false; self?.notice = "同步等待超时，保留上次缓存"
        }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let data = session.receivedApplicationContext["glance"] as? Data { Task { @MainActor in self.receive(data) } }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let data = applicationContext["glance"] as? Data { Task { @MainActor in self.receive(data) } }
    }
}
