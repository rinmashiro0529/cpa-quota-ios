import XCTest
import UIKit
import notify

/// Runs against the real app UI and production parsers using Debug-only local
/// transport fixtures. Screenshots accompany assertions; they are not treated
/// as proof of a pass by themselves.
final class CPAQuotaAppUITests: XCTestCase {
    // WebKit's accessibility tree can take nearly 15 seconds on a hosted
    // simulator, even after the preview itself appears.
    private let htmlPreviewContentTimeout: TimeInterval = 30

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLoginValidatesHTTPSAndRejectsManagement401BeforeConnecting() {
        let app = launch(connected: false)
        defer { app.terminate() }
        let address = app.textFields["connection.server"]
        let key = app.secureTextFields["connection.key"]
        let submit = app.buttons["connection.submit"]
        expectExists(address, in: app)
        reveal(submit, in: app)
        verify(!submit.isEnabled, in: app, "An empty connection must not be submitted.")

        reveal(address, in: app, upward: false)
        replaceText(in: address, with: "http://ui-test.invalid", app: app)
        reveal(key, in: app)
        replaceText(in: key, with: "ui-test-valid-key", app: app)
        reveal(submit, in: app)
        submit.tap()
        let invalidServer = textContaining("服务地址格式无效", in: app)
        reveal(invalidServer, in: app, upward: false, requiresHitTarget: false)
        verify(invalidServer.label.contains("服务地址格式无效"), in: app,
               "An HTTP address must produce the actual HTTPS validation error.")
        attach(app, name: "login-invalid-https")

        reveal(address, in: app, upward: false)
        replaceText(in: address, with: "https://ui-test.invalid", app: app)
        reveal(key, in: app)
        replaceText(in: key, with: "ui-test-invalid-key", app: app)
        reveal(submit, in: app)
        submit.tap()
        let unauthorized = textContaining("CPA 管理密钥鉴权失败", in: app)
        reveal(unauthorized, in: app, upward: false, requiresHitTarget: false)
        verify(unauthorized.label.contains("CPA 管理密钥鉴权失败"), in: app,
               "The real management HTTP 401 response must be presented as an authentication failure.")
        verify(!element("quota.options", in: app).exists, in: app,
               "A management 401 must not open the quota workspace.")
        attach(app, name: "login-management-401")

        reveal(key, in: app, upward: false)
        replaceText(in: key, with: "ui-test-valid-key", app: app)
        reveal(submit, in: app)
        submit.tap()
        let account = element("quota.account.ui-main", in: app)
        expectExists(element("quota.options", in: app), in: app, timeout: 15)
        reveal(account, in: app)
        verify(nativeTab("quotas", title: "额度总览", in: app).isSelected, in: app,
               "Successful authentication must return to the selected native quota destination.")
        let remaining = textContaining("42% 剩余", in: app)
        reveal(remaining, in: app, requiresHitTarget: false)
        verify(remaining.label.contains("42% 剩余"), in: app,
               "The connected workspace must show the parsed fixture's remaining quota.")
        verify(!textContaining("native@example.com", in: app).exists, in: app,
               "The default masking preference must apply to accessible text.")
        attach(app, name: "login-connected-quota")
    }

    @MainActor
    func testCloseDuringSlowConnectionClearsDraftAndRejectsLateResponse() {
        verifySlowConnectionDismissal(interactively: false)
    }

    @MainActor
    func testSwipeDismissalDuringSlowConnectionClearsDraftAndRejectsLateResponse() {
        verifySlowConnectionDismissal(interactively: true)
    }

    @MainActor
    private func verifySlowConnectionDismissal(interactively: Bool) {
        let app = launch(connected: false)
        defer { app.terminate() }
        let address = app.textFields["connection.server"]
        let key = app.secureTextFields["connection.key"]
        let submit = app.buttons["connection.submit"]
        replaceText(in: address, with: "https://slow-ui-test.invalid", app: app)
        reveal(key, in: app)
        replaceText(in: key, with: "ui-test-valid-key", app: app)
        reveal(submit, in: app)
        submit.tap()
        expectExists(app.buttons["connection.cancel"], in: app)
        let close = app.buttons["connection.close"]
        if interactively {
            let grabber = app.buttons["Sheet Grabber"]
            expectExists(grabber, in: app)
            expectPredicate(NSPredicate(format: "hittable == true"), on: grabber, in: app,
                            message: "The native sheet grabber must be tappable.",
                            finalCheck: { grabber.isHittable })
            grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        } else {
            reveal(close, in: app, upward: false)
            verify(close.isHittable, in: app, "The connection sheet close button must be tappable.")
            close.tap()
        }
        expectPredicate(NSPredicate(format: "exists == false"), on: close, in: app,
                        message: "The connection sheet must actually close.",
                        finalCheck: { !close.exists })
        let start = app.buttons["connection.start"]
        expectExists(start, in: app)
        expectPredicate(NSPredicate(format: "hittable == true"), on: start, in: app,
                        message: "The connection start action must be tappable after dismissal.",
                        finalCheck: { start.isHittable })
        expectExists(app.staticTexts["ui-test.slowResponse.pending"], in: app)
        let release = app.buttons["ui-test.slowResponse.release"]
        expectExists(release, in: app)
        verify(release.isHittable, in: app, "The fixture release control must be tappable.")
        release.tap()
        expectExists(app.staticTexts["ui-test.slowResponse.returned"], in: app)
        verify(!element("quota.options", in: app).waitForExistence(timeout: 6), in: app,
               "A response received after dismissal must not open or replace the workspace.")
        start.tap()
        expectExists(address, in: app)
        replaceText(in: address, with: "https://ui-test.invalid", app: app)
        reveal(submit, in: app)
        verify(!submit.isEnabled, in: app,
               "Reopening with a valid address must require a new management key.")
        attach(app, name: interactively ? "connection-cancel-swipe" : "connection-cancel-close")
    }

    @MainActor
    func testFiveNativeTabsAndQuotaDetailKeepTheirSystemNavigation() {
        let app = launch(connected: true)
        defer { app.terminate() }
        let tabs = [
            ("quotas", "额度总览"), ("usage", "CAP 用量"),
            ("chat", "AI 对话"), ("accounts", "账号诊断"),
            ("connection", "连接管理")
        ]
        // TabView may become a side rail on iOS 27. Verify all five native
        // destinations without requiring a specific UIKit TabBar hierarchy.
        for (id, title) in tabs {
            let tab = nativeTab(id, title: title, in: app)
            expectExists(tab, in: app, timeout: 5)
            verify(tab.isHittable, in: app, "The native destination \(title) must be reachable.")
        }
        for (id, title) in tabs {
            selectTab(id, title: title, in: app)
            verify(app.navigationBars.firstMatch.exists, in: app,
                   "Each workspace must retain its native navigation stack.")
            if id == "chat" {
                verify(element("chat.new", in: app).exists, in: app,
                       "A connected session must show the chat list with its new-conversation action.")
            }
            attach(app, name: "tab-\(id)")
        }

        selectTab("quotas", title: "额度总览", in: app)
        let account = element("quota.account.ui-main", in: app)
        reveal(account, in: app)
        account.tap()
        expectExists(app.navigationBars["账号详情"], in: app, timeout: 5)
        verify(element("quota.account.refresh", in: app).exists, in: app,
               "The account detail must retain its refresh action.")
        let remaining = textContaining("42% 剩余", in: app)
        reveal(remaining, in: app, requiresHitTarget: false)
        verify(remaining.label.contains("42% 剩余"), in: app,
               "The account detail must show the real parsed remaining percentage.")
        attach(app, name: "quota-detail-multiple-windows")
        let detailNav = app.navigationBars["账号详情"]
        app.buttons["完成"].tap()
        expectPredicate(NSPredicate(format: "exists == false"), on: detailNav, in: app,
                        message: "Done must dismiss the native account sheet.",
                        finalCheck: { !detailNav.exists })
        expectExists(account, in: app, timeout: 5)
    }

    @MainActor
    func testQuotaCardShowsRegularCodexWindowsInOrderWithUnknownAndSevenDayOnly() {
        let app = launch(connected: true)
        defer { app.terminate() }
        selectTab("quotas", title: "额度总览", in: app)

        let fiveHour = element("quota.card.ui-main.5h", in: app)
        let sevenDay = element("quota.card.ui-main.7d", in: app)
        reveal(fiveHour, in: app, requiresHitTarget: false)
        reveal(sevenDay, in: app, requiresHitTarget: false)
        verify(fiveHour.exists && sevenDay.exists, in: app,
               "The Codex card must show both the 5-hour and 7-day regular windows.")
        verify(fiveHour.frame.minY < sevenDay.frame.minY, in: app,
               "The 5-hour row must render above the 7-day row.")
        verify(fiveHour.label.contains("42% 剩余") && sevenDay.label.contains("91% 剩余"), in: app,
               "Each row must show its own parsed remaining percentage.")
        attach(app, name: "quota-card-both-windows")

        let emptyRow = element("quota.card.ui-empty.5h", in: app)
        reveal(emptyRow, in: app, requiresHitTarget: false)
        verify(emptyRow.label.contains("0% 剩余"), in: app,
               "A real exhausted reading must stay a real zero, not unknown.")
        attach(app, name: "quota-card-exhausted")

        let weekly = element("quota.card.ui-weekly.7d", in: app)
        reveal(weekly, in: app, requiresHitTarget: false)
        expectExists(weekly, in: app, timeout: 5)
        verify(!element("quota.card.ui-weekly.5h", in: app).exists, in: app,
               "A 7-day-only account must show only its existing window.")

        let unknown = element("quota.card.ui-unknown.5h", in: app)
        reveal(unknown, in: app, requiresHitTarget: false)
        expectExists(unknown, in: app, timeout: 5)
        verify(unknown.label.contains("剩余比例未知"), in: app,
               "A missing ratio must read as unknown, never as zero.")
        attach(app, name: "quota-card-unknown-ratio")
    }

