import XCTest

/// UI-only smoke checks, using disposable local fixtures and no credentials.
final class LayoutSmokeTests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-welcome", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func reveal(_ element: XCUIElement) {
        for _ in 0..<9 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "Expected control remains reachable: \(element)")
    }
    private func tapTab(_ name: String) {
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
    }
    private func back() { app.navigationBars.buttons.element(boundBy: 0).tap() }

    func testPhonePagesAndReadOnlyPreviews() throws {
        XCTAssertTrue(app.descendants(matching: .any)["overviewSummary"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["今天的协作"].exists)
        XCTAssertTrue(app.staticTexts["待你授权"].exists)
        shot("after-01-home")
        app.staticTexts["继续处理招聘账号里的申请步骤"].tap()
        let confirm = app.buttons["confirmExternalAuthorization"]
        reveal(confirm)
        XCTAssertTrue(confirm.isEnabled)
        shot("after-02-authorization")
        back()
        tapTab("任务")
        shot("after-03-tasks")
        let resume = app.staticTexts["为产品岗位整理一版简历"]
        reveal(resume); resume.tap()
        XCTAssertTrue(app.staticTexts["任务资料"].waitForExistence(timeout: 5))
        shot("after-04-task-detail")
        let update = app.buttons["recordProgress"]
        reveal(update); update.tap()
        XCTAssertTrue(app.descendants(matching: .any)["progressBody"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["saveProgress"].isEnabled)
        shot("after-05-progress-form")
        app.buttons["取消"].tap()
        back()
        tapTab("台账")
        shot("after-06-libraries")
        let library = app.staticTexts["资料追踪 · 演示"]
        XCTAssertTrue(library.waitForExistence(timeout: 5)); library.tap()
        XCTAssertTrue(app.staticTexts["一份待整理的资料"].waitForExistence(timeout: 5))
        shot("after-07-library-table")
        app.staticTexts["一份待整理的资料"].tap()
        XCTAssertTrue(app.staticTexts["原始内容"].waitForExistence(timeout: 5))
        shot("after-08-record")
        tapTab("消息")
        shot("after-09-messages")
        tapTab("设置")
        XCTAssertTrue(app.textFields["serverAddress"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["apiCredential"].exists)
        XCTAssertFalse(app.buttons["connectServer"].isEnabled)
        shot("after-10-settings")
        let access = app.buttons["membersAccess"]
        reveal(access); access.tap()
        XCTAssertTrue(app.buttons["addAIMember"].waitForExistence(timeout: 5))
        shot("after-11-members")
        back()
        let glance = app.buttons["glanceSettings"]
        reveal(glance); glance.tap()
        XCTAssertTrue(app.descendants(matching: .any)["smallWidgetPreview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["mediumWidgetPreview"].exists)
        shot("after-12-widget-previews")
    }

    func testLargestTextKeepsCriticalControlsReachable() throws {
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["overviewSummary"].waitForExistence(timeout: 5))
        shot("after-13-accessibility-home")
        let request = app.staticTexts["继续处理招聘账号里的申请步骤"]
        reveal(request); request.tap()
        let confirm = app.buttons["confirmExternalAuthorization"]
        reveal(confirm)
        XCTAssertTrue(confirm.isEnabled)
        shot("after-14-accessibility-authorization")
    }

    /// Run with the dedicated QA simulator appearance set to dark.
    func testSecondaryPagesAndDarkPreviews() throws {
        XCTAssertTrue(app.descendants(matching: .any)["overviewSummary"].waitForExistence(timeout: 5))
        shot("after-15-dark-home")
        app.buttons["reviewQueue"].tap()
        XCTAssertTrue(app.staticTexts["核对岗位清单与申请优先级"].waitForExistence(timeout: 5))
        shot("after-16-review-inbox")
        back()
        let alert = app.staticTexts["AI C 需要协助"]
        reveal(alert); alert.tap()
        XCTAssertTrue(app.buttons["问题已解决，恢复执行"].waitForExistence(timeout: 5))
        shot("after-17-alert-detail")
        back()
        tapTab("设置")
        let access = app.buttons["membersAccess"]
        reveal(access); access.tap()
        app.buttons["addAIMember"].tap()
        XCTAssertTrue(app.textFields["aiDisplayName"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["saveAIMember"].isEnabled)
        shot("after-18-add-member-form")
        app.buttons["关闭"].tap()
        back()
        let notifications = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "锁屏与系统提醒")).firstMatch
        reveal(notifications); notifications.tap()
        shot("after-19-notification-settings")
        back()
        let glance = app.buttons["glanceSettings"]
        reveal(glance); glance.tap()
        XCTAssertTrue(app.descendants(matching: .any)["smallWidgetPreview"].waitForExistence(timeout: 5))
        shot("after-20-dark-widget-previews")
    }
}
