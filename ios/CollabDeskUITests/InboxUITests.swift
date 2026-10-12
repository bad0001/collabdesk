import XCTest

final class InboxUITests: XCTestCase {
    private func app() -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--skip-welcome", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]; app.launch(); return app
    }
    func testHomeIncomingMessageOpensReplyWithoutApproval() {
        let app = app()
        let incoming = app.buttons["home-message-1"]
        XCTAssertTrue(incoming.waitForExistence(timeout: 5)); capture(app, name: "inbox-home-demo"); incoming.tap()
        XCTAssertTrue(app.navigationBars["消息详情"].waitForExistence(timeout: 3))
        app.buttons["reply-message-detail"].tap()
        XCTAssertTrue(app.navigationBars["回复消息"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["messageRecipient"].label.contains("Leader"))
        XCTAssertFalse(app.buttons["批准"].exists)
        capture(app, name: "inbox-home-direct-reply-demo")
    }
    func testMessagesHaveOneCategoryRowAndOversightIsMenuOnly() {
        let app = app(); app.tabBars.buttons["消息"].tap()
        XCTAssertTrue(app.segmentedControls["messageCategory"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.segmentedControls["messageScope"].exists)
        XCTAssertTrue(app.buttons["conversation-1"].exists)
        capture(app, name: "inbox-messages-grouped-demo")
        app.buttons["消息更多操作"].tap()
        XCTAssertTrue(app.buttons["查看全部协作"].waitForExistence(timeout: 3))
        app.buttons["查看全部协作"].tap()
        app.buttons["conversation-1"].tap()
        XCTAssertTrue(app.navigationBars["Leader"].waitForExistence(timeout: 3))
        capture(app, name: "inbox-conversation-demo")
    }

    func testMultipleSMSCandidatesRequireSelectionAndDemoCannotUpload() {
        let app = app()
        let vault = app.buttons["openCodeVault"]
        for _ in 0..<4 { if vault.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(vault.exists); vault.tap()
        let practice = app.buttons["practiceSMSExtraction"]
        XCTAssertTrue(practice.waitForExistence(timeout: 3)); practice.tap()
        let input = app.textFields["smsImportText"]
        XCTAssertTrue(input.waitForExistence(timeout: 3)); input.tap(); input.typeText("OTP 123456\nverification code 987654")
        app.buttons["提取候选"].tap()
        XCTAssertTrue(app.buttons["123456"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["987654"].exists)
        XCTAssertTrue(app.staticTexts["发现多个候选，请手动选择；不会自动挑一个上传。"].exists)
        XCTAssertFalse(app.buttons["确认导入"].isEnabled)
        capture(app, name: "inbox-code-import-multiple-demo")
        app.buttons["123456"].tap()
        XCTAssertFalse(app.buttons["确认导入"].isEnabled)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

}
