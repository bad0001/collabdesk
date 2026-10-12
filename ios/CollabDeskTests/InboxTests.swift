import XCTest
@testable import CollabDesk

@MainActor final class InboxTests: XCTestCase {
    func testConversationsGroupByStableIdentityNotDisplayName() {
        var snapshot = DemoData.make()
        snapshot.members[1].name = "相同名字"
        snapshot.members[2].name = "相同名字"
        snapshot.messages = [
            DirectMessage(id: 1, senderId: "b", senderName: "相同名字", recipientId: "user", body: "一", createdAt: "2026-10-08T01:00:00Z"),
            DirectMessage(id: 2, senderId: "c", senderName: "相同名字", recipientId: "user", body: "二", createdAt: "2026-10-08T01:00:00Z"),
            DirectMessage(id: 3, senderId: "user", senderName: "我", recipientId: "b", body: "回复", createdAt: "2026-10-08T01:00:00Z")]
        let conversations = snapshot.conversations(includeAll: false)
        XCTAssertEqual(conversations.count, 2)
        XCTAssertEqual(conversations[0].messages.map(\.id), [3, 1])
        XCTAssertEqual(conversations[0].unread(for: "user"), 1)
        XCTAssertEqual(conversations[1].messages.map(\.id), [2])
    }
    func testWorkerOversightMenuDoesNotOpenAnotherConversation() throws {
        var snapshot = DemoData.make()
        snapshot.me = try XCTUnwrap(snapshot.members.first { $0.id == "b" })
        snapshot.messages = [DirectMessage(id: 1, senderId: "c", senderName: "C", recipientId: "leader", body: "内部", createdAt: "2026-10-08T01:00:00Z")]
        XCTAssertTrue(snapshot.conversations(includeAll: true).isEmpty)
    }
    func testViewingInboxDoesNotReadResolveOrApprove() {
        let snapshot = DemoData.make()
        let baseline = snapshot
        _ = snapshot.incomingAttention; _ = snapshot.inboxChangeIDs; _ = snapshot.conversations(includeAll: false)
        XCTAssertEqual(snapshot, baseline)
        XCTAssertTrue(snapshot.userRequests == nil)
    }
    func testOldSnapshotAcceptsAbsentUserRequests() throws {
        let encoded = try JSONEncoder().encode(DemoData.make())
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: encoded)
        XCTAssertNil(snapshot.userRequests)
        XCTAssertFalse(snapshot.incomingAttention.isEmpty)
    }
    func testExtractsExplicitNumericCode() {
        XCTAssertEqual(SMSCodeParser.candidates(in: "【网站】您的验证码是 123456，请勿泄露，有效 5 分钟。"), ["123456"])
        XCTAssertEqual(SMSCodeParser.candidates(in: "Your verification code is 456789"), ["456789"])
        XCTAssertEqual(SMSCodeParser.candidates(in: "123456 is your verification code."), ["123456"])
    }
    func testMultipleCandidatesStaySeparateForManualSelection() {
        XCTAssertEqual(SMSCodeParser.candidates(in: "验证码 123456\nOTP 987654\n验证码 123456"), ["123456", "987654"])
    }
    func testUnlabelledPhoneAmountAndDateAreNotCodes() {
        XCTAssertTrue(SMSCodeParser.candidates(in: "电话 13812345678，费用 1000 元，订单 123456").isEmpty)
        XCTAssertTrue(SMSCodeParser.candidates(in: "验证码发送至 13812345678").isEmpty)
        XCTAssertTrue(SMSCodeParser.candidates(in: "验证码交易金额 ￥1234").isEmpty)
        XCTAssertTrue(SMSCodeParser.candidates(in: "验证码交易金额 1234元").isEmpty)
        XCTAssertTrue(SMSCodeParser.candidates(in: "验证码金额 1234.56").isEmpty)
        XCTAssertTrue(SMSCodeParser.candidates(in: "验证码发送日期 2026-10-08").isEmpty)
    }
    func testCodeMatchingUsesExactTrimmedSourceAccountAndPurpose() {
        let code = VerificationCodeMetadata(id: "opaque-id", service: "A", accountLabel: "account", purpose: "login", state: "available", version: 1, receivedAt: "", expiresAt: "", createdAt: "")
        var request = CodeRequestMetadata(id: 1, taskId: "TASK-000001", requesterId: "b", requesterName: "B", service: " A ", accountLabel: "account", purpose: "login", state: "waiting", version: 1, createdAt: "", updatedAt: "")
        XCTAssertTrue(request.matches(code)); request.service = "a"; XCTAssertFalse(request.matches(code))
    }
    func testRequestRoutesAreCanonicalAndNeverCarryCodes() {
        XCTAssertEqual(DeskRoute(url: URL(string: "collabdesk://user-request/1")!), .userRequest(1))
        XCTAssertEqual(DeskRoute(url: URL(string: "collabdesk://user-requests")!), .userRequests)
        for bad in ["collabdesk://user-request/01", "collabdesk://user-request/-1", "collabdesk://user-request/1?code=123456", "collabdesk://user-request/1/x", "collabdesk://codes/123456", "collabdesk://user-requests/"] {
            XCTAssertNil(DeskRoute(url: URL(string: bad)!), bad)
        }
    }
    func testSensitiveImportDoesNotCreateDiskPendingRecordInDemo() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DeskStore(directory: folder, defaults: UserDefaults(suiteName: UUID().uuidString)!, forceDemo: true)
        do { _ = try await store.importVerificationCode(code: "123456", service: "test", account: "account", purpose: "login", expiresIn: 300, receivedAt: Date(), key: UUID().uuidString); XCTFail("演示不得导入") } catch {}
        XCTAssertNil(store.pendingWrite)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("pending.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("demo.json").path))
    }
}
