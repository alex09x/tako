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
    func testPermissionsAreOptionalAndNotificationCheckGivesVisibleFeedback() async throws {
        let app = try isolatedApplication()
        app.launch()
        try openSetup(app)
        app.buttons["SetupStep-permissions"].click()
        XCTAssertTrue(app.staticTexts["Permissions"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["SetupAgentsCard"].exists)
        XCTAssertFalse(app.buttons["SetupSystemPermissionsCard"].exists)
        XCTAssertFalse(app.buttons["SetupPermission-notifications"].exists)
        let folders = app.buttons["SetupPermission-protectedFolders"]
        XCTAssertTrue(folders.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["SetupChooseFolder"].exists)
        XCTAssertTrue(folders.isHittable)
        let disk = app.buttons["SetupPermission-fullDiskAccess"]
        XCTAssertTrue(disk.isHittable)
        for kind in ["localNetwork", "microphone", "systemAudio", "screenCapture", "automation"] {
            XCTAssertTrue(app.buttons["SetupPermission-\(kind)"].isHittable)
        }
        disk.click()
        app.activate()
        let dragApp = app.descendants(matching: .any)["SetupDiskDragApp"].firstMatch
        XCTAssertTrue(dragApp.waitForExistence(timeout: 5))
        XCTAssertTrue(dragApp.isHittable)
        XCTAssertFalse(app.descendants(matching: .any)["SetupDiskAccessGuide"].exists)
        XCTAssertFalse(app.buttons["SetupDiskCopyPath"].exists)
        XCTAssertFalse(app.buttons["SetupDiskGuideBack"].exists)
        app.descendants(matching: .any)["SetupWizard"].firstMatch.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -180)
        let audio = app.buttons["SetupPermission-systemAudio"]
        audio.click()
        app.activate()
        XCTAssertFalse(app.descendants(matching: .any)["SetupPermissionExplanation-systemAudio"].exists)
        XCTAssertTrue(dragApp.waitForNonExistence(timeout: 5))
        XCTAssertTrue(audio.isHittable)
        XCTAssertFalse(app.descendants(matching: .any)["SetupPermission-camera"].exists)
        XCTAssertFalse(app.buttons["SetupRequestPermission-camera"].exists)
        let scopeNote = app.staticTexts["SetupPermissionScopeNote"]
        XCTAssertTrue(scopeNote.exists)
        XCTAssertTrue((scopeNote.label + " " + (scopeNote.value as? String ?? ""))
            .contains("Checks apply to Tako"))
        attach(app, name: "Setup optional permission statuses")
        // Navigation and status inspection must not require allowing an OS prompt.
        app.buttons["SetupStep-notifications"].click()
        let check = app.buttons["SetupRefreshNotifications"]
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        XCTAssertEqual(check.label, "Send test notification")
        XCTAssertTrue(app.staticTexts["SetupNotificationPresentationHint"].exists)
        check.click()
        XCTAssertTrue(app.staticTexts["SetupMessage"].waitForExistence(timeout: 5))
        let feedbackElement = app.staticTexts["SetupMessage"]
        let feedback = (feedbackElement.label + " " + (feedbackElement.value as? String ?? "")).lowercased()
        XCTAssertTrue(["test notification", "disabled", "enable notifications", "unavailable"].contains { feedback.contains($0) })
        attach(app, name: "Setup notification test feedback")
        app.buttons["SetupLater"].click()
        try await assertKeyboardReturnsToTerminal(app)
    }

    func testFreshLaunchCanSkipSetupAndKeepUsingTheTerminal() async throws {
        let app = try isolatedApplication()
        app.launchArguments.removeAll { $0 == "--no-launch-notices" }
        app.launchEnvironment.removeValue(forKey: "TAKO_NO_LAUNCH_NOTICES")
        app.launch()
        let wizard = app.descendants(matching: .any)["SetupWizard"].firstMatch
        XCTAssertTrue(wizard.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Your terminal. Your way."].exists)
        attach(app, name: "Setup welcome")
        app.buttons["SetupNext"].click()
        for _ in 0..<4 {
            let skip = app.buttons["SetupSkip"]
            XCTAssertTrue(skip.waitForExistence(timeout: 5))
            skip.click()
        }
        XCTAssertTrue(app.staticTexts["You're ready to go."].waitForExistence(timeout: 5))
        attach(app, name: "Setup optional steps skipped")
        app.buttons["SetupNext"].click()
        XCTAssertTrue(wizard.waitForNonExistence(timeout: 5))
        try await assertKeyboardReturnsToTerminal(app)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(wizard.waitForExistence(timeout: 2), "Completed setup must not reappear on relaunch")
    }

    func testAppearanceAppliesAndEscapeResumesAtTheSameStep() async throws {
        let app = try isolatedApplication()
        let initialConfig = try XCTUnwrap(app.launchEnvironment["TAKO_CONFIG_PATH"])
        var initial = try String(contentsOfFile: initialConfig, encoding: .utf8)
        initial += "\nfont-family = Monaco\nfont-size = 17\nfont-weight = 550\n"
        try initial.write(toFile: initialConfig, atomically: true, encoding: .utf8)
        app.launch()
        try openSetup(app)
        app.buttons["SetupStep-appearance"].click()
        let themes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "SetupTheme-"))
        XCTAssertTrue(themes.firstMatch.waitForExistence(timeout: 5))
        let choice = try XCTUnwrap(themes.allElementsBoundByIndex.first { ($0.value as? String) == "Not selected" })
        let chosenName = choice.label
        let preview = app.descendants(matching: .any)["SetupWizard"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let before = try previewBackground(preview)
        choice.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).click()
        let selected = NSPredicate(format: "value == %@", "Selected")
        let selectedExpectation = expectation(for: selected, evaluatedWith: choice)
        await fulfillment(of: [selectedExpectation], timeout: 5)
        let configPath = try XCTUnwrap(app.launchEnvironment["TAKO_CONFIG_PATH"])
        let text = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertTrue(text.contains("theme = \(chosenName)"), "Choosing a preset must persist immediately")
        XCTAssertTrue(text.contains("font-family = Monaco"))
        XCTAssertTrue(text.contains("font-size = 17"))
        XCTAssertTrue(text.contains("font-weight = 550"))
        attach(app, name: "Setup whole window after color selection")
        print("Setup colors before=\(before), after=\(try previewBackground(preview))")
        let changed = NSPredicate { _, _ in
            guard let after = try? self.previewBackground(preview) else { return false }
            return zip(before, after).reduce(0.0) { $0 + abs($1.0 - $1.1) } > 0.03
        }
        await fulfillment(of: [expectation(for: changed, evaluatedWith: preview)], timeout: 5)
        let appliedBackground = try previewBackground(preview)
        XCTAssertFalse(app.popUpButtons["SetupFont"].exists)
        XCTAssertFalse(app.steppers["SetupFontSize"].exists)
        let light = app.buttons["SetupTheme-Tako Dawn"]
        light.click()
        XCTAssertEqual(light.value as? String, "Selected")
        XCTAssertGreaterThan(try previewBackground(preview).reduce(0, +), 2.4,
                             "The whole setup window must use the selected light palette")
        choice.click()
        XCTAssertEqual(choice.value as? String, "Selected")
        XCTAssertLessThan(try previewBackground(preview).reduce(0, +), 1.0,
                          "Switching back must also recolor the whole window")
        attach(app, name: "Setup selected theme")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["SetupNext"].waitForNonExistence(timeout: 5))
        try assertTerminalFillsItsHost(app, background: appliedBackground)
        try openSetup(app)
        XCTAssertTrue(app.staticTexts["Find your colors."].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["SetupTheme-\(chosenName)"].value as? String, "Selected")
        app.buttons["SetupLater"].click()
        try await assertKeyboardReturnsToTerminal(app)
    }

    private func previewBackground(_ preview: XCUIElement) throws -> [Double] {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: preview.screenshot().pngRepresentation))
        let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide - 40, y: 80)?.usingColorSpace(.sRGB))
        return [color.redComponent, color.greenComponent, color.blueComponent]
    }

    private func assertTerminalFillsItsHost(_ app: XCUIApplication, background: [Double]) throws {
        let terminal = app.descendants(matching: .any)["terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        XCTAssertEqual(terminal.frame.minX, window.frame.minX, accuracy: 1.5)
        XCTAssertEqual(terminal.frame.maxX, window.frame.maxX, accuracy: 1.5)
        XCTAssertEqual(terminal.frame.maxY, window.frame.maxY, accuracy: 1.5)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: terminal.screenshot().pngRepresentation))
        // Skip the native window's one-pixel outline and rounded corner.
        // Exact drawable corners are covered by Metal and CPU bitmap tests.
        for (x, y) in [(bitmap.pixelsWide - 5, 12), (bitmap.pixelsWide - 28, bitmap.pixelsHigh - 28),
                       (bitmap.pixelsWide / 2, bitmap.pixelsHigh - 5), (5, bitmap.pixelsHigh / 2)] {
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            for (actual, expected) in zip([color.redComponent, color.greenComponent, color.blueComponent], background) {
                XCTAssertEqual(actual, expected, accuracy: 0.035, "Terminal edge at \(x),\(y) must match the selected background")
            }
        }
        let evidence = XCTAttachment(screenshot: terminal.screenshot())
        evidence.name = "Edge to edge terminal after theme selection"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testReentryIsSingleInstanceAndNotificationStepIsOptional() async throws {
        let app = try isolatedApplication()
        app.launch()
        app.typeKey(",", modifierFlags: [.command])
        let setupButton = app.buttons["SettingsSetupButton"]
        XCTAssertTrue(setupButton.waitForExistence(timeout: 5))
        setupButton.click()
        XCTAssertTrue(app.buttons["SetupNext"].waitForExistence(timeout: 5))
        app.buttons["SetupStep-agents"].click()
        XCTAssertTrue(app.checkBoxes["SetupAgent-codex"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.checkBoxes["SetupAgent-codex"].isEnabled, "The isolated profile must not connect real-account agents")
        XCTAssertFalse(app.buttons["SetupConnectAgents"].isEnabled)
        app.buttons["SetupStep-notifications"].click()
        XCTAssertTrue(app.staticTexts["Know when you're needed."].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "SetupWizard").count, 1)
        XCTAssertTrue(app.buttons["SetupSkip"].isHittable)
        // Reading this step must never require answering a macOS consent prompt.
        XCTAssertTrue(app.buttons["SetupLater"].isHittable)
        attach(app, name: "Setup notifications")
        app.buttons["SetupLater"].click()
        try openSetup(app)
        XCTAssertTrue(app.staticTexts["Know when you're needed."].waitForExistence(timeout: 5))
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
        XCTAssertNotNil(config["hooks"])
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
        var tab: XCUIElement?
        while tab == nil && Date() < deadline {
            tab = app.radioButtons.matching(identifier: "tab-1").allElementsBoundByIndex.first { $0.isHittable }
            if tab == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertEqual(try XCTUnwrap(tab).value as? Int, 1, "A normal keyboard shortcut must reach the terminal after setup closes")
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
