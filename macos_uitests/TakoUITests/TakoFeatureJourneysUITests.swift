/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest

final class TakoFeatureJourneysUITests: TakoCustomConfigCase {

    @MainActor
    func testSettingsDialogPresentationAndDismissal() async throws {
        let app = try takoApplication()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "Terminal window should appear")

        // Open Settings via Cmd+,
        app.typeKey(",", modifierFlags: .command)

        let closeButton = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'Close'")).firstMatch
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "Settings dialog with Close button should appear")

        // Dismiss settings with Escape
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(closeButton.waitForNonExistence(timeout: 5), "Settings dialog should disappear after typing Escape")
    }

    @MainActor
    func testSessionSidebarToggle() async throws {
        let app = try takoApplication()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "Terminal window should appear")

        // Toggle Session Sidebar via shortcut Cmd+Option+S
        app.typeKey("s", modifierFlags: [.command, .option])

        // Toggle back
        app.typeKey("s", modifierFlags: [.command, .option])
    }

    @MainActor
    func testPaneOverviewToggle() async throws {
        let app = try takoApplication()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "Terminal window should appear")

        // Open Pane Overview via Cmd+Shift+O
        app.typeKey("o", modifierFlags: [.command, .shift])

        // Dismiss via Escape
        app.typeKey(.escape, modifierFlags: [])
    }
}
