import Foundation

/// Minimal read-only packet. Never contains credentials, URLs, messages or full task bodies.
struct GlanceTask: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let status: String
}

struct GlanceSnapshot: Codable, Equatable {
    static let schema = 2
    let schemaVersion: Int
    let publishedAt: Date
    let syncedAt: Date?
    let mode: String // demo, live, unavailable
    let role: String
    let authorizations: Int
    let inProgress: Int
    let reviews: Int
    let redAlerts: Int
    let yellowAlerts: Int
    let tasks: [GlanceTask]
    var hasData: Bool { mode == "demo" || mode == "live" }
    var isDemo: Bool { mode == "demo" }
    var authorizationLabel: String { role == "admin" ? "待你授权" : (role == "leader" ? "待你审批" : "等待授权") }
    var reviewLabel: String { role == "admin" ? "待你终审" : (role == "leader" ? "待你验收" : "待验收") }
    func isStale(at date: Date = Date()) -> Bool {
        guard let syncedAt else { return !isDemo }
        return !isDemo && date.timeIntervalSince(syncedAt) > 900
    }
    static func empty(at date: Date = Date()) -> Self {
        Self(schemaVersion: schema, publishedAt: date, syncedAt: nil, mode: "unavailable", role: "admin",
             authorizations: 0, inProgress: 0, reviews: 0, redAlerts: 0, yellowAlerts: 0, tasks: [])
    }
    func isNewer(than other: GlanceSnapshot) -> Bool { publishedAt >= other.publishedAt }
    static func preview(at date: Date = Date()) -> Self {
        Self(schemaVersion: schema, publishedAt: date, syncedAt: nil, mode: "demo", role: "admin",
             authorizations: 1, inProgress: 2, reviews: 1, redAlerts: 1, yellowAlerts: 1,
             tasks: [GlanceTask(id: "TASK-000003", title: "整理一份资料", status: "待协助")])
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32_768 else { throw GlanceError.invalid }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let value = try decoder.decode(Self.self, from: data)
        guard value.schemaVersion == schema, ["demo", "live", "unavailable"].contains(value.mode),
              ["admin", "leader", "worker"].contains(value.role), value.tasks.count <= 3,
              [value.authorizations, value.inProgress, value.reviews, value.redAlerts, value.yellowAlerts].allSatisfy({ $0 >= 0 }),
              value.tasks.allSatisfy({ DeskRoute.task($0.id).url != nil && $0.title.count <= 120 && $0.status.count <= 32 }),
              value.hasData || (value.tasks.isEmpty && value.authorizations == 0 && value.inProgress == 0 && value.reviews == 0 && value.redAlerts == 0 && value.yellowAlerts == 0)
        else { throw GlanceError.invalid }
        return value
    }
}

enum GlanceError: Error { case invalid }

enum DeskRoute: Equatable, Identifiable {
    case authorizations, alerts, tasks, task(String), messages, message(Int), userRequests, userRequest(Int)
    var id: String { url?.absoluteString ?? "invalid" }
    var url: URL? {
        switch self {
        case .authorizations: return URL(string: "collabdesk://authorizations")
        case .alerts: return URL(string: "collabdesk://alerts")
        case .tasks: return URL(string: "collabdesk://tasks")
        case .messages: return URL(string: "collabdesk://messages")
        case .userRequests: return URL(string: "collabdesk://user-requests")
        case .userRequest(let id):
            guard id > 0 else { return nil }
            return URL(string: "collabdesk://user-request/\(id)")
        case .message(let id):
            guard id > 0 else { return nil }
            return URL(string: "collabdesk://message/\(id)")
        case .task(let id):
            guard id.range(of: #"^TASK-[0-9]{6,}$"#, options: .regularExpression) != nil else { return nil }
            return URL(string: "collabdesk://task/\(id)")
        }
    }
    init?(url: URL) {
        guard url.scheme == "collabdesk", url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return nil }
        switch (url.host, url.path) {
        case ("authorizations", ""): self = .authorizations
        case ("alerts", ""): self = .alerts
        case ("tasks", ""): self = .tasks
        case ("messages", ""):
            guard url.absoluteString == "collabdesk://messages" else { return nil }
            self = .messages
        case ("user-requests", ""):
            guard url.absoluteString == "collabdesk://user-requests" else { return nil }
            self = .userRequests
        case ("user-request", let path):
            let rawID = String(path.dropFirst())
            guard path.hasPrefix("/"), let id = Int(rawID), id > 0, rawID == String(id),
                  URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath == "/\(id)",
                  url.absoluteString == "collabdesk://user-request/\(id)" else { return nil }
            self = .userRequest(id)
        case ("message", let path):
            let rawID = String(path.dropFirst())
            guard path.hasPrefix("/"), let id = Int(rawID), id > 0, rawID == String(id),
                  URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath == "/\(id)",
                  url.absoluteString == "collabdesk://message/\(id)" else { return nil }
            self = .message(id)
        case ("task", let path):
            let id = String(path.dropFirst())
            guard path.hasPrefix("/"), DeskRoute.task(id).url != nil else { return nil }
            self = .task(id)
        default: return nil
        }
    }
}

struct GlanceCache {
    static let groupID = "group.org.example.collabdesk"
    let file: URL
    static func shared() -> Self? {
        guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        return Self(file: folder.appendingPathComponent("glance-v2.json"))
    }
    func read() -> GlanceSnapshot? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? GlanceSnapshot.decode(data)
    }
    func write(_ packet: GlanceSnapshot) throws {
        _ = try GlanceSnapshot.decode(packet.encoded())
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try packet.encoded().write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
