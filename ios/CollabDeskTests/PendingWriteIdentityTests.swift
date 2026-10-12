import XCTest
@testable import CollabDesk

@MainActor final class PendingWriteIdentityTests: XCTestCase {
    private func request(workspace: String? = "workspace-a") -> PendingWrite {
        PendingWrite(endpoint: "https://api.example.com", memberId: "user", workspaceId: workspace,
                     path: "/v1/tasks", key: "fixture-key", body: Data("{}".utf8))
    }

    func testPendingWriteBindsOriginMemberAndWorkspace() {
        let pending = request()
        XCTAssertTrue(pending.matches(endpoint: pending.endpoint, memberId: "user", workspaceId: "workspace-a"))
        XCTAssertFalse(pending.matches(endpoint: pending.endpoint, memberId: "leader", workspaceId: "workspace-a"))
        XCTAssertFalse(pending.matches(endpoint: pending.endpoint, memberId: "user", workspaceId: "workspace-b"))
        XCTAssertFalse(pending.matches(endpoint: "https://other.example", memberId: "user", workspaceId: "workspace-a"))
    }

    func testLegacyPendingDecodesButNeverMatchesForReplay() throws {
        let data = Data(#"{"endpoint":"https://api.example.com","memberId":"user","path":"/v1/tasks","key":"fixture-key","body":"e30="}"#.utf8)
        let pending = try JSONDecoder().decode(PendingWrite.self, from: data)
        XCTAssertNil(pending.workspaceId)
        XCTAssertFalse(pending.matches(endpoint: pending.endpoint, memberId: "user", workspaceId: "workspace-a"))
    }

    func testManualCheckArchivesWithoutSendingOrChangingTasks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DeskStore(directory: folder, defaults: UserDefaults(suiteName: UUID().uuidString)!, forceDemo: true)
        let pending = request()
        try JSONEncoder().encode(pending).write(to: folder.appendingPathComponent("pending.json"))
        store.pendingWrite = pending
        let before = store.snapshot
        XCTAssertTrue(store.confirmPendingManuallyChecked())
        XCTAssertNil(store.pendingWrite)
        XCTAssertEqual(store.snapshot, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("pending.json").path))
        let archives = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("pending-checked-") }
        XCTAssertEqual(archives.count, 1)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: archives[0])) as? [String: Any])
        let saved = try XCTUnwrap(value["request"] as? [String: Any])
        XCTAssertEqual(saved["workspaceId"] as? String, "workspace-a")
        XCTAssertEqual(saved["key"] as? String, pending.key)
    }

    func testArchiveFailureRetainsPending() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DeskStore(directory: folder, defaults: UserDefaults(suiteName: UUID().uuidString)!, forceDemo: true)
        store.pendingWrite = request()
        // Missing original file must never silently clear the queued request.
        XCTAssertFalse(store.confirmPendingManuallyChecked())
        XCTAssertNotNil(store.pendingWrite)
    }
}
