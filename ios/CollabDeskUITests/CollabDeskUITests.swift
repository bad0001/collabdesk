import XCTest

final class CollabDeskUITests: XCTestCase {
    var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-welcome", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }


    /// Optional integration input is supplied at test time, never bundled.
    /// Only a deliberately disposable loopback fixture is accepted.
    private func disposableQAConnection() throws -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["COLLABDESK_QA_URL"],
              let url = URLComponents(string: address),
              url.scheme == "http", ["localhost", "127.0.0.1", "[::1]"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              let admin = environment["COLLABDESK_QA_ADMIN_TOKEN"], !admin.isEmpty,
              let leader = environment["COLLABDESK_QA_LEADER_TOKEN"], !leader.isEmpty else {
            throw XCTSkip("Set disposable loopback COLLABDESK_QA_* environment values to run live integration checks")
        }
        return ["url": address, "token": admin, "leaderToken": leader]
    }

    private func keepShot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testGlancePreviewsAndAuthorizationEntry() throws {
        app.tabBars.buttons["设置"].tap()
        app.buttons["glanceSettings"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["smallWidgetPreview"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.descendants(matching: .any)["mediumWidgetPreview"].exists)
        XCTAssertTrue(app.staticTexts["待你终审"].exists)
        keepShot("glance-01-widget-previews")
        let button = app.buttons["glanceOpenAuthorizations"]
        for _ in 0..<6 { if button.isHittable { break }; app.swipeUp() }
        button.tap()
        XCTAssertTrue(app.staticTexts["继续处理招聘账号里的申请步骤"].waitForExistence(timeout: 4))
        keepShot("glance-02-authorizations-deep-link")
        app.buttons["关闭"].tap()
    }

    func testWelcomeToPracticeDoesNotCreateTask() throws {
        app.terminate()
        app.launchArguments.removeAll { $0 == "--skip-welcome" }
        app.launch()
        XCTAssertTrue(app.staticTexts["你交办，AI 协作"].waitForExistence(timeout: 5))
        keepShot("guide-01-welcome")
        app.buttons["welcomeNext"].tap()
        XCTAssertTrue(app.staticTexts["只记住这三个地方"].exists)
        app.buttons["welcomeNext"].tap()
        XCTAssertTrue(app.staticTexts["先用示例熟悉一下"].exists)
        keepShot("guide-02-demo-boundary")
        app.buttons["welcomeNext"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "practiceNotice").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Leader 已安排负责人"].exists)
        app.buttons["practiceNext"].tap()
        XCTAssertTrue(app.staticTexts["进行中"].exists)
        app.buttons["practiceNext"].tap()
        XCTAssertTrue(app.staticTexts["待验收"].exists)
        keepShot("guide-03-practice-review")
        app.buttons["practiceNext"].tap()
        XCTAssertTrue(app.staticTexts["已完成"].exists)
        app.buttons["closePractice"].tap()
        XCTAssertTrue(app.staticTexts["今天的协作"].waitForExistence(timeout: 3))
        app.tabBars.buttons["任务"].tap()
        XCTAssertFalse(app.staticTexts["为一个岗位整理简历"].exists)
    }

    func testHelpOpensCreateFormWithoutSaving() throws {
        app.buttons["openHelp"].tap()
        XCTAssertTrue(app.staticTexts["先找 Leader，不用自己派单"].waitForExistence(timeout: 3))
        keepShot("guide-04-help")
        let create = app.buttons["manualTaskFromHelp"]
        for _ in 0..<8 { if create.isHittable { break }; app.swipeUp() }
        create.tap()
        XCTAssertTrue(app.descendants(matching: .any)["taskTitle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["现在创建的是本地演示任务，不会发给真实 AI。"].exists)
        XCTAssertFalse(app.buttons["createTaskConfirm"].isEnabled)
        keepShot("guide-05-guided-create")
        app.buttons["取消"].tap()
        app.tabBars.buttons["设置"].tap()
        app.buttons["settingsWelcome"].tap()
        XCTAssertTrue(app.staticTexts["你交办，AI 协作"].waitForExistence(timeout: 3))
        app.buttons["skipWelcome"].tap()
        XCTAssertTrue(app.buttons["settingsHelp"].waitForExistence(timeout: 3))
    }

    func testWelcomeAtLargestTextRemainsOperable() throws {
        app.terminate()
        app.launchArguments.removeAll { $0 == "--skip-welcome" }
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.staticTexts["你交办，AI 协作"].waitForExistence(timeout: 5))
        keepShot("guide-06-large-text")
        XCTAssertTrue(app.buttons["welcomeNext"].isHittable)
        app.buttons["welcomeNext"].tap()
        app.buttons["welcomeNext"].tap()
        XCTAssertTrue(app.buttons["welcomeNext"].isHittable)
        app.buttons["skipWelcome"].tap()
        XCTAssertTrue(app.staticTexts["今天的协作"].waitForExistence(timeout: 3))
    }

    func testDemoCardAuthorizationAndAddNamedAI() throws {
        app.tabBars.buttons["设置"].tap()
        app.buttons["authorizationCenter"].tap()
        XCTAssertTrue(app.staticTexts["继续处理招聘账号里的申请步骤"].waitForExistence(timeout: 3))
        app.staticTexts["继续处理招聘账号里的申请步骤"].tap()
        XCTAssertTrue(app.buttons["confirmExternalAuthorization"].waitForExistence(timeout: 3))
        keepShot("authorization-01-user-card")
        app.buttons["confirmExternalAuthorization"].tap()
        let note = app.textFields["authorizationDecisionNote"]
        XCTAssertTrue(note.waitForExistence(timeout: 3)); note.tap(); note.typeText("演示：已经在对应账号完成")
        app.buttons["saveAuthorizationDecision"].tap()
        XCTAssertTrue(app.staticTexts["用户已确认外部授权"].waitForExistence(timeout: 4))
        app.tabBars.buttons["设置"].tap()
        app.buttons["membersAccess"].tap()
        app.buttons["addAIMember"].tap()
        let name = app.textFields["aiDisplayName"]
        XCTAssertTrue(name.waitForExistence(timeout: 3)); name.tap(); name.typeText("我的岗位搭档")
        app.buttons["saveAIMember"].tap()
        XCTAssertTrue(app.staticTexts["演示成员已添加。真实连接需独立服务与成员凭据。"].waitForExistence(timeout: 4))
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["我的岗位搭档"].waitForExistence(timeout: 3))
        keepShot("authorization-02-named-member")
    }

    func testLiveMemberRegistrationShowsCredentialOnlyOnce() throws {
        let connection = try disposableQAConnection()
        app.tabBars.buttons["设置"].tap()
        app.textFields["serverAddress"].tap(); app.textFields["serverAddress"].typeText(try XCTUnwrap(connection["url"]) + "\n")
        app.secureTextFields["apiCredential"].typeText(try XCTUnwrap(connection["token"]))
        app.buttons["完成输入"].tap(); app.buttons["connectServer"].tap()
        XCTAssertTrue(app.staticTexts["已连接服务"].waitForExistence(timeout: 15))
        app.buttons["membersAccess"].tap()
        app.buttons["addAIMember"].tap()
        let name = app.textFields["aiDisplayName"]
        XCTAssertTrue(name.waitForExistence(timeout: 3)); name.tap(); name.typeText("联调岗位搭档")
        app.buttons["saveAIMember"].tap()
        XCTAssertTrue(app.staticTexts["oneTimeMemberCredential"].waitForExistence(timeout: 10))
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["联调岗位搭档"].waitForExistence(timeout: 5))
    }

