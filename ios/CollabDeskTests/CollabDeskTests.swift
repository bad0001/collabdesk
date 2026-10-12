import XCTest
@testable import CollabDesk

@MainActor
final class CollabDeskTests: XCTestCase {
    func testDemoRoundTripAndSeparation() throws {
        let snapshot = DemoData.make()
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(snapshot, decoded)
        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(decoded.activeAlerts.count, 2)
        XCTAssertTrue(decoded.tasks.contains { $0.status == .awaiting_review })
        XCTAssertTrue(decoded.tasks.allSatisfy { $0.details.contains("演示") })
    }

    func testBackendContractFixture() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "api-snapshot", withExtension: "json"))
        let value = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        XCTAssertEqual(value.schemaVersion, 2)
        XCTAssertEqual(value.activeAlerts.first?.severity, "red")
        XCTAssertEqual(value.dashboard?.first?.redAlerts, 1)
        XCTAssertEqual(value.tasks.first?.blockedReason, "缺少岗位材料，需要 Leader 补充")
        XCTAssertTrue(value.me.privileged)
    }

    func testEndpointRules() throws {
        XCTAssertEqual(try DeskStore.validEndpoint("https://example.com").scheme, "https")
        XCTAssertEqual(try DeskStore.validEndpoint("http://127.0.0.1:8766").host, "127.0.0.1")
        for bad in ["http://example.com", "https://user:password@example.com", "https://example.com/path", "https://example.com?token=x", "file:///tmp/a"] {
            XCTAssertThrowsError(try DeskStore.validEndpoint(bad))
        }
    }

    func testSourceLabelsAreSeparateFromActor() {
        let task = DemoData.make().tasks.first { $0.source == .user }!
        XCTAssertEqual(task.source.label, "用户指派")
        XCTAssertEqual(task.createdBy, "b")
        XCTAssertEqual(TaskStatus.awaiting_review.label, "待验收")
    }

    func testDemoCreatePersistsAndConflictIsDetected() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = DeskStore(directory: folder, defaults: defaults, forceDemo: true)
        let created = await store.create(title: "独立测试任务", owner: "b", source: .user, category: .resume, priority: "normal", details: "演示", acceptance: "成果链接", jobURL: "", requiresReview: true)
        XCTAssertTrue(created)
        let task = try XCTUnwrap(store.snapshot.tasks.first)
        XCTAssertTrue(task.needsReview)
        XCTAssertEqual(task.id, "TASK-000005")
        let first = await store.update(task: task, kind: "accepted", body: "接单", status: .in_progress, owner: "b", resultURL: "")
        XCTAssertTrue(first)
        let stale = await store.update(task: task, kind: "progress", body: "旧版本", status: .in_progress, owner: "b", resultURL: "")
        XCTAssertFalse(stale)
        let persisted = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: folder.appendingPathComponent("demo.json")))
        XCTAssertEqual(persisted.tasks.first?.status, .in_progress)
    }

    func testDemoAcknowledgeIsNotResolved() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DeskStore(directory: folder, defaults: UserDefaults(suiteName: UUID().uuidString)!, forceDemo: true)
        let alert = try XCTUnwrap(store.snapshot.activeAlerts.first)
        let ok = await store.alertAction(alert, action: "acknowledge", note: "已看，待补充")
        XCTAssertTrue(ok)
        XCTAssertEqual(store.snapshot.activeAlerts.first?.state, "acknowledged")
        XCTAssertEqual(store.snapshot.activeAlerts.count, 2)
    }

    func testAuthorizationCardNeedsUserAndDemoPreservesHistory() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DeskStore(directory: folder, defaults: UserDefaults(suiteName: UUID().uuidString)!, forceDemo: true)
        let card = try XCTUnwrap(store.snapshot.authorizations?.first)
        XCTAssertEqual(card.state, "awaiting_user")
        let earlier = store.snapshot.authorizationEvents?.count
        let wrongAction = await store.decideAuthorization(card, action: "approved", note: "错误类型")
        XCTAssertFalse(wrongAction)
        let confirmed = await store.decideAuthorization(card, action: "confirmed_external", note: "已在外部账号完成")
        XCTAssertTrue(confirmed)
        XCTAssertEqual(store.snapshot.authorizations?.first?.decidedBy, "user")
        XCTAssertEqual(store.snapshot.authorizations?.first?.state, "confirmed_external")
        XCTAssertEqual(store.snapshot.authorizationEvents?.count, (earlier ?? 0) + 1)
        let saved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: folder.appendingPathComponent("demo.json")))
        XCTAssertEqual(saved.authorizations?.first?.state, "confirmed_external")
    }

    func testWorkerAuthorizationBlocksDemoUntilLeaderApproves() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DeskStore(directory: folder, defaults: UserDefaults(suiteName: UUID().uuidString)!, forceDemo: true)
        let worker = try XCTUnwrap(store.snapshot.members.first { $0.id == "b" })
        store.snapshot.me = worker
        let task = try XCTUnwrap(store.snapshot.tasks.first { $0.id == "TASK-000002" })
        let asked = await store.requestAuthorization(task: task, kind: "normal", subject: "使用资料", reason: "需要确认范围", accountLabel: "")
        XCTAssertTrue(asked)
        let blocked = await store.update(task: task, kind: "progress", body: "越过审批", status: .in_progress, owner: "b", resultURL: "")
        XCTAssertFalse(blocked)
        let request = try XCTUnwrap(store.snapshot.authorizations?.first)
        store.snapshot.me = try XCTUnwrap(store.snapshot.members.first { $0.id == "leader" })
        let approved = await store.decideAuthorization(request, action: "approved", note: "批准使用这份资料")
        XCTAssertTrue(approved)
        store.snapshot.me = worker
        let continued = await store.update(task: task, kind: "progress", body: "已核对资料", status: .in_progress, owner: "b", resultURL: "")
        XCTAssertTrue(continued)
    }

    func testUserCanAddAndRenameDemoAIWithoutChangingIdentity() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DeskStore(directory: folder, defaults: UserDefaults(suiteName: UUID().uuidString)!, forceDemo: true)
        let added = await store.registerMember(name: "岗位搭档", role: "worker")
        XCTAssertTrue(added)
        let member = try XCTUnwrap(store.snapshot.members.first { $0.name == "岗位搭档" })
        XCTAssertNil(store.issuedCredential)
        let renamed = await store.renameMember(member, name: "新的岗位搭档")
        XCTAssertTrue(renamed)
        XCTAssertEqual(store.snapshot.members.first { $0.id == member.id }?.name, "新的岗位搭档")
        XCTAssertEqual(store.snapshot.members.first { $0.id == member.id }?.id, member.id)
    }
}
