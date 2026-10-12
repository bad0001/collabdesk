import XCTest
import UserNotifications
@testable import CollabDesk

@MainActor final class MessageTests: XCTestCase {
    private func fixture() -> Snapshot {
        var value = DemoData.make()
        let stamp = "2026-10-08T01:00:00Z"
        value.messages = [
            DirectMessage(id: 1, senderId: "b", senderName: "AI B", recipientId: "user", body: "给用户", createdAt: stamp),
            DirectMessage(id: 2, senderId: "user", senderName: "我", recipientId: "c", body: "给 Worker", createdAt: stamp),
            DirectMessage(id: 3, senderId: "b", senderName: "AI B", recipientId: "leader", body: "内部汇报", createdAt: stamp),
            DirectMessage(id: 4, senderId: "c", senderName: "AI C", recipientId: "leader", body: "另一条内部汇报", createdAt: stamp),
            DirectMessage(id: 5, senderId: "leader", senderName: "Leader", recipientId: "user", body: "已读来信", createdAt: stamp, readAt: stamp)
        ]
        return value
    }
    func testPersonalMessagesExcludeOversightOnlyConversation() {
        let snapshot = fixture()
        XCTAssertEqual(snapshot.visibleMessages(includeAll: false).map(\.id), [5, 2, 1])
        XCTAssertEqual(snapshot.visibleMessages(includeAll: true).map(\.id), [5, 4, 3, 2, 1])
        XCTAssertEqual(snapshot.unreadPersonalMessageCount, 1)
    }
    func testWorkerAllSelectorDoesNotExpandVisibleScope() throws {
        var snapshot = fixture()
        snapshot.me = try XCTUnwrap(snapshot.members.first { $0.id == "b" })
        XCTAssertEqual(snapshot.visibleMessages(includeAll: true).map(\.id), [3, 1])
        XCTAssertEqual(snapshot.unreadPersonalMessageCount, 0)
        XCTAssertEqual(Set(snapshot.messageRecipients.map(\.id)), Set(["leader", "user"]))
    }
    func testReplyOnlyTargetsActualSenderOfMyIncomingMessage() throws {
        var snapshot = fixture()
        let incoming = try XCTUnwrap(snapshot.messages?.first { $0.id == 1 })
        XCTAssertEqual(snapshot.replyRecipient(for: incoming), "b")
        XCTAssertNil(snapshot.replyRecipient(for: try XCTUnwrap(snapshot.messages?.first { $0.id == 2 })))
        XCTAssertNil(snapshot.replyRecipient(for: try XCTUnwrap(snapshot.messages?.first { $0.id == 3 })))
        snapshot.members.removeAll { $0.id == "b" }
        XCTAssertNil(snapshot.replyRecipient(for: incoming))
    }
    func testReplyPreselectionDoesNotFallBackToAnotherMember() {
        let snapshot = fixture()
        XCTAssertEqual(snapshot.preferredMessageRecipient("c"), "c")
        XCTAssertEqual(snapshot.preferredMessageRecipient(nil), "leader")
        XCTAssertEqual(snapshot.preferredMessageRecipient("missing"), "")
        XCTAssertEqual(snapshot.preferredMessageRecipient("user"), "")
    }
    func testLookingAtOrPreparingReplyDoesNotMarkMessageRead() throws {
        let snapshot = fixture()
        let original = snapshot
        let message = try XCTUnwrap(snapshot.messages?.first { $0.id == 1 })
        _ = snapshot.replyRecipient(for: message)
        _ = snapshot.preferredMessageRecipient(message.senderId)
        _ = snapshot.visibleMessages(includeAll: false)
        XCTAssertEqual(snapshot, original)
        XCTAssertNil(message.readAt)
    }
    func testPushStatusAcceptsOldServerWithoutConfigurationProblem() throws {
        let old = Data(#"{"configured":false,"registeredDevices":1,"queued":0,"acceptedByAPNs":0,"failed":0,"deliveryNote":"尚未发送"}"#.utf8)
        let decoded = try JSONDecoder().decode(PushStatus.self, from: old)
        XCTAssertFalse(decoded.configured)
        XCTAssertNil(decoded.configProblem)
        var configured = decoded
        configured.configProblem = "待配置 Apple 推送密钥"
        XCTAssertEqual(try JSONDecoder().decode(PushStatus.self, from: JSONEncoder().encode(configured)), configured)
    }
    func testPermissionLabelsDoNotConfuseQuietDeliveryWithFullPermission() {
        XCTAssertEqual(PushPermissionState(.notDetermined), .notAsked)
        XCTAssertEqual(PushPermissionState(.denied), .denied)
        XCTAssertFalse(PushPermissionState(.denied).allowsRegistration)
        XCTAssertTrue(PushPermissionState(.authorized).allowsRegistration)
        XCTAssertTrue(PushPermissionState(.provisional).allowsRegistration)
        XCTAssertTrue(PushPermissionState(.ephemeral).allowsRegistration)
        XCTAssertNotEqual(PushPermissionState(.provisional).label, PushPermissionState(.authorized).label)
    }
    func testDisablingInstallationDoesNotRequireFreshDeviceToken() throws {
        let value = try XCTUnwrap(DeskStore.pushDevicePayload(installationID: "fixture_installation", token: nil, environment: "sandbox", enabled: false))
        XCTAssertEqual(value["installationId"] as? String, "fixture_installation")
        XCTAssertEqual(value["enabled"] as? Bool, false)
        XCTAssertNil(value["token"])
        XCTAssertNil(value["environment"])
        XCTAssertNil(DeskStore.pushDevicePayload(installationID: "fixture_installation", token: nil, environment: "sandbox", enabled: true))
        XCTAssertEqual(DeskStore.pushDevicePayload(installationID: "fixture_installation", token: "fixture", environment: "sandbox", enabled: true)?["token"] as? String, "fixture")
    }

}