    func testLiveUserCardAndLeaderNormalDecision() throws {
        let connection = try disposableQAConnection()
        app.tabBars.buttons["设置"].tap()
        app.textFields["serverAddress"].tap(); app.textFields["serverAddress"].typeText(try XCTUnwrap(connection["url"]) + "\n")
        app.secureTextFields["apiCredential"].typeText(try XCTUnwrap(connection["token"]))
        app.buttons["完成输入"].tap(); app.buttons["connectServer"].tap()
        XCTAssertTrue(app.staticTexts["已连接服务"].waitForExistence(timeout: 15))
        app.tabBars.buttons["总览"].tap()
        XCTAssertTrue(app.staticTexts["需要你亲自授权"].waitForExistence(timeout: 4))
        app.staticTexts["需要账号授权卡"].tap()
        XCTAssertTrue(app.buttons["confirmExternalAuthorization"].waitForExistence(timeout: 3))
        app.buttons["confirmExternalAuthorization"].tap()
        let cardNote = app.textFields["authorizationDecisionNote"]
        cardNote.tap(); cardNote.typeText("本地测试：已在外部操作")
        app.buttons["saveAuthorizationDecision"].tap()
        XCTAssertTrue(app.staticTexts["用户已确认外部授权"].waitForExistence(timeout: 5))
        // A separate Leader session verifies the normal route without sharing the user's credential.
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-welcome", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.tabBars.buttons["设置"].tap()
        app.textFields["serverAddress"].tap(); app.textFields["serverAddress"].typeText(try XCTUnwrap(connection["url"]) + "\n")
        app.secureTextFields["apiCredential"].typeText(try XCTUnwrap(connection["leaderToken"]))
        app.buttons["完成输入"].tap(); app.buttons["connectServer"].tap()
        XCTAssertTrue(app.staticTexts["已连接服务"].waitForExistence(timeout: 15))
        app.tabBars.buttons["总览"].tap()
        XCTAssertTrue(app.staticTexts["等待 Leader 审批"].waitForExistence(timeout: 4))
        app.staticTexts["继续处理普通任务"].tap()
        XCTAssertTrue(app.buttons["approveNormalAuthorization"].waitForExistence(timeout: 3))
        app.buttons["approveNormalAuthorization"].tap()
        let normalNote = app.textFields["authorizationDecisionNote"]
        normalNote.tap(); normalNote.typeText("本地测试：同意此范围")
        app.buttons["saveAuthorizationDecision"].tap()
        XCTAssertTrue(app.staticTexts["已批准"].waitForExistence(timeout: 5))
    }

