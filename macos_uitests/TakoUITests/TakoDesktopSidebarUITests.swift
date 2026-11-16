/*
 * tako — Sidebar icons, keyboard search and plus-menu creation
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest

final class TakoDesktopSidebarUITests: TakoDesktopDesignCase {
    func testCompactSidebarHasDesignHeightInAnIsolatedShell() throws {
        // Fixed expected paths are independent of the application's received values.
        let home = fixtureShellHome
        let agents = designDirectory.appendingPathComponent("agents")
        let expected = [
            "HOME": home.path,
            "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
            "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path,
            "XDG_CACHE_HOME": home.appendingPathComponent(".cache").path,
            "HISTFILE": home.appendingPathComponent(".shell_history").path,
            "ZDOTDIR": home.path,
            "TAKO_AGENT_HOOKS_HOME": agents.path,
            "CODEX_HOME": agents.appendingPathComponent(".codex").path,
            "TAKO_SESSIONS_HOME": fixtureSessionsHome.path,
        ]
        let prompt = "TKUI-READY>"
        beforeDesktopLaunch = { app in
            app.launchEnvironment["PS1"] = prompt
            app.launchEnvironment["PROMPT_COMMAND"] = ""
            app.launchEnvironment["BASH_ENV"] = ""
            app.launchEnvironment["ENV"] = ""
            for (key, path) in expected {
                guard path.hasPrefix("/private/tmp/tkui/"), app.launchEnvironment[key] == path else {
                    throw NSError(domain: "TakoUITestPrivateLaunch", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Refusing a non-private launch value for \(key)"])
                }
            }
        }
        // Start the private login shell; replace it explicitly rather than relying on a command config key.
        let app = try launchDesktop(configuration: """
        sidebar-style = compact
        sidebar-group = workspace
        shell-integration = none
        """)
        let id = try XCTUnwrap(paneIDs(in: app).first)
        let terminal = pane(id, in: app).textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        XCTAssertTrue(terminal.isHittable)
        let loginReady = XCTNSPredicateExpectation(predicate: NSPredicate { element, _ in
            guard let value = (element as? XCUIElement)?.value as? String else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }, object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [loginReady], timeout: 10), .completed,
                       "Wait for the private login shell's initial screen before the bootstrap input")
        terminal.click()
        // Portable first input, interpreted only by this fixture's private login shell.
        app.typeText("exec /bin/bash --noprofile --norc --noediting -i\n")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", prompt), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, "Wait for the controlled shell prompt")
        let keys = ["HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "HISTFILE",
                    "ZDOTDIR", "TAKO_AGENT_HOOKS_HOME", "CODEX_HOME", "TAKO_SESSIONS_HOME"]
        let witness = fixtureShellHome.appendingPathComponent("environment-witness.txt")
        let variables = (keys + ["BASH_VERSION", "PWD"]).map { "$" + $0 }.joined(separator: "|")
        terminal.click()
        // After the exec bootstrap: inspect only the declared private values, never the full environment.
        app.typeText("printf '%s\\n' \"\(variables)\" > '\(witness.path)'\n")
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let text = try? String(contentsOf: witness, encoding: .utf8) else { return false }
            let fields = text.trimmingCharacters(in: .newlines).components(separatedBy: "|")
            return fields.count == keys.count + 2 && !fields[keys.count].isEmpty
                && zip(keys, fields).allSatisfy { expected[$0.0] == $0.1 }
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 10), .completed,
                       "The controlled Bash must receive the fixed private directories and history file")
        let observed = try String(contentsOf: witness, encoding: .utf8)
        let metadata = XCTAttachment(string: "First input replaces the private login shell with /bin/bash --noprofile --norc --noediting -i.\n"
            + "Verified fields: \(keys.joined(separator: ",")); final fields are observed BASH_VERSION and PWD.\n"
            + "Cwd is observed only, not claimed private. This case does not verify fish/zsh history policy.\n" + observed)
        metadata.name = "Controlled Bash private directory witness"
        metadata.lifetime = .keepAlways
        add(metadata)

        let row = activeWindow(in: app).descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'session-tab-' AND value == 'selected'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 7))
        XCTAssertTrue(row.isHittable)
        XCTAssertEqual(row.frame.height, 24, accuracy: 0.75, "Compact's visible row uses the approved 24 pt height")
        XCTAssertEqual(paneIDs(in: app), [id])
        let sidebar = activeWindow(in: app).descendants(matching: .any)["SessionSidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: sidebar.screenshot())
        shot.name = "Compact sidebar, live 24 pt row"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testSettingsAndKeyboardIconsOpenTheirActualPages() throws {
        let app = try launchDesktop()
        app.buttons["SessionSidebarSettings"].firstMatch.click()
        XCTAssertTrue(settings(in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(settings(in: app).buttons["DesktopSettingsSection-general"].firstMatch.isSelected)
        closeSettings(in: app)
        app.buttons["SessionSidebarKeys"].firstMatch.click()
        XCTAssertTrue(settings(in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(settings(in: app).buttons["DesktopSettingsSection-keys"].firstMatch.isSelected)
        closeSettings(in: app)
    }

    func testCommandKFiltersAndEscapeRestoresSidebarWithoutClosingIt() throws {
        let app = try launchDesktop()
        let id = try XCTUnwrap(paneIDs(in: app).first)
        pane(id, in: app).textViews.firstMatch.click()
        app.typeKey("k", modifierFlags: .command)
        app.typeText("no-such-session-8675309")
        let search = app.textFields["SessionSidebarSearchField"].firstMatch
        XCTAssertEqual(search.value as? String, "no-such-session-8675309")
        XCTAssertTrue(app.buttons["SessionSidebarSearchClear"].firstMatch.exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(search.value as? String, "")
        XCTAssertTrue(search.isHittable)
        XCTAssertEqual(paneIDs(in: app), [id])
        XCTAssertFalse(app.buttons["SessionSidebarNewSession"].exists, "The retired footer is absent")
    }

    func testPlusMenuCreatesSplitAndSessionWithoutClosingExistingPane() throws {
        let app = try launchDesktop()
        let first = try XCTUnwrap(paneIDs(in: app).first)
        app.buttons["SessionSidebarHeaderNewSession"].firstMatch.click()
        let split = app.menuItems["New Terminal to the Right"].firstMatch
        XCTAssertTrue(split.waitForExistence(timeout: 5))
        split.click()
        waitForPaneCount(2, in: app)
        XCTAssertTrue(paneIDs(in: app).contains(first))
        let second = try XCTUnwrap(paneIDs(in: app).first { $0 != first })
        let process = try shellPID(second, phase: "SIDEBAR_HIDE_BEFORE", in: app)
        // The parent row represents the focused pane; capture it after the split.
        let row = activeWindow(in: app).descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'session-tab-' AND value == 'selected'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let originalRow = row.identifier
        app.buttons["SessionSidebarHeaderNewSession"].firstMatch.click()
        app.menuItems["New Session"].firstMatch.click()
        waitForPaneCount(1, in: app)
        XCTAssertFalse(paneIDs(in: app).contains(first))
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'session-tab-'"))
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        activeWindow(in: app).descendants(matching: .any)[originalRow].firstMatch.click()
        waitForPaneCount(2, in: app)
        XCTAssertTrue(paneIDs(in: app).contains(first))
        XCTAssertEqual(try shellPID(second, phase: "SIDEBAR_SHOW_AFTER", in: app, focus: false), process)
    }

    func testActiveSessionStaysVisibleWhenReturningToAnOverflowingSidebar() throws {
        let app = try launchDesktop()
        func createSession() {
            let before = Set(paneIDs(in: app))
            app.typeKey("t", modifierFlags: .command)
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let ids = self.paneIDs(in: app)
                return ids.count == 1 && !before.contains(ids[0])
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 10), .completed)
        }
        for _ in 0..<14 { createSession() }
        let previousPane = try XCTUnwrap(paneIDs(in: app).first)
        let process = try shellPID(previousPane, phase: "SCROLL_BEFORE", in: app)
        func selectedRow() -> XCUIElement {
            activeWindow(in: app).descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH 'session-tab-' AND value == 'selected'")).firstMatch
        }
        let previousRow = selectedRow().identifier
        createSession()
        func assertSelectionVisible() {
            let row = selectedRow()
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            let list = activeWindow(in: app).descendants(matching: .any)["SessionSidebar"].firstMatch.scrollViews.firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 5))
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                list.frame.contains(row.frame.insetBy(dx: 1, dy: 1)) && row.isHittable
            }, object: row)
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed,
                           "The current session must remain inside the sidebar viewport after remount")
        }
        assertSelectionVisible()
        activeWindow(in: app).descendants(matching: .any)[previousRow].firstMatch.click()
        waitForPaneCount(1, in: app)
        XCTAssertEqual(paneIDs(in: app), [previousPane])
        assertSelectionVisible()
        XCTAssertEqual(try shellPID(previousPane, phase: "SCROLL_AFTER", in: app, focus: false), process)
    }
}
