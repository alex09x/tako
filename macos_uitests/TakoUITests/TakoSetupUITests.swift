/*
 * tako — Setup wizard user journeys
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import XCTest

@MainActor
final class TakoSetupUITests: TakoCustomConfigCase {
    /// The A16 access list (SetupPermissionPanel): five main rows with their
    /// passive status, an action and a ? help each, three extras behind a
    /// collapsed disclosure, no camera. Only navigation is exercised: no row
    /// action runs, so nothing is requested and System Settings is not opened.
    /// Sending a test notification is covered by the model/unit tests, not
    /// here: this identity's notifications are Unavailable.
    func testPermissionsPanelShowsOptionalAccessStatusAndHelpWithoutRequestingAnything() async throws {
        // Every precondition throws: with continueAfterFailure = false XCTest
        // can tear the app down at the next suspension while a body that only
        // recorded a failure would go on against a terminated app.
        func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
            guard condition else { throw SetupPrecondition(message: message()) }
        }
        func shown(_ element: XCUIElement) -> String {
            (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
        }
        let app = try isolatedApplication()
        app.launch()
        try openSetup(app)
        app.buttons["SetupStep-notifications"].click()
        let title = app.staticTexts["SetupStepTitle"].firstMatch
        try require(title.waitForExistence(timeout: 5), "no SetupStepTitle")
        // A SwiftUI Text exposes its words as the static text's value.
        try require(shown(title) == "macOS Permissions", "title: \(shown(title))")
        try require(!app.buttons["SetupAgentsCard"].exists, "SetupAgentsCard is shown")
        try require(!app.buttons["SetupSystemPermissionsCard"].exists, "SetupSystemPermissionsCard is shown")
        let scopeNote = app.staticTexts["SetupPermissionScopeNote"]
        try require(scopeNote.exists, "no SetupPermissionScopeNote")
        try require((scopeNote.label + " " + (scopeNote.value as? String ?? "")).contains("permissions apply to Tako"),
                    "scope note: \(scopeNote.label) \(scopeNote.value ?? "")")
        func row(_ kind: String) -> XCUIElement { app.descendants(matching: .any)["SetupPermissionRow-\(kind)"].firstMatch }
        func texts(_ element: XCUIElement) -> [String] { element.staticTexts.allElementsBoundByIndex.map(shown) }
        // Main rows: title, purpose and a status each, one action, one ?.
        let main = ["notifications", "protectedFolders", "microphone", "fullDiskAccess", "localNetwork"]
        for kind in main {
            try require(row(kind).waitForExistence(timeout: 5), "no row \(kind)")
            try require(texts(row(kind)).count == 3, "\(kind): title, purpose and status \(texts(row(kind)))")
            try require(app.buttons["SetupPermissionHelp-\(kind)"].isHittable, "\(kind): ? is not hittable")
        }
        try require(app.buttons["SetupEnableNotifications"].isHittable, "SetupEnableNotifications is not hittable")
        try require(!app.buttons["SetupPermission-notifications"].exists, "SetupPermission-notifications is shown")
        for kind in main.dropFirst() {
            try require(app.buttons["SetupPermission-\(kind)"].isHittable, "\(kind): action is not hittable")
        }
        try require(texts(row("notifications")).last == "Unavailable",
                    "this test identity cannot post notifications: \(texts(row("notifications")))")
        try require(!app.buttons["SetupChooseFolder"].exists, "SetupChooseFolder is shown")
        try require(!app.descendants(matching: .any)["SetupPermission-camera"].exists, "a camera row is shown")
        try require(!app.buttons["SetupRequestPermission-camera"].exists, "a camera request is shown")
        // Extras: collapsed until the disclosure opens them.
        let extras = app.buttons["SetupPermissionExtras"]
        try require(extras.value as? String == "collapsed", "extras: \(extras.value ?? "nil")")
        let extraKinds = ["screenCapture", "systemAudio", "automation"]
        for kind in extraKinds { try require(!row(kind).exists, "\(kind) is shown while collapsed") }
        extras.click()
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "expanded"), object: extras)
        let opened = await XCTWaiter().fulfillment(of: [expanded], timeout: 5)
        try require(opened == .completed, "extras did not expand (\(opened.rawValue)): \(extras.value ?? "nil")")
        for kind in extraKinds {
            try require(row(kind).waitForExistence(timeout: 5), "no extra row \(kind)")
            try require(app.buttons["SetupPermission-\(kind)"].exists, "\(kind): no action")
            try require(app.buttons["SetupPermissionHelp-\(kind)"].exists, "\(kind): no ?")
        }
        try require(!app.descendants(matching: .any)["SetupPermission-camera"].exists, "a camera row is shown in extras")
        attach(app, name: "Setup optional permission statuses")
        // ? shows the row's help in the panel and hides it again; no prompt.
        let help = app.staticTexts["SetupPermissionHelp"]
        try require(!help.exists, "help is shown before ?")
        let notificationsHelp = app.buttons["SetupPermissionHelp-notifications"]
        notificationsHelp.click()
        try require(help.waitForExistence(timeout: 5), "? did not show the help")
        try require(!shown(help).isEmpty, "the help text is empty")
        attach(app, name: "Setup permission help")
        notificationsHelp.click()
        try require(help.waitForNonExistence(timeout: 5), "? did not hide the help")
        try require(!app.descendants(matching: .any)["SetupDiskDragApp"].exists, "a row action ran")
        // The app must still be running around Finish Later; a failure names
        // the runner and every uitest Tako process.
        func running(_ phase: String) throws {
            let apps = NSWorkspace.shared.runningApplications.filter {
                ($0.bundleIdentifier ?? "").hasPrefix("com.tako-core.terminal.uitest")
            }.map { "\($0.bundleIdentifier ?? "?") pid=\($0.processIdentifier) terminated=\($0.isTerminated)" }
            try require(app.state == .runningForeground || app.state == .runningBackground,
                        "the app is not running \(phase): app.state=\(app.state.rawValue) runner pid=\(ProcessInfo.processInfo.processIdentifier) apps=\(apps)")
        }
        try running("before SetupLater")
        app.buttons["SetupLater"].click()
        try running("after SetupLater")
        try await assertKeyboardReturnsToTerminal(app)
    }

    func testFreshLaunchCanSkipSetupAndKeepUsingTheTerminal() async throws {
        let app = try isolatedApplication()
        app.launchArguments.removeAll { $0 == "--no-launch-notices" }
        app.launchEnvironment.removeValue(forKey: "TAKO_NO_LAUNCH_NOTICES")
        app.launch()
        let wizard = app.descendants(matching: .any)["SetupWizard"].firstMatch
        XCTAssertTrue(wizard.waitForExistence(timeout: 15))
        // The welcome hero (A14): its line and Get Started.
        XCTAssertTrue(app.staticTexts["A terminal that shows which agents are working, waiting for you or need attention."].exists)
        XCTAssertEqual(app.buttons["SetupNext"].label, "Get Started")
        attach(app, name: "Setup welcome")
        app.buttons["SetupNext"].click()
        // Theme, Agents and Permissions are optional: Continue leaves each without choosing anything.
        for stage in ["Theme", "Agents", "Permissions"] {
            let next = app.buttons["SetupNext"]
            XCTAssertTrue(next.waitForExistence(timeout: 5), "Continue on \(stage)")
            XCTAssertEqual(next.label, "Continue")
            next.click()
        }
        XCTAssertTrue(app.staticTexts["Tako Is Ready"].waitForExistence(timeout: 5))
        attach(app, name: "Setup optional steps skipped")
        app.buttons["SetupFinish"].click()
        XCTAssertTrue(wizard.waitForNonExistence(timeout: 5))
        try await assertKeyboardReturnsToTerminal(app)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(wizard.waitForExistence(timeout: 2), "Completed setup must not reappear on relaunch")
    }

    func testReentryIsSingleInstanceAndNotificationStepIsOptional() async throws {
        let app = try isolatedApplication()
        app.launch()
        // Cmd+, opens the native Settings panel; General › First Run reopens setup.
        app.typeKey(",", modifierFlags: [.command])
        let settings = app.descendants(matching: .any)["DesktopSettingsRoot"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let general = settings.buttons["DesktopSettingsSection-general"].firstMatch
        XCTAssertTrue(general.waitForExistence(timeout: 5))
        general.click()
        let setupButton = settings.buttons["DesktopOpenSetup"].firstMatch
        XCTAssertTrue(setupButton.waitForExistence(timeout: 5))
        XCTAssertTrue(setupButton.isHittable)
        setupButton.click()
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5), "Opening setup must close Settings")
        XCTAssertTrue(app.buttons["SetupNext"].waitForExistence(timeout: 5))
        showStages(app)
        app.buttons["SetupStep-agents"].click()
        // An agent is a card button whose value says Connected / Selected / Not selected.
        let codex = app.buttons["SetupAgent-codex"]
        XCTAssertTrue(codex.waitForExistence(timeout: 5))
        XCTAssertFalse(codex.isEnabled, "The isolated profile must not connect real-account agents")
        XCTAssertFalse(app.buttons["SetupConnectAgents"].isEnabled)
        // The Permissions stage (A16) is opened by its first step, notifications: the
        // passive permission panel, with notifications as its first row.
        app.buttons["SetupStep-notifications"].click()
        let title = app.staticTexts["SetupStepTitle"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        // A SwiftUI Text exposes its words as the static text's value.
        func titleText() -> String { (title.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title.label }
        XCTAssertEqual(titleText(), "macOS Permissions")
        XCTAssertTrue(app.descendants(matching: .any)["SetupPermissionRow-notifications"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "SetupWizard").count, 1)
        // Optional: Continue leaves the stage without granting anything.
        XCTAssertTrue(app.buttons["SetupNext"].isHittable)
        XCTAssertEqual(app.buttons["SetupNext"].label, "Continue")
        // Reading this step must never require answering a macOS consent prompt.
        XCTAssertTrue(app.buttons["SetupLater"].isHittable)
        attach(app, name: "Setup notifications")
        app.buttons["SetupLater"].click()
        try openSetup(app)
        // Reopened, the wizard resumes at the same stage, once.
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(titleText(), "macOS Permissions")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "SetupWizard").count, 1)
        app.buttons["SetupLater"].click()
    }

    func testSelectedAgentReportsFailureThenInstallsRealHooksAndSkillInAnIsolatedHome() async throws {
        let app = try isolatedApplication()
        let home = URL(fileURLWithPath: try XCTUnwrap(app.launchEnvironment["TAKO_AGENT_HOOKS_HOME"]))
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not JSON".write(to: settings, atomically: true, encoding: .utf8)
        let skill = home.appendingPathComponent(".claude/skills/tako/SKILL.md")
        let codex = home.appendingPathComponent(".codex/hooks.json")
        try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: codex, atomically: true, encoding: .utf8)
        app.launch()
        try openSetup(app)
        app.buttons["SetupStep-agents"].click()
        let connect = app.buttons["SetupConnectAgents"]
        let enabled = NSPredicate(format: "enabled == true")
        await fulfillment(of: [expectation(for: enabled, evaluatedWith: connect)], timeout: 10)
        XCTAssertEqual(app.checkBoxes.matching(NSPredicate(format: "identifier BEGINSWITH %@", "SetupAgent-")).count, 0)
        app.buttons["SetupAgent-codex"].click()
        app.buttons["SetupLater"].click()
        try openSetup(app)
        let codexChoice = app.buttons["SetupAgent-codex"]
        await fulfillment(of: [expectation(for: enabled, evaluatedWith: codexChoice)], timeout: 10)
        XCTAssertEqual(codexChoice.value as? String, "Not selected", "An explicitly unselected agent must stay unselected on resume")
        await fulfillment(of: [expectation(for: enabled, evaluatedWith: connect)], timeout: 10)
        connect.click()
        XCTAssertTrue(app.staticTexts["SetupMessage"].waitForExistence(timeout: 10))
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "not JSON")
        XCTAssertFalse(FileManager.default.fileExists(atPath: skill.path))

        try #"{"setup-test-preserved":true}"#.write(to: settings, atomically: true, encoding: .utf8)
        app.buttons["SetupRefreshAgents"].click()
        await fulfillment(of: [expectation(for: enabled, evaluatedWith: connect)], timeout: 10)
        connect.click()
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 10))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertEqual(config["setup-test-preserved"] as? Bool, true)
        XCTAssertNil(config["hooks"], "Connect installs a skill, not removed status hooks")
        let skillText = try String(contentsOf: skill, encoding: .utf8)
        XCTAssertTrue(skillText.contains("name: tako") || skillText.contains("Tako Terminal Integration"))
        XCTAssertEqual(try String(contentsOf: codex, encoding: .utf8), "{}")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/skills/tako/SKILL.md").path))
        attach(app, name: "Setup connected agent")
        app.buttons["SetupLater"].click()
    }

    func testSetupMenuCreatesAHostWhenNoInitialWindowWasRequested() async throws {
        try updateConfig("initial-window = false\n")
        let app = try isolatedApplication()
        app.launch()
        app.activate()
        XCTAssertTrue(app.menuBars.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, 0)
        app.menuBars.menuBarItems.element(boundBy: 1).click()
        app.menuItems["Set Up Tako…"].click()
        XCTAssertTrue(app.buttons["SetupNext"].waitForExistence(timeout: 8))
        app.buttons["SetupLater"].click()
        try await assertTypingReachesTheShell(app)
    }

    func testSetupMenuCanRecoverAfterAllTerminalWindowsWereClosed() async throws {
        let app = try isolatedApplication()
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        app.typeKey("p", modifierFlags: [.command, .shift])
        let closeAll = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "Close All Windows")).firstMatch
        XCTAssertTrue(closeAll.waitForExistence(timeout: 5))
        closeAll.click()
        XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: 5))
        app.menuBars.menuBarItems.element(boundBy: 1).click()
        app.menuItems["Set Up Tako…"].click()
        XCTAssertTrue(app.buttons["SetupNext"].waitForExistence(timeout: 8))
        app.buttons["SetupLater"].click()
        try await assertTypingReachesTheShell(app)
    }

    func testAutomaticSetupWaitsForAFirstWindowBeyondTheOldDeadline() async throws {
        try updateConfig("initial-window = false\n")
        let app = try isolatedApplication()
        app.launchArguments.removeAll { $0 == "--no-launch-notices" }
        app.launchEnvironment.removeValue(forKey: "TAKO_NO_LAUNCH_NOTICES")
        app.launch()
        app.activate()
        XCTAssertTrue(app.menuBars.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, 0)
        try await Task.sleep(for: .seconds(13))
        app.typeKey("n", modifierFlags: [.command])
        XCTAssertTrue(app.buttons["SetupNext"].waitForExistence(timeout: 15))
        app.buttons["SetupLater"].click()
        try await assertTypingReachesTheShell(app)
    }

    private func isolatedApplication() throws -> XCUIApplication {
        let app = try takoApplication()
        let root = URL(fileURLWithPath: try XCTUnwrap(app.launchEnvironment["TAKO_CONFIG_PATH"]))
            .deletingLastPathComponent().appendingPathComponent("setup-agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        app.launchEnvironment["TAKO_AGENT_HOOKS_HOME"] = root.path
        return app
    }

    private func openSetup(_ app: XCUIApplication) throws {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        app.activate()
        app.menuBars.menuBarItems.element(boundBy: 1).click()
        let item = app.menuItems["Set Up Tako…"]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.click()
        XCTAssertTrue(app.buttons["SetupNext"].waitForExistence(timeout: 5))
        showStages(app)
    }

    /// The welcome hero (A14) has no stage bar: Get Started (`SetupNext`) leads to the
    /// stages. A reopened wizard that resumes at a stage already shows the bar.
    private func showStages(_ app: XCUIApplication) {
        let bar = app.buttons["SetupStep-appearance"]
        if !bar.exists {
            XCTAssertEqual(app.buttons["SetupNext"].label, "Get Started", "only the welcome hero lacks the stage bar")
            app.buttons["SetupNext"].click()
        }
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "the stage bar")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let wizard = app.descendants(matching: .any)["SetupWizard"].firstMatch
        let attachment = XCTAttachment(screenshot: wizard.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertKeyboardReturnsToTerminal(_ app: XCUIApplication) async throws {
        app.typeKey("t", modifierFlags: [.command])
        let deadline = Date().addingTimeInterval(5)
        var selectedCount = 0
        var sessionCount = 0
        while sessionCount < 2 && Date() < deadline {
            if let win = app.windows.allElementsBoundByIndex.first(where: { $0.textViews.firstMatch.isHittable }) {
                var seen: Set<String> = []
                let rows = win.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier BEGINSWITH 'session-tab-'"))
                    .allElementsBoundByIndex
                    .filter { $0.isHittable && seen.insert($0.identifier).inserted }
                sessionCount = rows.count
                selectedCount = rows.filter { ($0.value as? String) == "selected" }.count
            }
            if sessionCount < 2 { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertEqual(sessionCount, 2, "A normal keyboard shortcut must reach the terminal after setup closes")
        XCTAssertEqual(selectedCount, 1)
        try await assertTypingReachesTheShell(app)
    }

    private func assertTypingReachesTheShell(_ app: XCUIApplication) async throws {
        let witness = FileManager.default.temporaryDirectory.appendingPathComponent("setup-keyboard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: witness) }
        app.typeText("/usr/bin/printf 'SETUP''-RETURN' > '\(witness.path)'\n")
        let written = NSPredicate { _, _ in
            (try? String(contentsOf: witness, encoding: .utf8)) == "SETUP-RETURN"
        }
        let wroteFile = XCTNSPredicateExpectation(predicate: written, object: nil)
        await fulfillment(of: [wroteFile], timeout: 8)
    }
}

/// A failed precondition of an async UI test, thrown so the test stops where it failed.
struct SetupPrecondition: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
