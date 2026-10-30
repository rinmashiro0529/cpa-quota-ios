import XCTest
import UIKit

/// Runs against the real app UI and production parsers using Debug-only local
/// transport fixtures. Screenshots accompany assertions; they are not treated
/// as proof of a pass by themselves.
final class CPAQuotaAppUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLoginValidatesHTTPSAndRejectsManagement401BeforeConnecting() {
        let app = launch(connected: false)
        defer { app.terminate() }
        let address = element("connection.server", in: app)
        let key = element("connection.key", in: app)
        let submit = element("connection.submit", in: app)
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
        verify(!element("quota.displayMode", in: app).exists, in: app,
               "A management 401 must not open the quota workspace.")
        attach(app, name: "login-management-401")

        reveal(key, in: app, upward: false)
        replaceText(in: key, with: "ui-test-valid-key", app: app)
        reveal(submit, in: app)
        submit.tap()
        let account = element("quota.account.ui-main", in: app)
        expectExists(element("quota.displayMode", in: app), in: app, timeout: 15)
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
    func testFiveNativeTabsAndQuotaDetailKeepTheirSystemNavigation() {
        let app = launch(connected: true)
        defer { app.terminate() }
        let tabs = [
            ("quotas", "额度总览"), ("usage", "CAP用量"),
            ("monitoring", "监控与活动"), ("accounts", "账号诊断"),
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
        app.buttons["完成"].tap()
        expectExists(account, in: app, timeout: 5)
        verify(!app.navigationBars["账号详情"].exists, in: app,
               "Done must dismiss the native account sheet.")
    }

    @MainActor
    func testCAPAllFourSectionsReadParsedFixtures() {
        let app = launch(connected: true)
        defer { app.terminate() }
        selectTab("usage", title: "CAP用量", in: app)
        let sections = [
            ("近30m模型概览", "cap.loadOverview", "cap.overview.loaded"),
            ("趋势·分组·费用", "cap.loadAnalytics", "cap.analytics.loaded"),
            ("请求明细页", "cap.loadRequests", "cap.requests.loaded"),
            ("管理统计对比", "cap.loadManagement", "cap.management.loaded")
        ]
        for (title, loadID, loadedID) in sections {
            let picker = element("cap.sectionPicker", in: app)
            reveal(picker, in: app, upward: false)
            picker.tap()
            let option = app.buttons[title]
            expectExists(option, in: app, timeout: 5)
            option.tap()
            let load = element(loadID, in: app)
            reveal(load, in: app)
            verify(load.isEnabled, in: app, "The selected CAP section must be loadable.")
            load.tap()
            let loaded = loadedID == "cap.overview.loaded"
                ? app.staticTexts[loadedID]
                : element(loadedID, in: app)
            reveal(loaded, in: app, requiresHitTarget: loadedID == "cap.analytics.loaded")
            verify(loaded.exists, in: app, "Parsed content must replace the empty state for \(title).")
            if loadedID == "cap.overview.loaded" {
                verify(loaded.label.contains("singlePage"), in: app,
                       "The overview must display the fixture's complete single-page result.")
            }
            attach(app, name: loadedID)
        }
    }

    @MainActor
    func testUnconfiguredMonitoringRequiresSeparateCredentials() {
        let app = launch(connected: true)
        defer { app.terminate() }
        selectTab("monitoring", title: "监控与活动", in: app)
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
    private func launch(connected: Bool, largeText: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", connected ? "--fixture=connected" : "--fixture=unconfigured"]
        if largeText { app.launchArguments.append("--ui-test-large-text") }
        app.launch()
        verify(app.wait(for: .runningForeground, timeout: 10), in: app, "The fixture app must launch in the foreground.")
        verify(!element("ui-test.preparationFailed", in: app).exists, in: app, "Fixture preparation must succeed.")
        if connected {
            // A List does not create every offscreen row. In accessibility5 the
            // first account starts below the fold; waiting for it without
            // scrolling incorrectly treats native lazy loading as a failure.
            expectExists(element("quota.displayMode", in: app), in: app, timeout: 15)
            reveal(element("quota.account.ui-main", in: app), in: app)
        } else {
            expectExists(element("connection.server", in: app), in: app, timeout: 15)
        }
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
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
        // A rotation or a restored scroll position may place the target on
        // either side of the viewport. Try the expected direction, then recover.
        for direction in [upward, !upward] {
            for _ in 0..<10 {
                if element.exists {
                    if element.isHittable { return }
                    if (!requiresHitTarget || !element.isEnabled), isVisible(element, in: app) { return }
                }
                scrollContent(upward: direction, in: app, file: file, line: line)
            }
        }
        attachDiagnostics(app, name: "unreachable-control")
        XCTFail("Expected control must remain reachable by scrolling: \(element.identifier)", file: file, line: line)
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
            let cleared = field.value as? String ?? ""
            verify(cleared.isEmpty || cleared == field.placeholderValue, in: app,
                   "The existing field value must be cleared before replacement: \(field.identifier).",
                   file: file, line: line)
        }
        field.typeText(text)
        if field.elementType == .textField {
            verify(field.value as? String == text, in: app,
                   "The address field must contain exactly the entered fixture URL.", file: file, line: line)
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

    /// Use the actual visible List/Form viewport. A full-app swipe can start on
    /// a system side rail or the keyboard instead of scrolling app content.
    @MainActor
    private func contentContainer(in app: XCUIApplication) -> XCUIElement? {
        let containers = app.collectionViews.allElementsBoundByIndex
            + app.tables.allElementsBoundByIndex
            + app.scrollViews.allElementsBoundByIndex
        let visibleContainers = containers
            .filter {
                guard $0.exists else { return false }
                // UIKit can report the CollectionView itself as non-hittable
                // while its visible rows remain interactive and scrollable.
                // This occurs with the keyboard and with iOS 27's side rail.
                // Select the actual viewport; hit testing belongs to the final
                // button assertion, not to this noninteractive container.
                let viewport = visibleContentFrame($0, in: app)
                return !viewport.isNull && viewport.width > 44 && viewport.height > 80
            }
        // A presented form can be smaller than the still-visible tab content.
        // Its stable screen identity prevents scrolling the background list
        // while seeking a lazily-created accessibility-size detail row.
        let detailForms = visibleContainers.filter { $0.identifier == "quota.detail.form" }
        return (detailForms.isEmpty ? visibleContainers : detailForms)
            .max { left, right in
                let lhs = visibleContentFrame(left, in: app)
                let rhs = visibleContentFrame(right, in: app)
                return lhs.width * lhs.height < rhs.width * rhs.height
            }
    }

    @MainActor
    private func visibleContentFrame(_ container: XCUIElement, in app: XCUIApplication) -> CGRect {
        var viewport = container.frame.intersection(app.frame)
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists, keyboard.frame.intersects(viewport), keyboard.frame.minY > viewport.minY {
            viewport.size.height = min(viewport.maxY, keyboard.frame.minY) - viewport.minY
        }
        return viewport
    }

    @MainActor
    private func isVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard !element.frame.isEmpty, let container = contentContainer(in: app) else { return false }
        let viewport = visibleContentFrame(container, in: app)
        let visible = element.frame.intersection(viewport)
        guard !visible.isEmpty, !visible.isNull else { return false }
        // Static text and disabled controls still need to be in the viewport;
        // an offscreen accessibility record alone cannot satisfy this check.
        return visible.width >= min(element.frame.width, 44)
            && visible.height >= min(element.frame.height, 44)
    }

    @MainActor
    private func scrollContent(upward: Bool, in app: XCUIApplication,
                               file: StaticString, line: UInt) {
        guard let container = contentContainer(in: app) else {
            attachDiagnostics(app, name: "missing-scroll-container")
            XCTFail("A reachable native List/Form scroll container is required.", file: file, line: line)
            return
        }
        let viewport = visibleContentFrame(container, in: app)
        guard viewport.width > 44, viewport.height > 80 else {
            attachDiagnostics(app, name: "obscured-scroll-container")
            XCTFail("The native content viewport must remain usable above the keyboard.", file: file, line: line)
            return
        }
        let x = viewport.midX - container.frame.minX
        let top = viewport.minY + viewport.height * 0.25 - container.frame.minY
        let bottom = viewport.minY + viewport.height * 0.75 - container.frame.minY
        let origin = container.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: x, dy: upward ? bottom : top))
        let end = origin.withOffset(CGVector(dx: x, dy: upward ? top : bottom))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func expectExists(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 10,
                              file: StaticString = #filePath, line: UInt = #line) {
        verify(element.waitForExistence(timeout: timeout), in: app,
               "Expected element must exist: \(element.identifier).", file: file, line: line)
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
