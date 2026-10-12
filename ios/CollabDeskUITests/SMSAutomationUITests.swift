import XCTest

final class SMSAutomationUITests: XCTestCase {
    func testAutomaticSettingsAreCompactAndDemoDoesNotEnableUpload() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-welcome", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.tabBars.buttons["设置"].tap()
        let entry = app.buttons["短信自动入库"]
        for _ in 0..<5 { if entry.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 3)); entry.tap()
        XCTAssertTrue(app.navigationBars["短信自动入库"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["enableSMSAutomation"].exists)
        XCTAssertEqual(app.textFields.count, 0)
        XCTAssertEqual(app.secureTextFields.count, 0)
        XCTAssertTrue(app.staticTexts["未启用"].exists)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "sms-auto-settings-demo"; image.lifetime = .keepAlways; add(image)
    }
}
