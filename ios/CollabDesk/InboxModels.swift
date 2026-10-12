import Foundation

struct UserRequest: Codable, Identifiable, Equatable {
    let id: Int
    var taskId: String?
    var requesterId: String
    var requesterName: String
    var kind: String
    var subject: String
    var body: String
    var state: String
    var version: Int
    var createdAt: String
    var updatedAt: String
    var responseBody: String
    var responseBy: String?
    var responseAt: String?
    var active: Bool { state == "open" || state == "replied" }
    var kindLabel: String { ["question":"问题", "material":"资料", "code":"验证码", "external_action":"需要你操作"][kind] ?? "求助" }
    var stateLabel: String { ["open":"待你回复", "replied":"已回复 · 待解决", "resolved":"已解决", "cancelled":"已取消"][state] ?? state }
}

struct MessageConversation: Identifiable, Equatable {
    let id: String
    let memberIDs: [String]
    var messages: [DirectMessage]
    var latest: DirectMessage { messages[0] }
    func unread(for memberID: String) -> Int { messages.filter { $0.recipientId == memberID && $0.readAt == nil }.count }
    func title(in snapshot: Snapshot) -> String {
        memberIDs.filter { $0 != snapshot.me.id }.map { snapshot.memberName($0) }.joined(separator: " · ")
    }
}

extension Snapshot {
    var activeUserRequests: [UserRequest] { (userRequests ?? []).filter(\.active).sorted { $0.id > $1.id } }
    func conversations(includeAll: Bool) -> [MessageConversation] {
        let groups = Dictionary(grouping: visibleMessages(includeAll: includeAll)) { message in
            [message.senderId, message.recipientId].sorted().map { "\($0.count):\($0)" }.joined()
        }
        return groups.map { key, values in
            MessageConversation(id: key, memberIDs: [values[0].senderId, values[0].recipientId].sorted(), messages: values.sorted { $0.id > $1.id })
        }.sorted { $0.latest.id > $1.latest.id }
    }
    var incomingAttention: [DirectMessage] { personalMessages.filter { $0.recipientId == me.id && $0.readAt == nil }.sorted { $0.id > $1.id } }
    var inboxChangeIDs: Set<String> {
        Set(incomingAttention.map { "message:\($0.id)" } + activeUserRequests.filter { $0.state == "open" }.map { "request:\($0.id)" })
    }
}
