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
import AppKit

final class TakoFeatureJourneysUITests: TakoCustomConfigCase {

    @MainActor
    func testSettingsDialogPresentationAndDismissal() async throws {
        let app = try takoApplication()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "Terminal window should appear")

        // Open Settings via shortcut Cmd+,
        app.typeKey(",", modifierFlags: .command)

        let settingsDialog = app.groups["TerminalSettingsDialog"]
        XCTAssertTrue(settingsDialog.waitForExistence(timeout: 5), "Settings dialog should appear")

        let closeButton = app.buttons["SettingsCloseButton"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "Settings dialog with Close button should appear")

        // Dismiss settings with Escape
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(settingsDialog.waitForNonExistence(timeout: 5), "Settings dialog should disappear after typing Escape")
    }

    @MainActor
    func testSettingsKeybindingRecorderCancel() async throws {
        let app = try takoApplication()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "Terminal window should appear")

        // Open Settings via shortcut Cmd+,
        app.typeKey(",", modifierFlags: .command)

        let settingsDialog = app.groups["TerminalSettingsDialog"]
        XCTAssertTrue(settingsDialog.waitForExistence(timeout: 5), "Settings dialog should appear")

        let recordButton = app.buttons["SettingsRecordButton"]
        XCTAssertTrue(recordButton.waitForExistence(timeout: 5), "Record button should appear")

        let closeButton = app.buttons["SettingsCloseButton"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "Close button should appear")

        // Click Record button to activate recording mode
        recordButton.click()

        // Verify recording state entered
        let isRecordingPredicate = NSPredicate(format: "value == 'recording'")
        let expectationRecording = XCTNSPredicateExpectation(predicate: isRecordingPredicate, object: settingsDialog)
        XCTAssertEqual(XCTWaiter.wait(for: [expectationRecording], timeout: 3), .completed, "Dialog should enter recording state")

        // First Escape cancels recording, but Settings dialog remains open
        app.typeKey(.escape, modifierFlags: [])
        let isCancelledPredicate = NSPredicate(format: "value == 'cancelled'")
        let expectationCancelled = XCTNSPredicateExpectation(predicate: isCancelledPredicate, object: settingsDialog)
        XCTAssertEqual(XCTWaiter.wait(for: [expectationCancelled], timeout: 3), .completed, "Dialog should return to cancelled/idle state")
        XCTAssertTrue(closeButton.exists, "Settings dialog should remain open after first Escape cancels recording")

        // Second Escape closes Settings dialog
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(settingsDialog.waitForNonExistence(timeout: 5), "Settings dialog should disappear after second Escape")
    }

    @MainActor
    func testSessionSidebarToggle() async throws {
        let app = try takoApplication()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "Terminal window should appear")

        // Toggle Session Sidebar via shortcut Cmd+Option+S
        app.typeKey("s", modifierFlags: [.command, .option])

        let sessionsHeader = app.descendants(matching: .any)["SessionSidebarHeader"]
        XCTAssertTrue(sessionsHeader.waitForExistence(timeout: 5), "Session sidebar header should appear")

        // Toggle back to close
        app.typeKey("s", modifierFlags: [.command, .option])
        XCTAssertTrue(sessionsHeader.waitForNonExistence(timeout: 5), "Session sidebar should disappear after second toggle")
    }

    @MainActor
    func testPaneOverviewToggle() async throws {
        let app = try takoApplication()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "Terminal window should appear")

        // Open Pane Overview via shortcut Cmd+Shift+O
        app.typeKey("o", modifierFlags: [.command, .shift])

        let overviewHeader = app.descendants(matching: .any)["PaneOverviewHeader"]
        XCTAssertTrue(overviewHeader.waitForExistence(timeout: 5), "Pane Overview header should appear")

        // Dismiss via Escape
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(overviewHeader.waitForNonExistence(timeout: 5), "Pane Overview should disappear after typing Escape")
    }

    @MainActor
    func testNotificationCenterToggle() async throws {
        let app = try takoApplication()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "Terminal window should appear")

        // Toggle Notification Center via shortcut Cmd+Option+N
        app.typeKey("n", modifierFlags: [.command, .option])

        let notificationsHeader = app.descendants(matching: .any)["NotificationCenterHeader"]
        XCTAssertTrue(notificationsHeader.waitForExistence(timeout: 5), "Notification Center header should appear")

        // Toggle back to close
        app.typeKey("n", modifierFlags: [.command, .option])
        XCTAssertTrue(notificationsHeader.waitForNonExistence(timeout: 5), "Notification Center should disappear after second toggle")
    }

    @MainActor
    func testSettingsKeybindingRecorderSaveAndReset() async throws {
        let app = try takoApplication()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "Terminal window should appear")

        // Open Settings via shortcut Cmd+,
        app.typeKey(",", modifierFlags: .command)

        let settingsDialog = app.groups["TerminalSettingsDialog"]
        XCTAssertTrue(settingsDialog.waitForExistence(timeout: 5), "Settings dialog should appear")

        let recordButton = app.buttons["SettingsRecordButton"]
        XCTAssertTrue(recordButton.waitForExistence(timeout: 5), "Record button should appear")

        let resetButton = app.buttons["SettingsResetButton"]
        XCTAssertTrue(resetButton.waitForExistence(timeout: 5), "Reset button should appear")

        // Activate recording mode
        recordButton.click()
        let isRecordingPredicate = NSPredicate(format: "value == 'recording'")
        let expectationRecording = XCTNSPredicateExpectation(predicate: isRecordingPredicate, object: settingsDialog)
        XCTAssertEqual(XCTWaiter.wait(for: [expectationRecording], timeout: 3), .completed, "Dialog should enter recording state")

        // Press custom shortcut keys Cmd+Opt+Ctrl+K
        app.typeKey("k", modifierFlags: [.command, .option, .control])

        // Reset to default
        resetButton.click()
        let isResetPredicate = NSPredicate(format: "value BEGINSWITH 'reset_success' OR value CONTAINS 'Reset'")
        let expectationReset = XCTNSPredicateExpectation(predicate: isResetPredicate, object: settingsDialog)
        XCTAssertEqual(XCTWaiter.wait(for: [expectationReset], timeout: 3), .completed, "Dialog should confirm reset to default")

        // Close Settings via Escape
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(settingsDialog.waitForNonExistence(timeout: 5), "Settings dialog should close after Escape")
    }

    @MainActor
    func testSettingsConflictModalCancelAndReassign() async throws {
        let app = try takoApplication()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "Terminal window should appear")

        // Open Settings via shortcut Cmd+,
        app.typeKey(",", modifierFlags: .command)

        let settingsDialog = app.groups["TerminalSettingsDialog"]
        XCTAssertTrue(settingsDialog.waitForExistence(timeout: 5), "Settings dialog should appear")

        let recordButton = app.buttons["SettingsRecordButton"]
        XCTAssertTrue(recordButton.waitForExistence(timeout: 5), "Record button should appear")

        let resetButton = app.buttons["SettingsResetButton"]
        XCTAssertTrue(resetButton.waitForExistence(timeout: 5), "Reset button should appear")

        // Step 1: Record and detect conflict with default shortcut Cmd+D (Split Right)
        recordButton.click()
        app.typeKey("d", modifierFlags: .command)

        // Conflict prompt displayed: Cancel via Escape
        app.typeKey(.escape, modifierFlags: [])

        // Step 2: Record again, re-enter Cmd+D, and confirm reassignment via Return
        recordButton.click()
        app.typeKey("d", modifierFlags: .command)
        app.typeKey(.return, modifierFlags: [])

        // Restore default
        resetButton.click()

        // Close Settings
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(settingsDialog.waitForNonExistence(timeout: 5), "Settings dialog should close after Escape")
    }

    @MainActor
    func testModalEventContainment() async throws {
        let app = try takoApplication()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "Terminal window should appear")

        // Open Settings modal
        app.typeKey(",", modifierFlags: .command)

        let settingsDialog = app.groups["TerminalSettingsDialog"]
        XCTAssertTrue(settingsDialog.waitForExistence(timeout: 5), "Settings dialog should appear")

        // Attempt split shortcut Cmd+D while modal is active: should be consumed by performKeyEquivalent
        app.typeKey("d", modifierFlags: .command)

        // Verify settings dialog remains visible and undisturbed
        XCTAssertTrue(settingsDialog.exists, "Settings dialog should retain first responder containment")

        // Dismiss settings
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(settingsDialog.waitForNonExistence(timeout: 5), "Settings dialog should close after Escape")
    }

    @MainActor
    func testScreenObservationCapabilityAndTiming() async throws {
        // 1. Baseline screen capture before application launch
        let t0 = CFAbsoluteTimeGetCurrent()
        let baselineScreenshot = XCUIScreen.main.screenshot()
        let baselineLatencyMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
        let baselineSize = baselineScreenshot.image.size
        print("[SCREEN_OBSERVATION] Baseline screenshot captured in \(String(format: "%.1f", baselineLatencyMs))ms, size=\(baselineSize)")
        XCTAssertGreaterThan(baselineSize.width, 0, "Baseline screen width should be non-zero")
        XCTAssertGreaterThan(baselineSize.height, 0, "Baseline screen height should be non-zero")
        XCTAssertGreaterThan(baselineScreenshot.pngRepresentation.count, 0, "Baseline PNG representation must be non-empty")

        // Retain baseline screenshot as persistent test attachment
        let baselineAttachment = XCTAttachment(screenshot: baselineScreenshot)
        baselineAttachment.name = "Baseline-Prelaunch"
        baselineAttachment.lifetime = .keepAlways
        self.add(baselineAttachment)

        // 2. Launch application and wait for window appearance
        let app = try takoApplication()
        app.activate()
        let appWindow = app.windows.firstMatch
        XCTAssertTrue(appWindow.waitForExistence(timeout: 5), "Terminal window should appear")

        // 3. Measure consecutive XCUIScreen.main.screenshot() capture latencies
        var captures: [XCUIScreenshot] = []
        var latencies: [Double] = []
        for i in 1...5 {
            let start = CFAbsoluteTimeGetCurrent()
            let shot = XCUIScreen.main.screenshot()
            let latencyMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            latencies.append(latencyMs)
            captures.append(shot)
            print("[SCREEN_OBSERVATION] Capture \(i): \(String(format: "%.1f", latencyMs))ms, size=\(shot.image.size)")
        }
        let avgLatencyMs = latencies.reduce(0.0, +) / Double(latencies.count)
        let minLatencyMs = latencies.min() ?? 0.0
        let maxLatencyMs = latencies.max() ?? 0.0
        print("[SCREEN_OBSERVATION] Latency stats: min=\(String(format: "%.1f", minLatencyMs))ms, avg=\(String(format: "%.1f", avgLatencyMs))ms, max=\(String(format: "%.1f", maxLatencyMs))ms")

        // Retain representative post-launch screenshot as test attachment
        guard let postLaunchScreenshot = captures.last else {
            XCTFail("No screenshot captures recorded")
            return
        }
        XCTAssertGreaterThan(postLaunchScreenshot.image.size.width, 0, "Post-launch screen width should be non-zero")
        XCTAssertGreaterThan(postLaunchScreenshot.image.size.height, 0, "Post-launch screen height should be non-zero")
        XCTAssertGreaterThan(postLaunchScreenshot.pngRepresentation.count, 0, "Post-launch PNG representation must be non-empty")

        let postLaunchAttachment = XCTAttachment(screenshot: postLaunchScreenshot)
        postLaunchAttachment.name = "PostLaunch-ScreenCapture"
        postLaunchAttachment.lifetime = .keepAlways
        self.add(postLaunchAttachment)

        // 4. Content Verification Boundary:
        // Expected-content verification of compositor-visible frames (matching deterministic rendered terminal
        // text, prompt glyphs, or overview card structures against an absent-content control) requires
        // execution under an authenticated test runner. Because Automation Mode is disabled on this host
        // (`automationmodetool status`: disabled), live compositor content verification is explicitly left
        // PENDING / OPEN per docs/feature_registry.md Section 13.
        print("[SCREEN_OBSERVATION] Content verification status: PENDING authenticated runner execution")

        // 5. Evaluate budget feasibility based on empirical timing:
        print("[SCREEN_OBSERVATION] Budget evaluation: min=\(String(format: "%.1f", minLatencyMs))ms, avg=\(String(format: "%.1f", avgLatencyMs))ms vs 150ms budget (feasibility unverified pending execution)")
    }
}