    func testPracticeInConnectedWorkspaceIsReadOnly() async throws {
        guard let file = Bundle(for: Self.self).url(forResource: "qa-connection", withExtension: "json") else {
            throw XCTSkip("Run the disposable loopback QA server for this test.")
        }
        let connection = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
        let address = try XCTUnwrap(connection["url"])
        let token = try XCTUnwrap(connection["token"])
        func records() async throws -> Data {
            var request = URLRequest(url: try XCTUnwrap(URL(string: address + "/v1/snapshot")))
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try JSONSerialization.data(withJSONObject: ["tasks": value["tasks"]!, "events": value["events"]!, "messages": value["messages"]!], options: .sortedKeys)
        }
        let before = try await records()
        app.tabBars.buttons["设置"].tap()
        app.textFields["serverAddress"].tap(); app.textFields["serverAddress"].typeText(address + "\n")
        app.secureTextFields["apiCredential"].typeText(token)
        app.buttons["完成输入"].tap()
        app.buttons["connectServer"].tap()
        XCTAssertTrue(app.staticTexts["已连接服务"].waitForExistence(timeout: 15))
        app.buttons["settingsHelp"].tap()
        XCTAssertTrue(app.buttons["startPractice"].waitForExistence(timeout: 3))
        app.buttons["startPractice"].tap()
        XCTAssertTrue(app.buttons["practiceNext"].waitForExistence(timeout: 5))
        for _ in 0..<3 { app.buttons["practiceNext"].tap() }
        app.buttons["closePractice"].tap()
        let after = try await records()
        XCTAssertEqual(before, after, "Practice must not save sample tasks, messages or progress to a connected workspace")
        XCTAssertTrue(app.staticTexts["已连接服务"].waitForExistence(timeout: 3))
    }