    @MainActor
    func testCAPRangePanelCancelsWithoutRequestsAndSelectsBoundedHours() {
        let app = launch(connected: true)
        defer { app.terminate() }
        selectTab("usage", title: "CAP 用量", in: app)

        // Cancel first: the selection and the pending window must not change,
        // and no endpoint read may start.
        let picker = app.buttons["cap.rangePicker"]
        reveal(picker, in: app, upward: false)
        picker.tap()
        let cancel = app.buttons["cap.range.cancel"]
        expectExists(cancel, in: app, timeout: 5)
        cancel.tap()
        expectPredicate(NSPredicate(format: "exists == false"), on: cancel, in: app,
                        message: "Canceling the CAP range panel must dismiss the sheet.",
                        finalCheck: { !cancel.exists })
        let quickState = textContaining("查看近 30 分钟用量", in: app)
        reveal(quickState, in: app, requiresHitTarget: false)
        verify(quickState.label.contains("查看近 30 分钟用量"), in: app,
               "Canceling the panel must keep the default 30-minute selection.")
        verify(!app.staticTexts["cap.overview.loaded"].exists, in: app,
               "Canceling the panel must not trigger any CAP read.")
        attach(app, name: "cap-range-cancelled")

        // Level one groups by unit; level two lists bounded counts including
        // the legacy 24-hour boundary entry.
        reveal(picker, in: app, upward: false)
        picker.tap()
        let hoursGroup = app.buttons["cap.range.group.hours"]
        expectExists(hoursGroup, in: app, timeout: 5)
        hoursGroup.tap()
        let hoursList = app.collectionViews.containing(.button, identifier: "cap.range.option").firstMatch
        expectExists(hoursList, in: app, timeout: 5)
        let firstHour = hoursList.buttons["1 小时"]
        expectExists(firstHour, in: app, timeout: 5)
        let lastHour = hoursList.buttons["24 小时"]
        // The sheet's lazy list only exposes nearby options in the accessibility tree.
        for _ in 0..<12 {
            if lastHour.exists && lastHour.isHittable { break }
            hoursList.swipeUp()
        }
        verify(lastHour.exists && lastHour.isHittable, in: app,
               "The legacy 24-hour entry must be reachable by scrolling the hour list.")
        verify(app.buttons["cap.range.cancel"].exists, in: app,
               "The second level must keep its own cancel action.")
        let option = hoursList.buttons["3 小时"]
        for _ in 0..<12 {
            if option.exists && option.isHittable { break }
            hoursList.swipeDown()
        }
        verify(option.exists && option.isHittable, in: app,
               "Scrolling back must make the 3-hour option selectable again.")
        option.tap()
        let sheetCancel = app.buttons["cap.range.cancel"]
        expectPredicate(NSPredicate(format: "exists == false"), on: sheetCancel, in: app,
                        message: "Selecting a CAP hour range must dismiss the sheet.",
                        finalCheck: { !sheetCancel.exists })
        let hourState = textContaining("查看近 3 小时用量", in: app)
        reveal(hourState, in: app, requiresHitTarget: false)
        verify(hourState.label.contains("查看近 3 小时用量"), in: app,
               "Confirming a bounded count must update the pending range without reading data.")
        verify(!app.staticTexts["cap.overview.loaded"].exists, in: app,
               "Selecting a range alone must not issue a request.")
        attach(app, name: "cap-range-hours-selected")

        // The manual refresh uses the newly selected window.
        let load = app.buttons["cap.loadOverview"]
        reveal(load, in: app)
        load.tap()
        let loaded = app.staticTexts["cap.overview.loaded"]
        reveal(loaded, in: app, requiresHitTarget: false)
        verify(loaded.exists, in: app,
               "The explicit overview read must complete against the selected hour window.")
        attach(app, name: "cap-range-hours-loaded")
    }

    @MainActor
    func testCAPMonthOverviewUsesServerSummaryFromInitialOnly() {
        let app = launch(connected: true)
        defer { app.terminate() }
        selectTab("usage", title: "CAP 用量", in: app)

        let picker = app.buttons["cap.rangePicker"]
        reveal(picker, in: app, upward: false)
        picker.tap()
        let monthsGroup = app.buttons["cap.range.group.months"]
        expectExists(monthsGroup, in: app, timeout: 5)
        monthsGroup.tap()
        let monthOption = app.buttons["1 个月"]
        reveal(monthOption, in: app)
        monthOption.tap()
        let sheetCancel = app.buttons["cap.range.cancel"]
        expectPredicate(NSPredicate(format: "exists == false"), on: sheetCancel, in: app,
                        message: "Selecting a CAP month range must dismiss the sheet.",
                        finalCheck: { !sheetCancel.exists })
        let monthState = textContaining("查看按月模型汇总", in: app)
        reveal(monthState, in: app, requiresHitTarget: false)
        verify(monthState.label.contains("查看按月模型汇总"), in: app,
               "Selecting a month range must switch the model overview to the server summary source.")
        verify(!app.staticTexts["cap.overview.loaded"].exists, in: app,
               "Selecting a month must not run the request-sample overview.")
        attach(app, name: "cap-range-month-selected")

        let load = app.buttons["cap.loadMonthlyOverview"]
        reveal(load, in: app)
        load.tap()
        let loaded = element("cap.monthly.loaded", in: app)
        reveal(loaded, in: app, requiresHitTarget: false)
        verify(loaded.exists, in: app,
               "The explicit month read must publish the stats/initial server summary.")
        let summary = textContaining("服务端汇总", in: app)
        reveal(summary, in: app, requiresHitTarget: false)
        verify(summary.label.contains("服务端汇总"), in: app,
               "The month overview must label its server-aggregated source.")
        let model = textContaining("fixture-model", in: app)
        reveal(model, in: app, requiresHitTarget: false)
        verify(model.label.contains("fixture-model"), in: app,
               "The merged-by-model rows must come from the initial fixture payload.")
        attach(app, name: "cap-month-overview-loaded")
    }

    @MainActor
    func testCAPAllFourSectionsReadParsedFixtures() {
        let app = launch(connected: true)
        defer { app.terminate() }
        selectTab("usage", title: "CAP 用量", in: app)
        let sections = [
            ("模型概览", "cap.loadOverview", "cap.overview.loaded"),
            ("趋势·分组·费用", "cap.loadAnalytics", "cap.analytics.loaded"),
            ("请求记录", "cap.loadRequests", "cap.requests.loaded"),
            ("管理统计", "cap.loadManagement", "cap.management.loaded")
        ]
        for (title, loadID, loadedID) in sections {
            let picker = app.buttons["cap.sectionPicker"]
            reveal(picker, in: app, upward: false)
            picker.tap()
            let option = app.buttons[title]
            expectExists(option, in: app, timeout: 5)
            option.tap()
            let load = app.buttons[loadID]
            reveal(load, in: app)
            verify(load.isEnabled, in: app, "The selected CAP section must be loadable.")
            load.tap()
            let loaded = loadedID == "cap.overview.loaded"
                ? app.staticTexts[loadedID]
                : element(loadedID, in: app)
            reveal(loaded, in: app, requiresHitTarget: loadedID == "cap.analytics.loaded")
            verify(loaded.exists, in: app, "Parsed content must replace the empty state for \(title).")
            if loadedID == "cap.overview.loaded" {
                verify(loaded.label == "当前窗口的响应为单页", in: app,
                       "The overview must display the fixture's complete single-page result.")
            }
            attach(app, name: loadedID)
        }
    }

    @MainActor
    func testChatSelectsModelStreamsStopsAndRegenerates() {
        let app = launch(connected: true)
        defer { app.terminate() }
        selectTab("chat", title: "AI 对话", in: app)
        let newChat = element("chat.emptyNew", in: app)
        reveal(newChat, in: app)
        newChat.tap()

        let modelMenu = element("chat.modelMenu", in: app)
        expectExists(modelMenu, in: app)
        modelMenu.tap()
        let alternateModel = textContaining("fixture-chat-alternate", in: app)
        expectExists(alternateModel, in: app)
        alternateModel.tap()
        verify(modelMenu.label.contains("fixture-chat-alternate"), in: app,
               "The selected model must apply to this conversation.")

        let input = element("chat.input", in: app)
        expectExists(input, in: app)
        input.tap()
        input.typeText("Fixture question")
        tapChatSend(in: app)
        let partial = textContaining("第一段夹具回复", in: app)
        expectExists(partial, in: app)
        let stop = element("chat.stop", in: app)
        expectExists(stop, in: app)
        stop.tap()
        expectExists(textContaining("已停止生成", in: app), in: app)
        verify(partial.exists, in: app, "Stopping must keep the streamed text.")

        let regenerate = element("chat.regenerate", in: app)
        reveal(regenerate, in: app)
        regenerate.tap()
        expectExists(textContaining("重新生成的夹具回复", in: app), in: app)
        verify(!partial.exists, in: app, "Regenerating must replace the stopped reply.")
    }

