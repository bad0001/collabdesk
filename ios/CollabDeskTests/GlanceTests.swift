import XCTest
@testable import CollabDesk

@MainActor final class GlanceTests: XCTestCase {
    func testRoleAwareCountsDoNotCallLeaderReviewUserReview() throws {
        var value = DemoData.make()
        let admin = value.glance(isDemo: true, syncedAt: nil)
        XCTAssertEqual(admin.authorizations, 1)
        XCTAssertEqual(admin.authorizationLabel, "待你授权")
        XCTAssertEqual(admin.reviewLabel, "待你终审")
        XCTAssertTrue(admin.isDemo)
        value.me = try XCTUnwrap(value.members.first { $0.role == "leader" })
        let leader = value.glance(isDemo: false, syncedAt: Date())
        XCTAssertEqual(leader.authorizations, 0)
        XCTAssertEqual(leader.reviewLabel, "待你验收")
        value.me = try XCTUnwrap(value.members.first { $0.id == "c" })
        let worker = value.glance(isDemo: false, syncedAt: Date())
        XCTAssertEqual(worker.authorizations, 1)
        XCTAssertEqual(worker.authorizationLabel, "等待授权")
    }
    func testPacketIsMinimalAndPreservesPreciseOrdering() throws {
        var snapshot = DemoData.make()
        snapshot.tasks[0].details = "SECRET_FULL_TASK_BODY"
        snapshot.tasks[0].jobURL = "https://example.com/?token=SECRET_URL"
        snapshot.me.quotaNote = "SECRET_QUOTA"
        let date = Date(timeIntervalSince1970: 1_790_000_000.123)
        let packet = snapshot.glance(isDemo: false, syncedAt: date, publishedAt: date)
        let data = try packet.encoded()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("SECRET"))
        XCTAssertEqual(try GlanceSnapshot.decode(data), packet)
        XCTAssertLessThanOrEqual(packet.tasks.count, 3)
        XCTAssertTrue(packet.isNewer(than: .empty(at: date.addingTimeInterval(-0.01))))
        XCTAssertFalse(packet.isNewer(than: .empty(at: date.addingTimeInterval(0.01))))
    }
    func testInvalidPacketsRejected() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: GlanceSnapshot.preview().encoded()) as? [String: Any])
        json["schemaVersion"] = 9
        XCTAssertThrowsError(try GlanceSnapshot.decode(JSONSerialization.data(withJSONObject: json)))
        json["schemaVersion"] = GlanceSnapshot.schema; json["inProgress"] = -1
        XCTAssertThrowsError(try GlanceSnapshot.decode(JSONSerialization.data(withJSONObject: json)))
        json["inProgress"] = 1; json["mode"] = "unavailable"
        XCTAssertThrowsError(try GlanceSnapshot.decode(JSONSerialization.data(withJSONObject: json)))
        XCTAssertThrowsError(try GlanceSnapshot.decode(Data(repeating: 65, count: 32_769)))
    }
    func testCacheReopensAndCorruptionDoesNotInventLiveData() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = GlanceCache(file: folder.appendingPathComponent("glance.json"))
        let value = GlanceSnapshot.preview(at: Date(timeIntervalSince1970: 1_790_000_000))
        try cache.write(value)
        XCTAssertEqual(cache.read(), value)
        try Data("invalid".utf8).write(to: cache.file)
        XCTAssertNil(cache.read())
    }
    func testUnavailablePacketClearsContentAndRejectsOlderPackets() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let old = GlanceSnapshot.preview(at: date)
        let cleared = GlanceSnapshot.empty(at: date.addingTimeInterval(1))
        XCTAssertFalse(old.isNewer(than: cleared))
        let reopened = try GlanceSnapshot.decode(cleared.encoded())
        XCTAssertTrue(reopened.tasks.isEmpty)
        XCTAssertEqual(reopened.authorizations, 0)
        XCTAssertFalse(reopened.hasData)
    }
    func testKnownRoutesOnly() throws {
        for route in [DeskRoute.authorizations, .alerts, .tasks, .task("TASK-000001"), .messages, .message(1), .message(Int.max)] {
            XCTAssertEqual(DeskRoute(url: try XCTUnwrap(route.url)), route)
        }
        for raw in ["https://example.com", "collabdesk://task/../../x", "collabdesk://task/OTHER-000001", "collabdesk://authorizations?token=x", "collabdesk://user:pass@task/TASK-000001", "collabdesk://task/TASK-000001/extra"] {
            XCTAssertNil(DeskRoute(url: try XCTUnwrap(URL(string: raw))))
        }
    }
    func testMessageRoutesRejectNoncanonicalOrCredentialBearingURLs() throws {
        XCTAssertNil(DeskRoute.message(0).url)
        XCTAssertNil(DeskRoute.message(-1).url)
        for raw in ["collabdesk://message/0", "collabdesk://message/-1", "collabdesk://message/+1",
                    "collabdesk://message/01", "collabdesk://message/1/", "collabdesk://message//1",
                    "collabdesk://message/%31", "collabdesk://message/1?x=1", "collabdesk://message/1#x",
                    "collabdesk://message:443/1", "collabdesk://messages:443", "collabdesk://messages/",
                    "collabdesk://user:pass@message/1", "collabdesk://%6dessage/1",
                    "collabdesk://message/999999999999999999999999999999999999"] {
            XCTAssertNil(DeskRoute(url: try XCTUnwrap(URL(string: raw))), raw)
        }
    }
    func testLiveFreshnessAndDemoDistinction() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let live = DemoData.make().glance(isDemo: false, syncedAt: date, publishedAt: date)
        XCTAssertFalse(live.isStale(at: date.addingTimeInterval(899)))
        XCTAssertTrue(live.isStale(at: date.addingTimeInterval(901)))
        XCTAssertFalse(GlanceSnapshot.preview().isStale(at: .distantFuture))
    }
}
