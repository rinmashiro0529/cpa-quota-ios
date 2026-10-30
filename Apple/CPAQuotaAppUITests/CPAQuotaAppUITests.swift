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
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        reveal(submit, in: app)
        XCTAssertFalse(submit.isEnabled, "An empty connection must not be submitted.")

        reveal(address, in: app, upward: false)
        replaceText(in: address, with: "http://ui-test.invalid")
        reveal(key, in: app)
        replaceText(in: key, with: "ui-test-valid-key")
        reveal(submit, in: app)
        submit.tap()
        let invalidServer = textContaining("服务地址格式无效", in: app)
        XCTAssertTrue(invalidServer.waitForExistence(timeout: 10))
        reveal(invalidServer, in: app)
        attach(app, name: "login-invalid-https")

        reveal(address, in: app, upward: false)
        replaceText(in: address, with: "https://ui-test.invalid")
        reveal(key, in: app)
        replaceText(in: key, with: "ui-test-invalid-key")
        reveal(submit, in: app)
        submit.tap()
        let unauthorized = textContaining("CPA 管理密钥鉴权失败", in: app)
        XCTAssertTrue(unauthorized.waitForExistence(timeout: 10))
        reveal(unauthorized, in: app)
        XCTAssertFalse(element("quota.account.ui-main", in: app).exists)
        attach(app, name: "login-management-401")

        reveal(key, in: app, upward: false)
        replaceText(in: key, with: "ui-test-valid-key")
        reveal(submit, in: app)
        submit.tap()
        let account = element("quota.account.ui-main", in: app)
        XCTAssertTrue(account.waitForExistence(timeout: 15))
        reveal(account, in: app)
        XCTAssertTrue(app.tabBars.firstMatch.exists)
        XCTAssertTrue(textContaining("42% 剩余", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(textContaining("native@example.com", in: app).exists,
                       "The default masking preference must apply to accessible text.")
        attach(app, name: "login-connected-quota")
    }

    @MainActor
    func testFiveNativeTabsAndQuotaDetailKeepTheirSystemNavigation() {
        let app = launch(connected: true)
        defer { app.terminate() }
        XCTAssertEqual(app.tabBars.firstMatch.buttons.count, 5)
        let tabs = [
            ("quotas", "额度总览"), ("usage", "CAP用量"),
            ("monitoring", "监控与活动"), ("accounts", "账号诊断"),
            ("connection", "连接管理")
        ]
        for (id, title) in tabs {
            selectTab(id, title: title, in: app)
            XCTAssertTrue(element("workspace.\(id)", in: app).waitForExistence(timeout: 5))
            XCTAssertTrue(app.navigationBars.firstMatch.exists)
            attach(app, name: "tab-\(id)")
        }

        selectTab("quotas", title: "额度总览", in: app)
        let account = element("quota.account.ui-main", in: app)
        reveal(account, in: app)
        account.tap()
        XCTAssertTrue(app.navigationBars["账号详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("quota.account.refresh", in: app).exists)
        let remaining = textContaining("42% 剩余", in: app)
        reveal(remaining, in: app)
        XCTAssertTrue(remaining.exists)
        attach(app, name: "quota-detail-multiple-windows")
        app.navigationBars.buttons["完成"].tap()
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["账号详情"].exists)
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
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.tap()
            let load = element(loadID, in: app)
            reveal(load, in: app)
            XCTAssertTrue(load.isEnabled)
            load.tap()
            let loaded = element(loadedID, in: app)
            XCTAssertTrue(loaded.waitForExistence(timeout: 15), "Parsed content must replace the empty state for \(title).")
            reveal(loaded, in: app)
            attach(app, name: loadedID)
        }
    }

    @MainActor
    func testUnconfiguredMonitoringRequiresSeparateCredentials() {
        let app = launch(connected: true)
        defer { app.terminate() }
        selectTab("monitoring", title: "监控与活动", in: app)
        let unconfigured = element("monitoring.unconfigured", in: app)
        XCTAssertTrue(unconfigured.waitForExistence(timeout: 5))
        let connectLink = app.buttons["连接监控服务"]
        reveal(connectLink, in: app)
        connectLink.tap()
        let address = element("monitor.bridgeAddress", in: app)
        let token = element("monitor.bridgeToken", in: app)
        let connect = element("monitor.connect", in: app)
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        XCTAssertTrue(token.exists)
        reveal(connect, in: app)
        XCTAssertFalse(connect.isEnabled, "A CPA connection must not act as monitoring bridge credentials.")
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
        XCTAssertGreaterThan(light, 0.65, "The light setting must render a light content canvas.")
        attach(app, name: "settings-light")

        chooseAppearance("深色曜石", picker: appearance, in: app)
        let dark = try canvasBrightness(app.screenshot().image)
        XCTAssertLessThan(dark, 0.25, "The dark setting must render a dark content canvas.")
        XCTAssertGreaterThan(light - dark, 0.45)
        attach(app, name: "settings-dark")

        let sharing = app.switches["settings.widgetSharing"]
        reveal(sharing, in: app)
        XCTAssertEqual(sharing.value as? String, "0", "Sharing quota with widgets requires an explicit opt-in.")
        let masking = app.switches["settings.maskEmail"]
        XCTAssertEqual(masking.value as? String, "1")
    }

    @MainActor
    func testLargestDynamicTypeAndLandscapePreservePrimaryActions() {
        let normal = launch(connected: true)
        let normalAccount = element("quota.account.ui-main", in: normal)
        reveal(normalAccount, in: normal)
        let normalHeight = normalAccount.frame.height
        XCTAssertGreaterThanOrEqual(normalHeight, 44)
        normal.terminate()

        let app = launch(connected: true, largeText: true)
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }
        let account = element("quota.account.ui-main", in: app)
        reveal(account, in: app)
        XCTAssertGreaterThan(account.frame.height, normalHeight,
                             "Largest Dynamic Type must change actual text layout, not only the screenshot name.")
        XCTAssertTrue(account.isHittable)
        attach(app, name: "quota-accessibility5-portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        reveal(account, in: app, upward: false)
        XCTAssertTrue(account.isHittable)
        account.tap()
        let close = app.navigationBars.buttons["完成"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(close.isHittable)
        XCTAssertTrue(element("quota.account.refresh", in: app).isHittable)
        attach(app, name: "quota-detail-accessibility5-landscape")
        close.tap()

        selectTab("connection", title: "连接管理", in: app)
        let masking = app.switches["settings.maskEmail"]
        reveal(masking, in: app)
        XCTAssertTrue(masking.isHittable)
        XCTAssertGreaterThanOrEqual(masking.frame.height, 44)
        attach(app, name: "settings-accessibility5-landscape")
    }

    @MainActor
    private func launch(connected: Bool, largeText: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", connected ? "--fixture=connected" : "--fixture=unconfigured"]
        if largeText { app.launchArguments.append("--ui-test-large-text") }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertFalse(element("ui-test.preparationFailed", in: app).exists)
        if connected {
            XCTAssertTrue(element("quota.account.ui-main", in: app).waitForExistence(timeout: 15))
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
                        file: StaticString = #filePath, line: UInt = #line) {
        // A rotation or a restored scroll position may place the target on
        // either side of the viewport. Try the expected direction, then recover.
        for direction in [upward, !upward] {
            for _ in 0..<8 {
                if element.exists {
                    if element.isHittable { return }
                    if !element.isEnabled && !element.frame.isEmpty && app.frame.contains(element.frame) { return }
                }
                if direction { app.swipeUp() } else { app.swipeDown() }
            }
        }
        attach(app, name: "unreachable-control")
        XCTFail("Expected control must remain reachable by scrolling: \(element.identifier)", file: file, line: line)
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        let current = field.value as? String ?? ""
        if !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }

    @MainActor
    private func selectTab(_ id: String, title: String, in app: XCUIApplication) {
        let byIdentifier = app.tabBars.buttons.matching(identifier: "tab.\(id)").firstMatch
        let tab = byIdentifier.exists ? byIdentifier : app.tabBars.buttons[title]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
        XCTAssertTrue(tab.isSelected)
    }

    @MainActor
    private func chooseAppearance(_ title: String, picker: XCUIElement, in app: XCUIApplication) {
        reveal(picker, in: app, upward: false)
        picker.tap()
        let option = app.buttons[title]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        XCTAssertEqual(picker.value as? String, title)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
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