    @MainActor
    func testMonitoringDeepLinkOpensMonitoringPage() throws {
        let app = launch(connected: true)
        defer { app.terminate() }
        selectTab("chat", title: "AI 对话", in: app)
        app.open(try XCTUnwrap(URL(string: "cpaquota://monitor?source=personal")))
        expectExists(app.navigationBars["监控与活动"], in: app, timeout: 10)
        expectExists(element("monitoring.unconfigured", in: app), in: app)
    }

    @MainActor
    func testUnconfiguredMonitoringRequiresSeparateCredentials() {
        let app = launch(connected: true)
        defer { app.terminate() }
        selectTab("connection", title: "连接管理", in: app)
        let monitoringEntry = element("connection.monitoring", in: app)
        reveal(monitoringEntry, in: app)
        monitoringEntry.tap()
        expectExists(app.navigationBars["监控与活动"], in: app, timeout: 5)
        let unconfigured = element("monitoring.unconfigured", in: app)
        expectExists(unconfigured, in: app, timeout: 5)
        let connectLink = app.buttons["连接监控服务"]
        reveal(connectLink, in: app)
        connectLink.tap()
        let address = element("monitor.bridgeAddress", in: app)
        let token = element("monitor.bridgeToken", in: app)
        let connect = element("monitor.connect", in: app)
        expectExists(address, in: app, timeout: 5)
        verify(token.exists, in: app, "Monitoring must request its own credential.")
        reveal(connect, in: app)
        verify(!connect.isEnabled, in: app, "A CPA connection must not act as monitoring bridge credentials.")
        attach(app, name: "monitoring-unconfigured-separate-credentials")
    }

    @MainActor
    func testAppearancePickerChangesRealCanvasAndWidgetSharingDefaultsOff() throws {
        let app = launch(connected: true)
        defer { app.terminate() }
        selectTab("connection", title: "连接管理", in: app)
        let appearance = element("settings.appearance", in: app)
        reveal(appearance, in: app)

        chooseAppearance("浅色羊皮纸", picker: appearance, in: app)
        let light = try canvasBrightness(app.screenshot().image)
        verify(light > 0.65, in: app, "The light setting must render a light content canvas; measured \(light).")
        attach(app, name: "settings-light")

        chooseAppearance("深色曜石", picker: appearance, in: app)
        let dark = try canvasBrightness(app.screenshot().image)
        verify(dark < 0.25, in: app, "The dark setting must render a dark content canvas; measured \(dark).")
        verify(light - dark > 0.45, in: app, "The canvas must materially change between light and dark.")
        attach(app, name: "settings-dark")

        let sharing = app.switches["settings.widgetSharing"]
        reveal(sharing, in: app)
        verify(sharing.value as? String == "0", in: app,
               "Sharing quota with widgets requires an explicit opt-in.")
        let masking = app.switches["settings.maskEmail"]
        verify(masking.value as? String == "1", in: app, "Email masking must default to enabled.")
    }

    @MainActor
    func testLargestDynamicTypeAndDeviceRotationPreservePrimaryActions() async {
        let normal = launch(connected: true)
        let policy = layoutPolicy(in: normal)
        let rotationSuffix = policy == .duoAdaptive ? "rotated-system-window" : "landscape"
        let normalAccount = element("quota.account.ui-main", in: normal)
        reveal(normalAccount, in: normal)
        let normalHeight = normalAccount.frame.height
        verify(normalHeight >= 44, in: normal, "The normal account button must have a 44-point hit target.")
        let normalWindow = await rotateDeviceAndWaitForWindow(in: normal, policy: policy)
        reveal(normalAccount, in: normal, upward: false)
        normalAccount.tap()
        expectExists(normal.buttons["完成"], in: normal, timeout: 5)
        let normalEmail = element("quota.detail.email", in: normal)
        reveal(normalEmail, in: normal, requiresHitTarget: false)
        let normalEmailHeight = normalEmail.frame.height
        verify(normalEmailHeight > 0, in: normal, "The normal detail email row must have a measurable layout.")
        attach(normal, name: "quota-detail-normal-\(rotationSuffix)")
        normal.terminate()

        let app = launch(connected: true, largeText: true)
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }
        let account = element("quota.account.ui-main", in: app)
        reveal(account, in: app)
        let largeAccountHeight = account.frame.height
        verify(largeAccountHeight > normalHeight, in: app,
               "Largest Dynamic Type must change actual text layout: normal \(normalHeight), large \(largeAccountHeight).")
        verify(account.isHittable, in: app, "The enlarged account button must remain tappable.")
        attach(app, name: "quota-accessibility5-portrait")

        let largeWindow = await rotateDeviceAndWaitForWindow(in: app, policy: policy)
        expectExists(nativeTab("quotas", title: "额度总览", in: app), in: app, timeout: 5)
        verify(largeWindow.size == normalWindow.size, in: app,
               "Normal and accessibility5 detail layouts must be compared in the same actual window shape.")
        reveal(account, in: app, upward: false)
        verify(account.isHittable, in: app, "The account button must remain tappable after device rotation.")
        account.tap()
        let close = app.buttons["完成"]
        expectExists(close, in: app, timeout: 5)
        let largeEmail = element("quota.detail.email", in: app)
        reveal(largeEmail, in: app, requiresHitTarget: false)
        let largeEmailHeight = largeEmail.frame.height
        print("FRONTEND_DYNAMIC_TYPE normalAccountHeight=\(normalHeight) largeAccountHeight=\(largeAccountHeight) normalEmailHeight=\(normalEmailHeight) largeEmailHeight=\(largeEmailHeight) normalWindow=\(normalWindow) largeWindow=\(largeWindow) policy=\(policy.rawValue)")
        verify(largeEmailHeight > normalEmailHeight, in: app,
               "The sheet must inherit accessibility5: normal email height \(normalEmailHeight), large \(largeEmailHeight).")
        verify(close.isHittable, in: app, "Done must remain reachable at the largest font after device rotation.")
        verify(element("quota.account.refresh", in: app).isHittable, in: app,
               "The account refresh action must remain reachable at the largest font after device rotation.")
        attach(app, name: "quota-detail-accessibility5-\(rotationSuffix)")
        close.tap()
        expectPredicate(NSPredicate(format: "exists == false"), on: close, in: app,
                        message: "Done must dismiss the account sheet before switching tabs.",
                        finalCheck: { !close.exists })

