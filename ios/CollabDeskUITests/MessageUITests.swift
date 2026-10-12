import XCTest

final class MessageUITests: XCTestCase {
    func testIncomingReplyKeepsRecipientAndAppearsInPersonalMessages() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-welcome", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.tabBars.buttons["消息"].tap()
        let reply = app.buttons["reply-message-1"]
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        reply.tap()
        XCTAssertTrue(app.navigationBars["回复消息"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["messageRecipient"].label.contains("Leader"))
        let input = app.textFields["messageBody"]
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        input.tap(); input.typeText("REPLY_LOCAL_FIXTURE")
        let send = app.buttons["发送"]
        XCTAssertTrue(send.isEnabled); send.tap()
        XCTAssertTrue(app.staticTexts["REPLY_LOCAL_FIXTURE"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "personal-message-reply-fixture"; shot.lifetime = .keepAlways
        add(shot)
    }
}
