/*
 * tako — Native desktop design interaction fixtures
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import XCTest

@MainActor
class TakoDesktopDesignCase: TakoFloatingTerminalCase {
    let designDirectory = URL(fileURLWithPath: "/private/tmp/tkui")
        .appendingPathComponent("desktop-\(UUID().uuidString)")

    var designConfig: URL { designDirectory.appendingPathComponent("config") }
    var beforeDesktopLaunch: ((XCUIApplication) throws -> Void)?

    override func tearDown() async throws {
        try await super.tearDown()
        try? FileManager.default.removeItem(at: designDirectory)
    }

    func launchDesktop(appearance: String = "dark", setup: Bool = false,
                       configuration: String = "") throws -> XCUIApplication {
        try FileManager.default.createDirectory(at: designDirectory, withIntermediateDirectories: true)
        try """
        window-save-state = never
        session-persistence = false
        quit-after-last-window-closed = false
        auto-update = off
        confirm-close-surface = false
        macos-titlebar-style = tabs
        window-width = 130
        window-height = 38
        font-family = Menlo
        font-size = 13
        app-appearance = \(appearance)
        status-animate = false
        \(configuration)
        """.write(to: designConfig, atomically: true, encoding: .utf8)
        let app = try takoApplication()
        app.launchEnvironment["TAKO_CONFIG_PATH"] = designConfig.path
        let agents = designDirectory.appendingPathComponent("agents", isDirectory: true)
        let codex = agents.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        app.launchEnvironment["TAKO_AGENT_HOOKS_HOME"] = agents.path
        app.launchEnvironment["CODEX_HOME"] = codex.path
        if setup {
            app.launchArguments.removeAll { $0 == "--no-launch-notices" }
            app.launchEnvironment.removeValue(forKey: "TAKO_NO_LAUNCH_NOTICES")
        }
        try beforeDesktopLaunch?(app)
        app.launch()
        XCTAssertTrue(canvas(in: app).waitForExistence(timeout: 10))
        waitForPaneCount(1, in: app)
        return app
    }

    func settings(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["DesktopSettingsRoot"].firstMatch
    }

    func openSettings(in app: XCUIApplication) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let root = settings(in: app)
        XCTAssertTrue(root.waitForExistence(timeout: 7))
        return root
    }

    func selectSection(_ name: String, in app: XCUIApplication) {
        let button = settings(in: app).buttons["DesktopSettingsSection-\(name)"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(button.isHittable)
        button.click()
    }

    func setText(_ text: String, field: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        reveal(field, in: app)
        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText(text)
    }

    func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let root = settings(in: app)
        if element.identifier == "DesktopSettingsSearch" {
            XCTAssertTrue(element.isHittable)
            return
        }
        guard let page = root.scrollViews.allElementsBoundByIndex.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else { XCTAssertTrue(element.isHittable); return }
        // SwiftUI may report an offscreen field as hittable behind the footer.
        // Require its whole physical frame inside the clipped page as well.
        func visible() -> CGRect {
            let panel = root.frame
            let aboveFooter = CGRect(x: panel.minX, y: panel.minY, width: panel.width,
                                     height: max(0, panel.height - 56))
            return page.frame.intersection(aboveFooter).insetBy(dx: 2, dy: 3)
        }
        for _ in 0..<16 {
            let viewport = visible()
            if viewport.contains(element.frame) && element.isHittable { return }
            page.scroll(byDeltaX: 0, deltaY: element.frame.minY < viewport.minY ? 240 : -240)
        }
        XCTAssertTrue(visible().contains(element.frame), "Control must be visible above the footer: \(element.frame), page \(visible())")
        XCTAssertTrue(element.isHittable)
    }

    func clickSetting(_ identifier: String, in app: XCUIApplication) {
        let control = settings(in: app).descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        reveal(control, in: app)
        control.click()
    }

    func fontSize(in app: XCUIApplication) -> XCUIElement {
        settings(in: app).textFields["DesktopFontSize"].firstMatch
    }

    func enterSize(_ value: String, in app: XCUIApplication) {
        setText(value, field: fontSize(in: app), in: app)
        app.typeKey(.return, modifierFlags: [])
    }

    func assertSize(_ value: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let field = fontSize(in: app)
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed, file: file, line: line)
    }

    func configText() throws -> String { try String(contentsOf: designConfig, encoding: .utf8) }

    func closeSettings(in app: XCUIApplication) {
        let root = settings(in: app)
        let close = root.buttons["DesktopSettingsClose"].firstMatch
        XCTAssertTrue(close.isHittable)
        close.click()
        XCTAssertTrue(root.waitForNonExistence(timeout: 5))
    }

    func captureSettings(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: settings(in: app).screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func assertSettingsCentered(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let parent = activeWindow(in: app).frame
        let panel = settings(in: app).frame
        XCTAssertEqual(panel.midX, parent.midX, accuracy: 3, file: file, line: line)
        XCTAssertEqual(panel.midY, parent.midY, accuracy: 3, file: file, line: line)
        XCTAssertLessThanOrEqual(panel.width, min(820, parent.width - 24) + 3, file: file, line: line)
        XCTAssertLessThanOrEqual(panel.height, min(700, parent.height - 24) + 3, file: file, line: line)
        XCTAssertGreaterThanOrEqual(panel.width, min(820, parent.width - 24) - 3, file: file, line: line)
    }
}
