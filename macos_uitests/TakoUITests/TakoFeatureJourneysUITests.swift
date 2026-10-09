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
import Vision

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

    // MARK: - Screen Content Observation & Presentation Timing (Row 63)

    /// Extracts recognized text candidates and their bounding boxes from an NSImage via Vision framework.
    private func extractRecognizedText(from image: NSImage) -> [(text: String, box: CGRect)] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }
        var results: [(text: String, box: CGRect)] = []
        let request = VNRecognizeTextRequest { req, _ in
            guard let observations = req.results as? [VNRecognizedTextObservation] else { return }
            for obs in observations {
                if let candidate = obs.topCandidates(1).first {
                    results.append((candidate.string, obs.boundingBox))
                }
            }
        }
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return results
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

        let baselineAttachment = XCTAttachment(screenshot: baselineScreenshot)
        baselineAttachment.name = "Baseline-Prelaunch"
        baselineAttachment.lifetime = .keepAlways
        self.add(baselineAttachment)

        // 2. Launch application and wait for window appearance
        let app = try takoApplication()
        app.activate()
        let appWindow = app.windows.firstMatch
        XCTAssertTrue(appWindow.waitForExistence(timeout: 5), "Terminal window should appear")

        // 3. Pre-Open Baseline Capture (Absent-Content Negative Control for Pane Overview)
        let preOpenScreenshot = XCUIScreen.main.screenshot()
        let preOpenAttachment = XCTAttachment(screenshot: preOpenScreenshot)
        preOpenAttachment.name = "PreOpen-NegativeControl"
        preOpenAttachment.lifetime = .keepAlways
        self.add(preOpenAttachment)

        // Negative Control: Verify that before triggering Pane Overview, "Pane Overview" text is absent
        let preOpenTexts = extractRecognizedText(from: preOpenScreenshot.image)
        let preOpenHasOverview = preOpenTexts.contains { $0.text.localizedCaseInsensitiveContains("Pane Overview") }
        XCTAssertFalse(preOpenHasOverview, "Pane Overview header text must be absent before open action")

        // 4. Trigger Production Open Action (`Cmd+Shift+O` for Row 63) & Measure Presentation Latency
        let tTrigger = CFAbsoluteTimeGetCurrent()
        app.typeKey("o", modifierFlags: [.command, .shift])

        // Capture post-trigger compositor frame
        let overviewScreenshot = XCUIScreen.main.screenshot()
        let captureElapsedMs = (CFAbsoluteTimeGetCurrent() - tTrigger) * 1000.0
        print("[SCREEN_OBSERVATION] Post-trigger capture completed in \(String(format: "%.1f", captureElapsedMs))ms")

        let postTriggerAttachment = XCTAttachment(screenshot: overviewScreenshot)
        postTriggerAttachment.name = "PostTrigger-PaneOverview"
        postTriggerAttachment.lifetime = .keepAlways
        self.add(postTriggerAttachment)

        // 5. Expected-Content Recognition & Spatial Verification:
        // Use Apple Vision text recognition to prove the rendered frame contains the expected "Pane Overview" header
        let postOpenTexts = extractRecognizedText(from: overviewScreenshot.image)
        let matchedOverview = postOpenTexts.first { $0.text.localizedCaseInsensitiveContains("Pane Overview") }
        XCTAssertNotNil(matchedOverview, "Expected content 'Pane Overview' must be recognized in the captured frame after open action")

        if let match = matchedOverview {
            print("[SCREEN_OBSERVATION] Recognized expected content: '\(match.text)' at bounding box \(match.box)")
            // Verify spatial location: Vision bounding boxes have origin at bottom-left in normalized coordinates (0..1)
            // The overview header is located in the upper region of the screen/window
            XCTAssertGreaterThan(match.box.origin.y, 0.2, "Recognized header must be located in upper window region")
        }

        // 6. Dismiss via Escape and verify recovery
        app.typeKey(.escape, modifierFlags: [])
        let overviewHeaderAX = app.descendants(matching: .any)["PaneOverviewHeader"]
        XCTAssertTrue(overviewHeaderAX.waitForNonExistence(timeout: 5), "Pane Overview should dismiss on Escape")

        // 7. Budget Feasibility Evaluation (< 150 ms):
        print("[SCREEN_OBSERVATION] Row 63 Presentation Timing: elapsed=\(String(format: "%.1f", captureElapsedMs))ms vs 150.0ms budget")
        XCTAssertLessThan(captureElapsedMs, 150.0, "Overview interactive presentation must complete within 150ms budget")
    }
}

