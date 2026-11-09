/*
 * tako — English settings and menus preserve Unicode terminal output
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest

final class TakoEnglishInterfaceUITests: TakoDesktopDesignCase {
    private func assertEnglish(_ root: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for element in root.staticTexts.allElementsBoundByIndex + root.buttons.allElementsBoundByIndex {
            for text in [element.label, element.title, element.value as? String ?? ""] {
                XCTAssertFalse(text.unicodeScalars.contains { (0x0400...0x052f).contains($0.value) },
                               "Unexpected Cyrillic UI text: \(text)", file: file, line: line)
            }
        }
    }

    func testSettingsAndTerminalMenusUseEnglishAndPreserveUnicodeOutput() throws {
        let app = try launchDesktop()
        let id = try XCTUnwrap(paneIDs(in: app).first)
        let process = try shellPID(id, phase: "ENGLISH_BEFORE", in: app)
        let output = "\u{43f}\u{440}\u{438}\u{432}\u{435}\u{442}"
        app.typeText("/usr/bin/printf '\\320\\277\\321\\200\\320\\270\\320\\262\\320\\265\\321\\202\\n'\n")
        let terminal = pane(id, in: app).textViews.firstMatch
        let visibleOutput = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", output), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [visibleOutput], timeout: 5), .completed)

        let root = openSettings(in: app)
        let sections = [("general", "General"), ("interface", "App Appearance"),
                        ("appearance", "Terminal Appearance"), ("input", "Input & Cursor"),
                        ("windows", "Windows & Workspaces"), ("quickTerminal", "Quick Terminal"),
                        ("activity", "Status & Activity"), ("keys", "Keyboard Shortcuts"),
                        ("agents", "Agents"), ("notifications", "Notifications & Permissions"),
                        ("advanced", "Advanced")]
        for (key, title) in sections {
            let button = root.buttons["DesktopSettingsSection-\(key)"].firstMatch
            XCTAssertTrue(button.label.contains(title))
            selectSection(key, in: app)
            assertEnglish(root)
        }
        closeSettings(in: app)
        terminal.rightClick()
        let appearance = app.menuItems["Appearance"].firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.hover()
        XCTAssertTrue(app.menuItems["All Themes…"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Customize…"].firstMatch.exists)
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        header(id, in: app).rightClick()
        XCTAssertTrue(app.menuItems["Rename…"].firstMatch.waitForExistence(timeout: 5))
        let zoom = app.menuItems["FloatingPaneMenuMaximize"].firstMatch
        XCTAssertTrue(zoom.exists)
        // AppKit menu captions use AXTitle; AXLabel can legitimately be empty.
        let caption = zoom.title
        logTestProgress("English maximize menu caption: \(caption)")
        XCTAssertTrue(["Restore", "Maximize"].contains(caption), caption)
        XCTAssertTrue(app.menuItems["Float Terminal"].firstMatch.exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(try shellPID(id, phase: "ENGLISH_AFTER", in: app), process)
        XCTAssertTrue((terminal.value as? String)?.contains(output) == true)
    }
}
