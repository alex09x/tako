/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import XCTest

@MainActor
final class TakoScopedAppearanceHelpers {
    let testRoot: URL
    let sessionHome: URL
    let hooksHome: URL
    let configFile: URL
    let defaultsSuite: String
    private(set) var app: XCUIApplication?

    init() {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("tako_scoped_test_\(UUID().uuidString)")
        self.testRoot = tempBase
        self.sessionHome = tempBase.appendingPathComponent("sessions")
        self.hooksHome = tempBase.appendingPathComponent("hooks")
        self.configFile = tempBase.appendingPathComponent("config.tako")
        self.defaultsSuite = "TAKO_UI_TESTS_SCOPED_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"

        try? FileManager.default.createDirectory(at: sessionHome, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: hooksHome, withIntermediateDirectories: true)

        let initialConfig = """
        macos-titlebar-style = tabs
        tab-style = pill
        title = "TakoScopedAppearanceUITests"
        session-persistence = true
        remote-control = on
        auto-update = off
        cursor-style-blink = false
        theme = TakoCore
        """
        try? initialConfig.write(to: configFile, atomically: true, encoding: .utf8)
    }

    func launchIsolatedApp() throws -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments.append(contentsOf: [
            "-ApplePersistenceIgnoreState", "YES",
            "--no-update",
            "--no-launch-notices"
        ])
        application.launchEnvironment["TAKO_CONFIG_PATH"] = configFile.path
        application.launchEnvironment["TAKO_USER_DEFAULTS_SUITE"] = defaultsSuite
        application.launchEnvironment["TAKO_SESSIONS_HOME"] = sessionHome.path
        application.launchEnvironment["TAKO_AGENT_HOOKS_HOME"] = hooksHome.path
        application.launchEnvironment["TAKO_NO_UPDATE"] = "1"
        application.launchEnvironment["TAKO_NO_LAUNCH_NOTICES"] = "1"
        application.launchEnvironment["IDE_DISABLED_OS_ACTIVITY_DT_MODE"] = "1"
        application.launch()
        XCTAssertTrue(application.windows.firstMatch.waitForExistence(timeout: 10), "Terminal window should exist")
        self.app = application
        return application
    }

    func cleanup() {
        if let runningApp = app, runningApp.state != .notRunning {
            runningApp.terminate()
        }
        try? FileManager.default.removeItem(at: testRoot)
        UserDefaults(suiteName: defaultsSuite)?.removePersistentDomain(forName: defaultsSuite)
    }

    static func samplePixelColor(from element: XCUIElement, atNormalized offset: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> NSColor? {
        let screenshot = element.screenshot()
        let image = screenshot.image
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        guard width > 0, height > 0 else { return nil }
        let x = max(0, min(width - 1, Int(CGFloat(width) * offset.x)))
        let y = max(0, min(height - 1, Int(CGFloat(height) * offset.y)))
        return image.colorAt(x: x, y: y)
    }

    static func colorDifference(_ c1: NSColor, _ c2: NSColor) -> CGFloat {
        let r1 = c1.usingColorSpace(.sRGB) ?? c1
        let r2 = c2.usingColorSpace(.sRGB) ?? c2
        return abs(r1.redComponent - r2.redComponent)
            + abs(r1.greenComponent - r2.greenComponent)
            + abs(r1.blueComponent - r2.blueComponent)
    }

    static func attachScreenshot(_ screenshot: XCUIScreenshot, name: String, to testCase: XCTestCase) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    static func openSidebar(in app: XCUIApplication) {
        let header = app.descendants(matching: .any)["SessionSidebarHeader"]
        if !header.exists {
            app.typeKey("s", modifierFlags: [.command, .option])
            _ = header.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(header.exists, "Session sidebar should appear")
    }

    static func openWorkspaceAppearance(in app: XCUIApplication) -> XCUIElement {
        openSidebar(in: app)
        let wsRow = app.staticTexts["DEFAULT"]
        XCTAssertTrue(wsRow.waitForExistence(timeout: 5), "DEFAULT workspace row should exist")
        wsRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        let wsItem = app.menuItems["Workspace Appearance…"]
        XCTAssertTrue(wsItem.waitForExistence(timeout: 5), "Workspace Appearance menu item should exist")
        wsItem.click()
        let dialog = app.groups["TerminalSettingsDialog"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), "TerminalSettingsDialog should appear")
        return dialog
    }

    static func openPaneAppearance(in app: XCUIApplication, isChild: Bool = false) -> XCUIElement {
        openSidebar(in: app)
        let wsRow = app.staticTexts["DEFAULT"]
        XCTAssertTrue(wsRow.waitForExistence(timeout: 5), "DEFAULT workspace row should exist")

        let wsY = wsRow.frame.midY
        let sidebarTexts = app.windows.firstMatch.staticTexts.allElementsBoundByIndex
            .filter { $0.exists && $0.frame.midY > wsY && ($0.value as? String) != "DEFAULT" }
            .sorted(by: { $0.frame.midY < $1.frame.midY })

        let target: XCUIElement
        if isChild && sidebarTexts.count > 1 {
            target = sidebarTexts[1]
        } else if let first = sidebarTexts.first {
            target = first
        } else {
            target = wsRow
        }

        if target === wsRow {
            let offset = isChild ? CGVector(dx: 0.5, dy: 3.5) : CGVector(dx: 0.5, dy: 2.0)
            wsRow.coordinate(withNormalizedOffset: offset).rightClick()
        } else {
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        }

        let expectedTitle = isChild ? "Pane Appearance…" : "Terminal Appearance…"
        let altTitle = isChild ? "Terminal Appearance…" : "Pane Appearance…"
        var item = app.menuItems[expectedTitle]
        if !item.waitForExistence(timeout: 2) {
            item = app.menuItems[altTitle]
        }
        XCTAssertTrue(item.waitForExistence(timeout: 3), "Appearance menu item should exist in context menu")
        item.click()

        let dialog = app.groups["TerminalSettingsDialog"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), "TerminalSettingsDialog should appear")
        return dialog
    }

    static func dismissDialog(_ dialog: XCUIElement, in app: XCUIApplication) {
        let closeBtn = app.buttons["SettingsCloseButton"]
        if closeBtn.exists {
            closeBtn.click()
        } else {
            dialog.typeKey(.escape, modifierFlags: [])
            if dialog.exists {
                dialog.typeKey(.escape, modifierFlags: [])
            }
        }
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 5), "Dialog should dismiss")
    }
}