    func testOverviewAndCreateTaskFlow() throws {
        XCTAssertTrue(app.staticTexts["今天的协作"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["本地演示 · 示例数据，不会上传"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "01-overview"; shot.lifetime = .keepAlways; add(shot)
        app.swipeUp()
        let teamShot = XCTAttachment(screenshot: app.screenshot()); teamShot.name = "02-members"; teamShot.lifetime = .keepAlways; add(teamShot)
        app.tabBars.buttons["任务"].tap()
        app.buttons["任务更多操作"].tap(); app.buttons["手动补录任务"].tap()
        let field = app.descendants(matching: .any).matching(identifier: "taskTitle").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3)); field.tap(); field.typeText("UI Test Task")
        app.buttons["createTaskConfirm"].tap()
        XCTAssertTrue(app.staticTexts["UI Test Task"].waitForExistence(timeout: 5))
        app.staticTexts["UI Test Task"].tap()
        app.buttons["更新"].tap()
        let report = app.descendants(matching: .any).matching(identifier: "progressBody").firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 3)); report.tap(); report.typeText("UI progress recorded")
        app.buttons["saveProgress"].tap()
        XCTAssertTrue(app.staticTexts["进行中"].waitForExistence(timeout: 5))
    }

    func testReviewQueueAndMemberDisclosure() throws {
        app.buttons["reviewQueue"].tap()
        XCTAssertTrue(app.staticTexts["核对岗位清单与申请优先级"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["补充网申需要的项目经历"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        for _ in 0..<4 {
            if app.buttons["quietMembers"].isHittable { break }
            app.swipeUp()
        }
        let disclosure = app.buttons["quietMembers"]
        XCTAssertTrue(disclosure.exists)
        disclosure.tap()
        XCTAssertTrue(app.staticTexts["Leader"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "03-folding"; shot.lifetime = .keepAlways; add(shot)
    }

    func testLargeTextLayout() throws {
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.staticTexts["今天的协作"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "04-accessibility"; shot.lifetime = .keepAlways; add(shot)
        for _ in 0..<5 {
            if app.buttons["reviewQueue"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["reviewQueue"].isHittable)
        app.buttons["reviewQueue"].tap()
        XCTAssertTrue(app.staticTexts["核对岗位清单与申请优先级"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["TASK-000004"].exists)
        let detail = XCTAttachment(screenshot: app.screenshot()); detail.name = "05-large-task"; detail.lifetime = .keepAlways; add(detail)
    }

    func testAlertReadDoesNotCloseAlert() throws {
        app.staticTexts["AI C 需要协助"].tap()
        app.buttons["标记已读"].tap()
        let note = app.descendants(matching: .any).matching(identifier: "alertNote").firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 3)); note.tap(); note.typeText("Read, awaiting materials")
        app.buttons["确认"].tap()
        XCTAssertTrue(app.staticTexts["已读待处理"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["问题已解决，恢复执行"].exists)
    }

    func testTabsAndHTTPSSettings() throws {
        app.tabBars.buttons["消息"].tap()
        XCTAssertTrue(app.staticTexts["只分享这条消息，不自动开放其他成员的任务"].waitForExistence(timeout: 3))
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.textFields["serverAddress"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.secureTextFields["apiCredential"].exists)
        XCTAssertFalse(app.buttons["connectServer"].isEnabled)
    }

    func testLiveLocalAPIConnectionAndWrite() throws {
        guard let file = Bundle(for: Self.self).url(forResource: "qa-connection", withExtension: "json") else {
            throw XCTSkip("Start scripts/qa_server.py before generating the Xcode project for live API integration.")
        }
        let connection = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
        app.tabBars.buttons["设置"].tap()
        app.textFields["serverAddress"].tap()
        app.textFields["serverAddress"].typeText(try XCTUnwrap(connection["url"]) + "\n")
        app.secureTextFields["apiCredential"].typeText(try XCTUnwrap(connection["token"]))
        app.buttons["完成输入"].tap()
        app.buttons["connectServer"].tap()
        let connected = app.staticTexts["已连接服务"].waitForExistence(timeout: 15)
        XCTAssertTrue(connected, app.staticTexts["connectionError"].exists ? app.staticTexts["connectionError"].label : "No connection confirmation")
        app.tabBars.buttons["任务"].tap()
        XCTAssertTrue(app.staticTexts["实时接口联调任务"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["补充网申需要的项目经历"].exists)
        app.buttons["任务更多操作"].tap(); app.buttons["手动补录任务"].tap()
        let title = app.descendants(matching: .any).matching(identifier: "taskTitle").firstMatch
        title.tap(); title.typeText("Live API Created Task")
        app.buttons["createTaskConfirm"].tap()
        XCTAssertTrue(app.staticTexts["Live API Created Task"].waitForExistence(timeout: 10))
    }
}