        selectTab("connection", title: "连接管理", in: app)
        let masking = app.switches["settings.maskEmail"]
        reveal(masking, in: app)
        verify(masking.isHittable, in: app, "The privacy setting must remain operable after device rotation.")
        verify(masking.frame.height >= 44, in: app, "The privacy setting must retain a 44-point hit target.")
        attach(app, name: "settings-accessibility5-\(rotationSuffix)")
    }

    private enum UILayoutPolicy: String {
        case standardIPhone = "standard-iphone"
        case duoAdaptive = "duo-adaptive"
    }

    @MainActor
    private func layoutPolicy(in app: XCUIApplication) -> UILayoutPolicy {
        let environment = ProcessInfo.processInfo.environment
        let raw = environment["CPA_UI_LAYOUT_POLICY"] ?? UILayoutPolicy.standardIPhone.rawValue
        guard let policy = UILayoutPolicy(rawValue: raw) else {
            verify(false, in: app, "Unknown UI layout policy: \(raw).")
            return .standardIPhone
        }
        if policy == .duoAdaptive {
            verify(environment["CPA_UI_SIMULATOR_DEVICE"] == "iPhone Duo", in: app,
                   "The adaptive-window policy is only valid for the explicitly selected iPhone Duo simulator.")
        }
        return policy
    }

    @MainActor
    private func rotateDeviceAndWaitForWindow(in app: XCUIApplication, policy: UILayoutPolicy) async -> CGRect {
        XCUIDevice.shared.orientation = .landscapeLeft
        let deadline = Date.now.addingTimeInterval(5)
        var previous = CGRect.null
        var stableSamples = 0
        var frame = app.frame
        var settled = false
        repeat {
            frame = app.frame
            stableSamples = frame == previous ? stableSamples + 1 : 0
            previous = frame
            let expectedShape = policy == .duoAdaptive || frame.width > frame.height
            if !frame.isEmpty, stableSamples >= 2, expectedShape {
                settled = true
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        } while Date.now < deadline

        verify(XCUIDevice.shared.orientation == .landscapeLeft, in: app,
               "The simulator must accept the requested physical device orientation.")
        verify(settled, in: app,
               "Rotation must settle to a valid window for \(policy.rawValue); actual frame \(frame).")
        if policy == .standardIPhone {
            verify(frame.width > frame.height, in: app,
                   "A standard iPhone must actually render a wide landscape window.")
        }
        // Duo can retain a portrait-shaped inner display after physical
        // rotation. Record that actual shape rather than claiming a wide app.
        print("FRONTEND_ROTATION policy=\(policy.rawValue) frame=\(frame) physicalOrientation=\(XCUIDevice.shared.orientation.rawValue)")
        return frame
    }

    @MainActor
    private func launch(connected: Bool, largeText: Bool = false, arguments: [String] = [],
                        environment: [String: String] = [:]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", connected ? "--fixture=connected" : "--fixture=unconfigured"]
        app.launchEnvironment.merge(environment) { _, value in value }
        app.launchArguments += arguments
        if largeText { app.launchArguments.append("--ui-test-large-text") }
        app.launch()
        verify(app.wait(for: .runningForeground, timeout: 10), in: app, "The fixture app must launch in the foreground.")
        verify(!element("ui-test.preparationFailed", in: app).exists, in: app, "Fixture preparation must succeed.")
        if connected {
            // The toolbar is available before lazy account rows, including
            // when accessibility text sizes require scrolling to the first row.
            expectExists(element("quota.options", in: app), in: app, timeout: 15)
            reveal(element("quota.account.ui-main", in: app), in: app)
        } else {
            let start = app.buttons["connection.start"]
            expectExists(start, in: app, timeout: 15)
            start.tap()
            expectExists(app.textFields["connection.server"], in: app, timeout: 15)
        }
        return app
    }

    @MainActor
    func testReasoningIsVisibleBeforeAnswerIsReleased() {
        let app = launch(connected: true, arguments: ["--ui-test-chat-gate"])
        defer { app.terminate() }
        selectTab("chat", title: "AI 对话", in: app)
        element("chat.emptyNew", in: app).tap()
        let input = element("chat.input", in: app)
        input.tap()
        input.typeText("S1")
        tapChatSend(in: app)
        let reasoning = app.staticTexts["可见推理片段"]
        expectExists(reasoning, in: app)
        XCTAssertTrue(reasoning.isHittable)
        XCTAssertTrue(element("chat.stop", in: app).isHittable)
        XCTAssertFalse(textContaining("放行后的正文", in: app).exists)
        element("ui-test.chat.release", in: app).tap()
        expectExists(textContaining("放行后的正文", in: app), in: app)
        textContaining("思考过程", in: app).tap()
        expectExists(reasoning, in: app)
    }

    @MainActor
    private func startCheckpointScenario(_ app: XCUIApplication) {
        selectTab("chat", title: "AI 对话", in: app)
        element("chat.emptyNew", in: app).tap()
        let input = element("chat.input", in: app)
        input.tap()
        input.typeText("B4")
        tapChatSend(in: app)
        let checkpoint = element("ui-test.chat.checkpoint", in: app)
        expectExists(checkpoint, in: app)
        checkpoint.tap()
        expectExists(app.staticTexts["生成请求 1，已写块 1"], in: app)
    }

    @MainActor
    func testInterruptedGenerationRestoresWrittenCheckpointWithoutRequest() {
        let arguments = ["--ui-test-chat-gate", "--ui-test-chat-store=\(UUID().uuidString)"]
        let first = launch(connected: true, arguments: arguments)
        startCheckpointScenario(first)
        first.terminate()
        let reopened = launch(connected: true, arguments: arguments)
        defer { reopened.terminate() }
        selectTab("chat", title: "AI 对话", in: reopened)
        let row = reopened.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.conversation.")).firstMatch
        expectExists(row, in: reopened)
        row.tap()
        expectExists(textContaining("保存片段一", in: reopened), in: reopened)
        expectExists(textContaining("生成已中断", in: reopened), in: reopened)
        textContaining("思考过程", in: reopened).tap()
        expectExists(reopened.staticTexts["可见推理片段"], in: reopened)
        expectExists(element("chat.continue", in: reopened), in: reopened)
        XCTAssertFalse(element("chat.stop", in: reopened).exists)
        XCTAssertTrue(element("ui-test.chat.counts", in: reopened).label.contains("生成请求 0"))
    }

    @MainActor
    func testStopContinueAndCompleteOneReply() {
        let arguments = ["--ui-test-chat-gate", "--ui-test-chat-continuation", "--ui-test-chat-store=\(UUID().uuidString)"]
        let app = launch(connected: true, arguments: arguments)
        startCheckpointScenario(app)
        element("chat.stop", in: app).tap()
        let resume = element("chat.continue", in: app)
        expectExists(resume, in: app)
        XCTAssertEqual(resume.label, "续写上一条回复")
        let field = element("chat.input", in: app)
        field.tap()
        field.typeText("X")
        XCTAssertTrue(element("chat.send", in: app).isEnabled)
        XCTAssertFalse(resume.exists)
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        expectExists(resume, in: app)
        resume.tap()
        expectExists(element("chat.stop", in: app), in: app)
        element("ui-test.chat.checkpoint", in: app).tap()
        expectExists(app.staticTexts["生成请求 2，已写块 1"], in: app)
        app.terminate()

        let reopened = launch(connected: true, arguments: arguments)
        defer { reopened.terminate() }
        selectTab("chat", title: "AI 对话", in: reopened)
        reopened.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chat.conversation.")).firstMatch.tap()
        expectExists(textContaining("保存片段一追加片段二", in: reopened), in: reopened)
        XCTAssertTrue(element("ui-test.chat.counts", in: reopened).label.contains("生成请求 0"))
        element("chat.continue", in: reopened).tap()
        element("ui-test.chat.release", in: reopened).tap()
        expectExists(textContaining("保存片段一追加片段二放行后的正文", in: reopened), in: reopened)
        XCTAssertTrue(element("ui-test.chat.counts", in: reopened).label.contains("生成请求 1"))
        XCTAssertFalse(element("chat.continue", in: reopened).exists)
        attach(reopened, name: "continued-assistant-reply")
    }

    @MainActor
    func testForegroundReturnAndExplicitExpiryKeepOneGeneration() {
        let arguments = ["--ui-test-chat-gate", "--ui-test-chat-store=\(UUID().uuidString)"]
        let app = launch(connected: true, arguments: arguments)
        defer { app.terminate() }
        startCheckpointScenario(app)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(element("chat.stop", in: app).exists)
        element("ui-test.chat.expire", in: app).tap()
        expectExists(textContaining("后台生成已中断", in: app), in: app)
        expectExists(textContaining("保存片段一", in: app), in: app)
        let regenerate = element("chat.regenerate", in: app)
        reveal(regenerate, in: app)
        regenerate.tap()
        let confirmation = app.buttons["确认重新生成"]
        expectExists(confirmation, in: app)
        if app.buttons["取消"].exists {
            app.buttons["取消"].tap()
        } else {
            // Compact confirmation popovers can expose only the affirmative action.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.12)).tap()
        }
        XCTAssertFalse(confirmation.exists)
        XCTAssertTrue(element("ui-test.chat.counts", in: app).label.contains("生成请求 1"))
        regenerate.tap()
        app.buttons["确认重新生成"].tap()
        expectExists(element("chat.stop", in: app), in: app)
        // The Stop button tracks the workspace task. The engine increments its
        // counter on a later main-actor turn, after the request actually starts.
        let twoRequests = app.staticTexts.matching(identifier: "ui-test.chat.counts")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "生成请求 2，")).firstMatch
        expectExists(twoRequests, in: app)
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    func testReadingPositionDuringStreamGrowth() {
        let app = launch(connected: true, arguments: ["--ui-test-chat-gate", "--ui-test-chat-scroll"])
        defer { app.terminate() }
        selectTab("chat", title: "AI 对话", in: app)
        element("chat.emptyNew", in: app).tap()
        let input = element("chat.input", in: app)
        input.tap()
        input.typeText("Reading anchor")
        tapChatSend(in: app)
        let extend = element("ui-test.chat.extend", in: app)
        extend.tap()
        let last = textContaining("阅读段落 18", in: app)
        expectExists(last, in: app)
        let viewport = CGRect(x: 0, y: app.navigationBars.firstMatch.frame.maxY,
                              width: app.frame.width, height: max(0, input.frame.minY - app.navigationBars.firstMatch.frame.maxY))
        // Wait briefly for the animated streaming auto-scroll to finish settling into the viewport.
        let settleDeadline = Date().addingTimeInterval(3)
        var lastFrame = last.frame
        while !viewport.contains(CGPoint(x: lastFrame.midX, y: lastFrame.midY)), Date() < settleDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            if last.exists, let snap = try? last.snapshot() {
                lastFrame = snap.frame
            }
        }
        XCTAssertTrue(viewport.contains(CGPoint(x: lastFrame.midX, y: lastFrame.midY)),
                      "U1 bottom \(lastFrame) viewport \(viewport)")
        let first = element("chat.message.user", in: app)
        reveal(first, in: app, upward: false, requiresHitTarget: false)
        let originalY = first.frame.midY
        XCTAssertTrue(viewport.contains(CGPoint(x: first.frame.midX, y: originalY)))
        extend.tap()
        expectExists(textContaining("阅读段落 36", in: app), in: app)
        XCTAssertTrue(viewport.contains(CGPoint(x: first.frame.midX, y: first.frame.midY)))
        XCTAssertEqual(first.frame.midY, originalY, accuracy: 30)

        let firstParagraph = textContaining("阅读段落 1", in: app)
        let edit = element("chat.edit", in: app)
        expectExists(firstParagraph, in: app)
        XCTAssertFalse(edit.isEnabled)
        let replyOffset = firstParagraph.frame.minY - first.frame.minY
        element("ui-test.chat.release", in: app).tap()
        expectExists(edit, in: app)
        XCTAssertTrue(edit.isEnabled)
        XCTAssertTrue(viewport.contains(CGPoint(x: first.frame.midX, y: first.frame.midY)))
        XCTAssertEqual(firstParagraph.frame.minY - first.frame.minY, replyOffset, accuracy: 2)
    }

    @MainActor
    func testChatEditCancelRestoresMultilineDraft() {
        let app = launch(connected: true, arguments: ["--ui-test-chat-gate", "--ui-test-chat-image"])
        defer { app.terminate() }
        selectTab("chat", title: "AI 对话", in: app)
        element("chat.emptyNew", in: app).tap()
        let input = element("chat.input", in: app)
        input.tap()
        input.typeText("Earlier")
        tapChatSend(in: app)
        element("ui-test.chat.release", in: app).tap()
        expectExists(textContaining("放行后的正文", in: app), in: app)
        input.tap()
        input.typeText("draft one\ndraft two")
        element("chat.attach", in: app).tap()
        expectExists(app.buttons["移除图片"], in: app)
        let edit = app.buttons["编辑并重新发送"].firstMatch
        guard edit.exists else {
            XCTFail("U3 user-message editing has no discoverable button")
            return
        }
        reveal(edit, in: app, upward: false)
        edit.tap()
        XCTAssertEqual(input.value as? String, "Earlier")
        XCTAssertFalse(app.buttons["移除图片"].exists)
        app.buttons["取消"].tap()
        XCTAssertEqual(input.value as? String, "draft one\ndraft two")
        XCTAssertTrue(app.buttons["移除图片"].exists)
        XCTAssertTrue(app.buttons["复制"].firstMatch.exists)
        XCTAssertTrue(element("chat.regenerate", in: app).exists)
        let backButton = element("BackButton", in: app)
        expectExists(backButton, in: app)
        backButton.tap()
        element("chat.new", in: app).tap()
        XCTAssertFalse((element("chat.input", in: app).value as? String)?.contains("draft one") == true)
    }

    @MainActor
    func testLargeChatControlsInLightAndDarkLandscape() async throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        for appearance in ["light", "dark"] {
            let app = launch(connected: true, largeText: true, arguments: ["--ui-test-theme=" + appearance])
            defer { app.terminate() }
            selectTab("chat", title: "AI 对话", in: app)
            element("chat.new", in: app).tap()
            let menu = element("chat.modelMenu", in: app)
            let send = element("chat.send", in: app)
            XCTAssertTrue(menu.isHittable)
            XCTAssertTrue(send.exists)
            let lightness = try canvasBrightness(app.screenshot().image)
            if appearance == "light" { XCTAssertGreaterThan(lightness, 0.65) }
            else { XCTAssertLessThan(lightness, 0.25) }
            _ = await rotateDeviceAndWaitForWindow(in: app, policy: layoutPolicy(in: app))
            XCTAssertTrue(menu.isHittable)
            XCTAssertTrue(element("chat.attach", in: app).isHittable)
            let reasoning = element("chat.reasoningTrigger", in: app)
            XCTAssertTrue(reasoning.isHittable)
            XCTAssertLessThanOrEqual(element("chat.input", in: app).frame.maxY, reasoning.frame.minY + 2)
            XCTAssertTrue(app.frame.contains(CGPoint(x: send.frame.midX, y: send.frame.midY)))
            attach(app, name: "chat-large-landscape-" + appearance)
        }
    }

    @MainActor
    func testRecentModelPersistsAcrossCreationAndLaunch() {
        let args = ["--ui-test-chat-store=\(UUID().uuidString)", "--ui-test-chat-models", "--ui-test-chat-gate"]
        let app = launch(connected: true, arguments: args)
        selectTab("chat", title: "AI 对话", in: app)
        element("chat.emptyNew", in: app).tap()
        element("chat.modelMenu", in: app).tap()
        textContaining("fixture-chat-alternate", in: app).tap()
        expectExists(app.staticTexts["模型选择已写入"], in: app)
        let input = element("chat.input", in: app)
        input.tap()
        input.typeText("M1")
        tapChatSend(in: app)
        expectExists(element("chat.stop", in: app), in: app)
        let release = element("ui-test.chat.release", in: app)
        expectExists(release, in: app)
        release.tap()
        expectExists(textContaining("放行后的正文", in: app), in: app)
        let backButton = element("BackButton", in: app)
        expectExists(backButton, in: app)
        backButton.tap()
        element("chat.new", in: app).tap()
        XCTAssertTrue(element("chat.modelMenu", in: app).label.contains("fixture-chat-alternate"))
        app.terminate()

        let reopened = launch(connected: true, arguments: args)
        selectTab("chat", title: "AI 对话", in: reopened)
        element("chat.new", in: reopened).tap()
        XCTAssertTrue(element("chat.modelMenu", in: reopened).label.contains("fixture-chat-alternate"))
        reopened.terminate()

        let removed = launch(connected: true, arguments: args + ["--ui-test-removed-model"])
        defer { removed.terminate() }
        selectTab("chat", title: "AI 对话", in: removed)
        let row = removed.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.conversation.")).firstMatch
        row.tap()
        expectExists(textContaining("原模型已不可用", in: removed), in: removed)
        element("chat.modelMenu", in: removed).tap()
        textContaining("刷新模型列表", in: removed).tap()
        element("chat.modelMenu", in: removed).tap()
        textContaining("fixture-chat-default", in: removed).tap()
        let next = element("chat.input", in: removed)
        next.tap()
        next.typeText("M4")
        tapChatSend(in: removed)
        expectExists(element("chat.stop", in: removed), in: removed)
    }

    @MainActor
    func testLegacyFixedModelSurvivesLaunch() {
        let args = ["--ui-test-chat-store=\(UUID().uuidString)", "--ui-test-chat-legacy"]
        let app = launch(connected: true, arguments: args)
        defer { app.terminate() }
        selectTab("chat", title: "AI 对话", in: app)
        element("chat.emptyNew", in: app).tap()
        XCTAssertTrue(element("chat.modelMenu", in: app).label.contains("fixture-chat-alternate"))
    }

    @MainActor
    func testChatReasoningPickerSelectsPersistsAndShowsFallbackNotice() {
        let args = [
            "--ui-test-chat-store=\(UUID().uuidString)",
            "--ui-test-chat-reasoning",
            "--ui-test-chat-reasoning-fallback",
            "--ui-test-theme=dark",
        ]
        let app = launch(connected: true, arguments: args)
        defer { app.terminate() }
        selectTab("chat", title: "AI 对话", in: app)
        element("chat.emptyNew", in: app).tap()

        let trigger = element("chat.reasoningTrigger", in: app)
        let input = element("chat.input", in: app)
        expectExists(trigger, in: app)
        expectExists(input, in: app)
        XCTAssertEqual(trigger.value as? String, "自动")
        let attachment = element("chat.attach", in: app)
        let send = element("chat.send", in: app)
        let composer = element("chat.composer", in: app)
        // Compact widths and narrow composers always stack the text field above the action bar
        // so the field never truncates or jumps between 1-row and 2-row layouts.
        let availableFieldWidth = send.frame.minX - trigger.frame.maxX - 8
        XCTAssertEqual(attachment.frame.midY, trigger.frame.midY, accuracy: 4)
        XCTAssertEqual(send.frame.midY, trigger.frame.midY, accuracy: 4)
        let expectsStacked = app.frame.width < 600 || availableFieldWidth < 218
        if expectsStacked {
            XCTAssertLessThanOrEqual(input.frame.maxY, trigger.frame.minY + 2)
        } else if availableFieldWidth >= 224 {
            XCTAssertEqual(trigger.frame.midY, input.frame.midY, accuracy: 4)
        }
        let initialComposerHeight = composer.frame.height
        let initialTriggerWidth = trigger.frame.width

        trigger.tap()
        let slider = element("chat.reasoningSlider", in: app)
        expectExists(slider, in: app)
        let highOption = element("chat.reasoningOption.high", in: app)
        expectExists(highOption, in: app)
        highOption.tap()
        let xhighOption = element("chat.reasoningOption.xhigh", in: app)
        expectExists(xhighOption, in: app)
        xhighOption.tap()
        let activeTitle = element("chat.reasoningActiveTitle", in: app)
        expectExists(activeTitle, in: app)
        expectPredicate(NSPredicate(format: "label == %@", "极高"), on: activeTitle, in: app,
                        message: "Selecting xhigh must update the popover header.",
                        finalCheck: { activeTitle.label == "极高" })
        attach(app, name: "chat-reasoning-popover-dark")

        element("chat.reasoningOption.max", in: app).tap()
        expectPredicate(NSPredicate(format: "label == %@", "最大"), on: activeTitle, in: app,
                        message: "Selecting max must update the popover header.",
                        finalCheck: { activeTitle.label == "最大" })
        if slider.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
            expectPredicate(NSPredicate(format: "exists == false"), on: slider, in: app,
                            message: "Tapping outside must dismiss the reasoning popover.",
                            finalCheck: { !slider.exists })
        }
        expectPredicate(NSPredicate(format: "value == %@", "最大"), on: trigger, in: app,
                        message: "Composer trigger must display the chosen max reasoning level.",
                        finalCheck: { trigger.value as? String == "最大" })
        // DISP-03: Changing between 1-char and 2-char level titles must not jump composer height or pill width.
        XCTAssertEqual(composer.frame.height, initialComposerHeight, accuracy: 2)
        XCTAssertEqual(trigger.frame.width, initialTriggerWidth, accuracy: 2)

        input.tap()
        input.typeText("测试思考等级")
        tapChatSend(in: app)
        expectExists(textContaining("已按思考等级「max」回复", in: app), in: app)
        let notice = element("chat.message.reasoningNotice", in: app)
        expectExists(notice, in: app)
        XCTAssertTrue(notice.label.contains("已按「高」发送"))

        // New conversation remembers `.max` for `fixture-chat-default`.
        let backButton = element("BackButton", in: app)
        expectExists(backButton, in: app)
        backButton.tap()
        element("chat.new", in: app).tap()
        expectExists(trigger, in: app)
        expectPredicate(NSPredicate(format: "value == %@", "最大"), on: trigger, in: app,
                        message: "A new conversation must recall the model's last reasoning effort.",
                        finalCheck: { trigger.value as? String == "最大" })

        // Switching to another model in an empty conversation adopts its own preference (`.automatic`).
        element("chat.modelMenu", in: app).tap()
        textContaining("fixture-chat-alternate", in: app).tap()
        expectPredicate(NSPredicate(format: "value == %@", "自动"), on: trigger, in: app,
                        message: "Switching to an unconfigured model in an empty conversation must default to automatic.",
                        finalCheck: { trigger.value as? String == "自动" })

        // Conversation options sync with the composer trigger.
        element("chat.options", in: app).tap()
        let offOption = element("chat.reasoningOption.off", in: app)
        if !offOption.isHittable { reveal(offOption, in: app) }
        offOption.tap()
        let done = app.buttons["完成"]
        done.tap()
        expectPredicate(NSPredicate(format: "exists == false"), on: done, in: app,
                        message: "Tapping Done must dismiss the conversation options sheet.",
                        finalCheck: { !done.exists })
        expectExists(trigger, in: app)
        expectPredicate(NSPredicate(format: "value == %@", "关闭"), on: trigger, in: app,
                        message: "Changing reasoning effort in conversation options must sync to the composer trigger.",
                        finalCheck: { trigger.value as? String == "关闭" })
    }

    @MainActor
    func testChatTranscriptStaysVisibleWhenSendingAgainWithKeyboardOpen() throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("The HTML preview buttons require WebKit file-panel cancellation.") }
        let app = launch(connected: true, arguments: [
            "--ui-test-chat-gate", "--ui-test-chat-html", "--ui-test-theme=dark",
            "--ui-test-chat-store=\(UUID().uuidString)"
        ])
        defer { app.terminate() }
        selectTab("chat", title: "AI 对话", in: app)
        element("chat.emptyNew", in: app).tap()

        let input = element("chat.input", in: app)
        let keyboard = app.keyboards.firstMatch
        let release = element("ui-test.chat.release", in: app)
        let reasoning = element("chat.reasoningTrigger", in: app)
        reasoning.tap()
        element("chat.reasoningOption.high", in: app).tap()
        if element("chat.reasoningSlider", in: app).exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        }
        XCTAssertEqual(reasoning.value as? String, "高")
        input.tap()
        expectExists(keyboard, in: app)
        input.typeText("Marc")
        tapChatSend(in: app)
        expectExists(release, in: app)
        let reasoningHeader = textContaining("思考过程", in: app)
        expectExists(reasoningHeader, in: app)
        if reasoningHeader.isHittable {
            reasoningHeader.tap()
            expectExists(app.staticTexts["可见推理片段"], in: app)
        }
        release.tap()
        expectExists(element("chat.html.snippet.2", in: app), in: app)
        let copy = app.buttons.matching(identifier: "doc.on.doc").firstMatch
        expectExists(copy, in: app)
        copy.tap()

        let composer = element("chat.composer", in: app)
        func transcriptViewport() -> CGRect {
            let top = app.navigationBars.firstMatch.frame.maxY
            return CGRect(x: composer.frame.minX, y: top, width: composer.frame.width,
                          height: max(0, composer.frame.minY - top))
        }

        let model = element("chat.modelMenu", in: app)
        model.tap()
        textContaining("fixture-chat-alternate", in: app).tap()
        XCTAssertTrue(model.label.contains("fixture-chat-alternate"))
        expectExists(keyboard, in: app)
        let firstPreview = element("chat.html.snippet.2", in: app)
        verify(transcriptViewport().contains(CGPoint(x: firstPreview.frame.midX, y: firstPreview.frame.midY)), in: app,
               "Switching models with the keyboard open must keep the transcript visible before typing.")
        input.typeText("Eir")
        tapChatSend(in: app)
        expectExists(release, in: app)
        let streamedCode = app.staticTexts["<p>Second fragment"].firstMatch
        expectExists(streamedCode, in: app)
        verify(transcriptViewport().contains(CGPoint(x: streamedCode.frame.midX, y: streamedCode.frame.midY)), in: app,
               "The incomplete HTML source must be visible while the second reply streams.")
        release.tap()
        expectExists(element("chat.send", in: app), in: app)
        expectExists(keyboard, in: app)
        let previews = app.buttons.matching(identifier: "chat.html.snippet.2")
        let latestPreview = previews.allElementsBoundByIndex.last
        let viewport = transcriptViewport()
        verify(latestPreview.map { viewport.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) } ?? false,
               in: app, "A completed reply must remain in the transcript viewport.")
    }

    @MainActor
    func testHTMLFallbackCopiesOriginalMixedFences() {
        let app = launch(connected: true, arguments: ["--ui-test-chat-gate", "--ui-test-chat-html", "--ui-test-chat-html-copy-check"])
        defer { app.terminate() }
        selectTab("chat", title: "AI 对话", in: app)
        element("chat.emptyNew", in: app).tap()
        let input = element("chat.input", in: app)
        input.tap()
        input.typeText("HTML")
        tapChatSend(in: app)
        element("ui-test.chat.release", in: app).tap()
        let copy = app.buttons.matching(identifier: "doc.on.doc").firstMatch
        reveal(copy, in: app)
        copy.tap()
        let check = element("ui-test.chat.checkCopy", in: app)
        check.tap()
        XCTAssertEqual(check.label, "完整源码一致")
        XCTAssertFalse(app.webViews.firstMatch.exists)
    }

    @MainActor
    func testHTMLPreviewKeepsSnapshotWhileConversationStreams() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("The static HTML preview requires WebKit file-panel cancellation.") }
        let gate = UUID().uuidString
        let name = "icu.nahida.cpaquota.html." + gate
        let released = expectation(description: "The fixture delivered the next chunk while the preview was open")
        var token: Int32 = 0
        XCTAssertEqual(notify_register_dispatch(name + ".released", &token, .main) { _ in released.fulfill() }, UInt32(NOTIFY_STATUS_OK))
        defer { notify_cancel(token) }
        let app = launch(connected: true, arguments: ["--ui-test-chat-gate", "--ui-test-chat-html", "--ui-test-chat-html-copy-check", "--ui-test-theme=light"],
                         environment: ["CPA_UI_HTML_GATE": gate])
        defer { app.terminate() }
        selectTab("chat", title: "AI 对话", in: app)
        element("chat.emptyNew", in: app).tap()
        let input = element("chat.input", in: app)
        input.tap()
        input.typeText("HTML")
        tapChatSend(in: app)
        let first = element("chat.html.snippet.1", in: app)
        let second = element("chat.html.snippet.2", in: app)
        reveal(first, in: app)
        XCTAssertFalse(second.exists)
        first.tap()
        let web = app.webViews.firstMatch
        let start = app.webViews.staticTexts["First fragment"].firstMatch
        let end = app.webViews.staticTexts["First fixture end"].firstMatch
        expectExists(start, in: app, timeout: htmlPreviewContentTimeout)
        web.swipeUp()
        let y = end.frame.midY
        XCTAssertTrue(web.frame.contains(CGPoint(x: end.frame.midX, y: y)))
        XCTAssertEqual(notify_post(name), UInt32(NOTIFY_STATUS_OK))
        let result = await XCTWaiter.fulfillment(of: [released], timeout: 10)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(end.frame.midY, y, accuracy: 5)
        XCTAssertFalse(app.webViews.staticTexts["Second fragment"].exists)
        app.buttons["源码"].tap()
        expectExists(textContaining("<p style=", in: app), in: app)
        app.buttons["刷新"].tap()
        expectExists(start, in: app, timeout: htmlPreviewContentTimeout)
        XCTAssertTrue(web.frame.contains(CGPoint(x: start.frame.midX, y: start.frame.minY + 2)))
        let closePreview = app.buttons["关闭"]
        closePreview.tap()
        expectPredicate(NSPredicate(format: "exists == false"), on: closePreview, in: app,
                        message: "Closing the first HTML preview must dismiss the sheet.",
                        finalCheck: { !closePreview.exists })
        reveal(second, in: app)
        XCTAssertFalse(element("chat.html.snippet.3", in: app).exists)
        second.tap()
        let secondFragment = web.staticTexts["Second fragment"].firstMatch
        expectExists(secondFragment, in: app, timeout: htmlPreviewContentTimeout)
        XCTAssertFalse(web.staticTexts["First fragment"].exists)
        app.buttons["源码"].tap()
        app.buttons["复制源码"].tap()
        closePreview.tap()
        expectPredicate(NSPredicate(format: "exists == false"), on: closePreview, in: app,
                        message: "Closing the second HTML preview must dismiss the sheet.",
                        finalCheck: { !closePreview.exists })
        let check = element("ui-test.chat.checkCopy", in: app)
        check.tap()
        XCTAssertEqual(check.label, "片段源码一致")
        expectExists(input, in: app)
        XCTAssertFalse(element("chat.stop", in: app).exists)
    }

    @MainActor
    func testHTMLPreviewRotatesWithLargeTextInDarkAppearance() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("The static HTML preview requires WebKit file-panel cancellation.") }
        let app = launch(connected: true, largeText: true,
                         arguments: ["--ui-test-chat-gate", "--ui-test-chat-html", "--ui-test-theme=dark"])
        defer {
            XCUIDevice.shared.orientation = .portrait
            if app.state != .notRunning {
                app.terminate()
            }
        }
        selectTab("chat", title: "AI 对话", in: app)
        element("chat.new", in: app).tap()
        let input = element("chat.input", in: app)
        input.tap()
        input.typeText("HTML")
        tapChatSend(in: app)
        element("ui-test.chat.release", in: app).tap()
        let second = element("chat.html.snippet.2", in: app)
        reveal(second, in: app, upward: false)
        second.tap()
        let secondFragment = app.webViews.staticTexts["Second fragment"].firstMatch
        expectExists(secondFragment, in: app, timeout: htmlPreviewContentTimeout)
        _ = await rotateDeviceAndWaitForWindow(in: app, policy: layoutPolicy(in: app))
        app.buttons["源码"].tap()
        expectExists(textContaining("<p>Second fragment</p>", in: app), in: app)
        app.buttons["预览"].tap()
        expectExists(secondFragment, in: app, timeout: htmlPreviewContentTimeout)
        attach(app, name: "html-preview-dark-landscape")
        app.buttons["关闭"].tap()
        let web = app.webViews.firstMatch
        expectPredicate(NSPredicate(format: "exists == false"), on: web, in: app,
                        message: "Closing the HTML preview must dismiss the WebView sheet.",
                        finalCheck: { !web.exists })
        expectExists(input, in: app)
    }

    @MainActor
    private func textContaining(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, upward: Bool = true,
                        requiresHitTarget: Bool = true,
                        file: StaticString = #filePath, line: UInt = #line) {
        // Inspect after every gesture, including the final one. Once a lazy
        // target exists, move toward its center instead of blindly sweeping.
        for attempt in 0...30 {
            let context = geometry(in: app, scrollingTo: element)
            let snap: (any XCUIElementSnapshot)? = element.exists ? (try? element.snapshot()) : nil
            let exists = snap != nil
            let frame = snap?.frame ?? .null
            let hittable = exists && element.isHittable
            if let snap {
                if hasVisibleTapCenter(snapshot: snap, hittable: hittable, context: context) { return }
                if isVisible(frame, viewport: context.viewport) && (!requiresHitTarget || !snap.isEnabled) { return }
            }
            guard attempt < 30 else { break }
            var direction = attempt < 15 ? upward : !upward
            if !frame.isEmpty, !frame.isNull, let viewport = context.viewport {
                if frame.midY < viewport.midY { direction = false }
                else if frame.midY > viewport.midY { direction = true }
            }
            scrollContent(upward: direction, target: element, targetFrame: frame,
                          targetHittable: hittable, context: context, in: app, file: file, line: line)
        }
        attachDiagnostics(app, name: "unreachable-control")
        XCTFail("Expected control must remain reachable by scrolling.", file: file, line: line)
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String, app: XCUIApplication,
                             file: StaticString = #filePath, line: UInt = #line) {
        field.tap()
        let previous = field.value as? String ?? ""
        if !previous.isEmpty, previous != field.placeholderValue {
            // A center tap places the caret inside an existing URL. Backspacing
            // its character count from that position leaves a suffix behind.
            // These one-line fixture values fit the field: tapping its trailing
            // edge first places the insertion point after the complete value.
            // This also works for SecureField without exposing the credential.
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
            let placeholder = field.placeholderValue ?? ""
            let started = Date()
            let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == nil OR value == '' OR value == %@", placeholder),
                object: field)], timeout: 5)
            let elapsed = Date().timeIntervalSince(started)
            let current = field.value
            let currentString = current as? String
            let empty = currentString?.isEmpty ?? false
            let isPlaceholder = currentString.map { $0 == placeholder } ?? false
            let cleared = current == nil || empty || isPlaceholder
            print("FRONTEND_CLEAR_WAIT line=\(line) result=\(result) elapsed=\(elapsed) length=\(currentString?.count ?? -1) nil=\(current == nil) empty=\(empty) placeholder=\(isPlaceholder)")
            verify(cleared, in: app,
                   "The field must clear before replacement (length=\(currentString?.count ?? -1), nil=\(current == nil), empty=\(empty), placeholder=\(isPlaceholder)).",
                   file: file, line: line)
        }
        field.typeText(text)
        if field.elementType == .textField {
            expectPredicate(NSPredicate(format: "value == %@", text), on: field, in: app,
                            message: "The address field must contain exactly the entered fixture URL.",
                            finalCheck: { field.value as? String == text }, file: file, line: line)
        }
    }

    @MainActor
    private func nativeTab(_ id: String, title: String, in app: XCUIApplication) -> XCUIElement {
        let byIdentifier = app.buttons.matching(identifier: "tab.\(id)").firstMatch
        return byIdentifier.exists ? byIdentifier : app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    @MainActor
    private func selectTab(_ id: String, title: String, in app: XCUIApplication,
                           file: StaticString = #filePath, line: UInt = #line) {
        let tab = nativeTab(id, title: title, in: app)
        expectExists(tab, in: app, timeout: 5, file: file, line: line)
        verify(tab.isHittable, in: app, "The native destination \(title) must be tappable.", file: file, line: line)
        tab.tap()
        expectExists(element("workspace.\(id)", in: app), in: app, timeout: 5, file: file, line: line)
        verify(tab.isSelected, in: app, "The native destination \(title) must report its selected state.", file: file, line: line)
    }

    @MainActor
    private func chooseAppearance(_ title: String, picker: XCUIElement, in app: XCUIApplication) {
        reveal(picker, in: app, upward: false)
        picker.tap()
        let option = app.buttons[title]
        expectExists(option, in: app, timeout: 5)
        option.tap()
        verify(picker.value as? String == title, in: app, "The appearance picker must retain the selected option \(title).")
    }

    private struct GeometryContext {
        let appFrame: CGRect
        let bars: [XCUIElement]
        let container: XCUIElement?
        let containerFrame: CGRect
        let viewport: CGRect?
    }

    /// Capture geometry once per attempt, then refresh it after each gesture.
    /// Uses atomic `snapshot()` calls so transient elements (such as a dismissing
    /// sheet's navigation bar) never trigger fatal indexed-snapshot errors.
    @MainActor
    private func geometry(in app: XCUIApplication, scrollingTo target: XCUIElement? = nil) -> GeometryContext {
        let appFrame = app.frame
        let navBarEntries: [(element: XCUIElement, frame: CGRect)] =
            app.navigationBars.allElementsBoundByIndex.compactMap { bar in
                guard let snap = try? bar.snapshot() else { return nil }
                return (bar, snap.frame.intersection(appFrame))
            }
        let tabBarEntries: [(element: XCUIElement, frame: CGRect)] =
            app.tabBars.allElementsBoundByIndex.compactMap { bar in
                guard let snap = try? bar.snapshot() else { return nil }
                return (bar, snap.frame.intersection(appFrame))
            }
        let navBars = navBarEntries.map(\.element)
        let tabBars = tabBarEntries.map(\.element)
        let navFrames = navBarEntries.map(\.frame)
        let tabFrames = tabBarEntries.map(\.frame)
        let keyboard = app.keyboards.firstMatch
        let keyboardFrame: CGRect? = keyboard.exists ? (try? keyboard.snapshot())?.frame : nil
        let containers = app.collectionViews.allElementsBoundByIndex
            + app.tables.allElementsBoundByIndex + app.scrollViews.allElementsBoundByIndex
        let candidates: [(element: XCUIElement, identifier: String, frame: CGRect, viewport: CGRect)] = containers.compactMap { container in
            guard let snap = try? container.snapshot() else { return nil }
            let frame = snap.frame
            let viewport = visibleContentFrame(frame, appFrame: appFrame, navFrames: navFrames,
                                               tabFrames: tabFrames, keyboardFrame: keyboardFrame)
            guard !viewport.isNull, viewport.width > 44, viewport.height > 80 else { return nil }
            return (container, snap.identifier, frame, viewport)
        }
        let detailForms = candidates.filter { $0.identifier == "quota.detail.form" }
        let selected = (detailForms.isEmpty ? candidates : detailForms).max {
            $0.viewport.width * $0.viewport.height < $1.viewport.width * $1.viewport.height
        }
        var viewport = selected?.viewport
        let composerIDs: Set<String> = [
            "chat.composer", "chat.input", "chat.send", "chat.stop",
            "chat.continue", "chat.retry", "chat.attach", "chat.webSearch", "chat.searchUnavailable"
        ]
        let isComposerTarget = target.flatMap { $0.exists ? (try? $0.snapshot()) : nil }
            .map { composerIDs.contains($0.identifier) } ?? false
        if !isComposerTarget, var visibleViewport = viewport {
            let chatInput = app.textFields.matching(identifier: "chat.input").firstMatch
            if chatInput.exists, let inputSnap = try? chatInput.snapshot() {
                let composer = element("chat.composer", in: app)
                let composerSnap = composer.exists ? (try? composer.snapshot()) : nil
                let composerTop: CGFloat
                if let composerSnap, !composerSnap.frame.isEmpty {
                    composerTop = min(composerSnap.frame.minY, inputSnap.frame.minY)
                } else {
                    composerTop = inputSnap.frame.minY
                }
                if composerTop - visibleViewport.minY > 80, composerTop < visibleViewport.maxY {
                    visibleViewport.size.height = composerTop - visibleViewport.minY
                    viewport = visibleViewport
                }
            }
        }
        return GeometryContext(appFrame: appFrame, bars: navBars + tabBars,
                               container: selected?.element, containerFrame: selected?.frame ?? .null,
                               viewport: viewport)
    }

    private func visibleContentFrame(_ frame: CGRect, appFrame: CGRect, navFrames: [CGRect],
                                     tabFrames: [CGRect], keyboardFrame: CGRect?) -> CGRect {
        var viewport = frame.intersection(appFrame)
        for bar in navFrames where bar.intersects(viewport) && bar.midY < viewport.midY {
            let top = max(viewport.minY, bar.maxY)
            viewport = CGRect(x: viewport.minX, y: top, width: viewport.width,
                              height: max(0, viewport.maxY - top))
        }
        for bar in tabFrames where bar.intersects(viewport) && bar.midY > viewport.midY {
            viewport.size.height = max(0, min(viewport.maxY, bar.minY) - viewport.minY)
        }
        if let keyboardFrame, keyboardFrame.intersects(viewport), keyboardFrame.minY > viewport.minY {
            viewport.size.height = min(viewport.maxY, keyboardFrame.minY) - viewport.minY
        }
        return viewport
    }

    /// Hittable alone can include a stale rotation frame or content beneath
    /// system bars. Keep genuine toolbar buttons reachable in their own bars.
    @MainActor
    private func hasVisibleTapCenter(snapshot: any XCUIElementSnapshot, hittable: Bool,
                                     context: GeometryContext) -> Bool {
        let frame = snapshot.frame
        guard hittable, !frame.isEmpty, !frame.isNull else { return false }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard context.appFrame.contains(center) else { return false }
        let identifier = snapshot.identifier
        let label = snapshot.label
        for bar in context.bars {
            let buttons = bar.buttons
            let match = identifier.isEmpty
                ? buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
                : buttons.matching(identifier: identifier).matching(NSPredicate(format: "label == %@", label)).firstMatch
            if match.exists, let matchSnap = try? match.snapshot(), matchSnap.frame == frame { return true }
        }
        guard let viewport = context.viewport else { return false }
        return viewport.contains(center) && isVisible(frame, viewport: viewport)
    }

    private func isVisible(_ frame: CGRect, viewport: CGRect?) -> Bool {
        guard !frame.isEmpty, !frame.isNull, let viewport else { return false }
        let visible = frame.intersection(viewport)
        guard !visible.isEmpty, !visible.isNull else { return false }
        return visible.width >= min(frame.width, 44)
            && visible.height >= min(frame.height, 44)
    }

    @MainActor
    private func scrollContent(upward: Bool, target: XCUIElement, targetFrame: CGRect,
                               targetHittable: Bool, context: GeometryContext, in app: XCUIApplication,
                               file: StaticString, line: UInt) {
        guard let container = context.container, let viewport = context.viewport else {
            attachDiagnostics(app, name: "missing-scroll-container")
            XCTFail("A reachable native List/Form scroll container is required.", file: file, line: line)
            return
        }
        guard viewport.width > 44, viewport.height > 80 else {
            attachDiagnostics(app, name: "obscured-scroll-container")
            XCTFail("The native content viewport must remain usable above the keyboard.", file: file, line: line)
            return
        }
        let anchor = container.cells.firstMatch
        let before = anchor.exists
            ? ((try? anchor.snapshot()).flatMap { $0.frame.isEmpty ? nil : $0.frame } ?? .null)
            : .null
        let hasAnchor = !before.isNull
        let preferredX = hasAnchor ? before.minX + 4 : viewport.midX
        let x = min(max(preferredX, viewport.minX + 8), viewport.maxX - 8) - context.containerFrame.minX
        let targetDistance = targetFrame.isEmpty || targetFrame.isNull
            ? nil
            : abs(targetFrame.midY - viewport.midY)
        let usesPreciseScroll = targetDistance.map { $0 < max(viewport.height * 2, 240) } ?? false
        let dragDistance = usesPreciseScroll
            ? min(viewport.height * 0.45, max(28, (targetDistance ?? 0) * 0.6))
            : viewport.height * 0.25
        let centerY = viewport.minY + viewport.height * 0.35
        let top = centerY - dragDistance / 2 - context.containerFrame.minY
        let bottom = centerY + dragDistance / 2 - context.containerFrame.minY
        let origin = container.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: x, dy: upward ? bottom : top))
        let end = origin.withOffset(CGVector(dx: x, dy: upward ? top : bottom))
        if usesPreciseScroll {
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.15)
        } else {
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        let after = anchor.exists ? ((try? anchor.snapshot())?.frame ?? .null) : .null
        let afterSnap: (any XCUIElementSnapshot)? = target.exists ? (try? target.snapshot()) : nil
        let afterFrame = afterSnap?.frame ?? .null
        let afterHittable = afterSnap != nil && target.isHittable
        print("FRONTEND_SCROLL line=\(line) upward=\(upward) viewport=\(viewport) anchorBefore=\(before) anchorAfter=\(after) targetBefore=\(targetFrame) hittableBefore=\(targetHittable) targetAfter=\(afterFrame) hittableAfter=\(afterHittable)")
    }

    @MainActor
    private func tapChatSend(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        // Wait for the composer to enable Send after the keyboard delivers the draft.
        let send = app.buttons["chat.send"]
        expectPredicate(NSPredicate(format: "exists == true AND enabled == true"),
                        on: send, in: app, message: "Send must be enabled after typing.",
                        finalCheck: { send.exists && send.isEnabled }, file: file, line: line)
        // XCUITest can report an invalid activation point during the keyboard
        // transition. Use the center of the actual button for one tap.
        let button = send.frame
        let center = CGPoint(x: button.midX, y: button.midY)
        let window = app.frame
        verify(!button.isEmpty && window.contains(center), in: app,
               "Send must be within the app window.", file: file, line: line)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: center.x - window.minX, dy: center.y - window.minY)).tap()
    }

    @MainActor
    private func expectPredicate(_ predicate: NSPredicate, on element: XCUIElement,
                                 in app: XCUIApplication, message: String,
                                 finalCheck: @MainActor () -> Bool,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let started = Date()
        let result = XCTWaiter.wait(for: [expectation], timeout: 5)
        let elapsed = Date().timeIntervalSince(started)
        let condition = finalCheck()
        print("FRONTEND_PREDICATE_WAIT line=\(line) result=\(result) elapsed=\(elapsed) final=\(condition)")
        verify(condition, in: app, message, file: file, line: line)
    }

    @MainActor
    private func expectExists(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 10,
                              file: StaticString = #filePath, line: UInt = #line) {
        // Already-present controls need no polling round trip to the snapshot
        // service. Keep the same bounded wait for genuinely pending elements.
        let exists = element.exists || element.waitForExistence(timeout: timeout)
        verify(exists, in: app, "Expected element must exist.", file: file, line: line)
    }

    @MainActor
    private func verify(_ condition: Bool, in app: XCUIApplication, _ message: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        if !condition { attachDiagnostics(app, name: "assertion-failure") }
        XCTAssertTrue(condition, message, file: file, line: line)
    }

    @MainActor
    private func attachDiagnostics(_ app: XCUIApplication, name: String) {
        attach(app, name: name)
        let hierarchy = app.debugDescription
        let attachment = XCTAttachment(string: hierarchy)
        attachment.name = "\(name)-accessibility-hierarchy"
        attachment.lifetime = .keepAlways
        add(attachment)
        // CI artifact quota can prevent an xcresult upload. Keep the same
        // isolated-fixture hierarchy in the job log so failures remain diagnosable.
        print("FRONTEND_UI_FAILURE_HIERARCHY_BEGIN \(name)\n\(hierarchy)\nFRONTEND_UI_FAILURE_HIERARCHY_END")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        // Capture the complete display. Element screenshots can crop against
        // the application's rotated bounds and lose landscape content.
        let screenshot = XCUIScreen.main.screenshot()
        let image = screenshot.image
        print("FRONTEND_SCREENSHOT \(name) size=\(image.size.width)x\(image.size.height) scale=\(image.scale) orientation=\(image.imageOrientation.rawValue)")
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Sample the outer canvas beside inset Form rows. Wide thresholds verify
    /// light/dark behavior without pretending to be a complete pixel baseline.
    @MainActor
    private func canvasBrightness(_ image: UIImage) throws -> Double {
        let cgImage = try XCTUnwrap(image.cgImage)
        let sample = CGRect(x: 3 * image.scale, y: CGFloat(cgImage.height) * 0.5, width: 1, height: 1)
        let cropped = try XCTUnwrap(cgImage.cropping(to: sample))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        XCTAssertTrue(rendered)
        return (Double(bytes[0]) * 0.2126 + Double(bytes[1]) * 0.7152 + Double(bytes[2]) * 0.0722) / 255
    }
}
