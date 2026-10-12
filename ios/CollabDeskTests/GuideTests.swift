import XCTest
@testable import CollabDesk

@MainActor
final class GuideTests: XCTestCase {
    func testSuggestedAddressDoesNotReplaceCustomOrigin() {
        XCTAssertEqual(ConnectionGuide.addressSuggestion(existing: ""), "https://api.example.com")
        XCTAssertEqual(ConnectionGuide.addressSuggestion(existing: " \n "), "https://api.example.com")
        XCTAssertEqual(ConnectionGuide.addressSuggestion(existing: "https://private.example:9443"), "https://private.example:9443")
        XCTAssertEqual(ConnectionGuide.addressSuggestion(existing: "http://127.0.0.1:8766"), "http://127.0.0.1:8766")
    }

    func testPublicGuidesShareOnlyOfficialHTTPSURLs() {
        XCTAssertEqual(PublicAIGuide.allCases.count, 3)
        for document in PublicAIGuide.allCases {
            XCTAssertEqual(document.url.scheme, "https")
            XCTAssertEqual(document.url.host, "api.example.com")
            XCTAssertEqual(document.url.path, "/guide/\(document.rawValue).md")
            XCTAssertNil(document.url.user)
            XCTAssertNil(document.url.password)
            XCTAssertNil(document.url.query)
            XCTAssertNil(document.url.fragment)
        }
    }

    func testAddressSuggestionLeavesDemoAndSavedConnectionUntouched() {
        let name = "GuideTest-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DeskStore(directory: folder, defaults: defaults, forceDemo: true)
        let snapshot = store.snapshot
        XCTAssertEqual(ConnectionGuide.addressSuggestion(existing: store.endpoint), ConnectionGuide.suggestedAddress)
        XCTAssertTrue(store.isDemo)
        XCTAssertEqual(store.endpoint, "")
        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertNil(defaults.object(forKey: "endpoint"))
        XCTAssertNil(store.pendingWrite)
    }

    func testFirstRunCompletionPersistsWithoutChangingWorkspaceSettings() {
        let name = "GuideTest-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("https://example.com", forKey: "endpoint")
        defaults.set(false, forKey: "demo")
        let guide = GuideState(defaults: defaults)
        XCTAssertTrue(guide.showWelcome)
        guide.finishWelcome(goTo: .practice)
        XCTAssertFalse(guide.showWelcome)
        XCTAssertFalse(GuideState(defaults: defaults).showWelcome)
        XCTAssertEqual(defaults.string(forKey: "endpoint"), "https://example.com")
        XCTAssertFalse(defaults.bool(forKey: "demo"))
        XCTAssertNil(guide.sheet, "Wait for welcome dismissal before opening practice")
        guide.performPendingNavigation()
        XCTAssertEqual(guide.sheet, .practice)
    }

    func testSkipAndManualReplayDoNotForceAnotherWelcomeNextLaunch() {
        let name = "GuideTest-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let guide = GuideState(defaults: defaults)
        guide.finishWelcome()
        guide.performPendingNavigation()
        XCTAssertEqual(guide.tab, .overview)
        guide.sheet = .help
        guide.leaveHelp(goTo: .welcome)
        guide.performPendingNavigation()
        XCTAssertTrue(guide.showWelcome)
        guide.finishWelcome()
        XCTAssertFalse(GuideState(defaults: defaults).showWelcome)
    }

    func testNavigationRequestsAreConsumedOnlyOnce() {
        let name = "GuideTest-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let guide = GuideState(defaults: defaults, skipAutomaticWelcome: true)
        XCTAssertFalse(defaults.bool(forKey: GuideState.welcomeKey), "UI test bypass must not mark the user's onboarding complete")
        guide.sheet = .help
        guide.leaveHelp(goTo: .newTask)
        XCTAssertFalse(guide.newTaskRequested)
        guide.performPendingNavigation()
        XCTAssertEqual(guide.tab, .tasks)
        XCTAssertTrue(guide.newTaskRequested)
        guide.newTaskRequested = false
        guide.performPendingNavigation()
        XCTAssertFalse(guide.newTaskRequested)
    }

    func testPracticeIsDisposableAndDoesNotMutateDemoRecords() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DeskStore(directory: folder, defaults: UserDefaults(suiteName: UUID().uuidString)!, forceDemo: true)
        let original = store.snapshot
        var stage = PracticeStage.assign
        XCTAssertEqual(stage.status, .pending)
        stage = stage.next; XCTAssertEqual(stage.status, .in_progress)
        stage = stage.next; XCTAssertEqual(stage.status, .awaiting_review)
        stage = stage.next; XCTAssertEqual(stage.status, .completed)
        XCTAssertEqual(stage.next, .done)
        XCTAssertEqual(store.snapshot, original)
        XCTAssertNil(store.pendingWrite)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("demo.json").path))
    }
}
