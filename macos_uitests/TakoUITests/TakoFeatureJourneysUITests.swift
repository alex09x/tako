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

    // MARK: - Screen Content Observation & Header Visibility Probe (Row 63 Scope)

    enum ScreenObservationError: LocalizedError {
        case imageConversionFailed
        case visionRecognitionFailed(String)
        case windowROICropFailed(CGRect)

        var errorDescription: String? {
            switch self {
            case .imageConversionFailed:
                return "Failed to convert NSImage to CGImage representation"
            case .visionRecognitionFailed(let reason):
                return "Vision text recognition request failed: \(reason)"
            case .windowROICropFailed(let rect):
                return "Failed to crop screenshot CGImage to window ROI rect \(rect)"
            }
        }
    }

    /// Extracts recognized text candidates and their bounding boxes from a CGImage via Vision framework.
    /// Throws explicit errors if Vision processing fails or if the callback receives an error,
    /// ensuring OCR failure is never misinterpreted as absent content in negative controls.
    private func extractRecognizedText(from cgImage: CGImage) throws -> [(text: String, box: CGRect)] {
        var results: [(text: String, box: CGRect)] = []
        var callbackError: Error?

        let request = VNRecognizeTextRequest { req, error in
            if let error = error {
                callbackError = error
                return
            }
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
        do {
            try handler.perform([request])
        } catch {
            throw ScreenObservationError.visionRecognitionFailed(error.localizedDescription)
        }

        if let callbackError = callbackError {
            throw ScreenObservationError.visionRecognitionFailed(callbackError.localizedDescription)
        }

        return results
    }

    /// Crops a full-screen screenshot CGImage to the bounding ROI of the target window in screen coordinates.
    /// Throws explicit errors if conversion or cropping fails.
    private func cropToWindowROI(screenshot: XCUIScreenshot, window: XCUIElement) throws -> CGImage {
        guard let fullCGImage = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ScreenObservationError.imageConversionFailed
        }

        let windowFrame = window.frame
        let screenWidthPts = screenshot.image.size.width
        let screenHeightPts = screenshot.image.size.height
        guard screenWidthPts > 0, screenHeightPts > 0 else {
            throw ScreenObservationError.windowROICropFailed(windowFrame)
        }

        let scaleX = CGFloat(fullCGImage.width) / screenWidthPts
        let scaleY = CGFloat(fullCGImage.height) / screenHeightPts

        // XCUIElement.frame coordinates are top-left screen points (Quartz display coordinates).
        // CGImage pixel coordinates also place (0, 0) at the top-left row/column.
        let cropPixelRect = CGRect(
            x: max(0, windowFrame.origin.x * scaleX),
            y: max(0, windowFrame.origin.y * scaleY),
            width: min(CGFloat(fullCGImage.width), windowFrame.size.width * scaleX),
            height: min(CGFloat(fullCGImage.height), windowFrame.size.height * scaleY)
        ).integral

        guard cropPixelRect.width > 0, cropPixelRect.height > 0,
              let cropped = fullCGImage.cropping(to: cropPixelRect) else {
            throw ScreenObservationError.windowROICropFailed(cropPixelRect)
        }

        return cropped
    }

    /// Header visibility and screen observation capability probe.
    /// Evaluates window ROI image extraction, Vision text recognition, and capture latency upper bounds.
    /// Note: This test serves as a window-scoped header visibility and screen observation probe.
    /// Capture completion elapsed time represents a conservative capture roundtrip upper bound,
    /// not an exact hardware first-frame presentation timestamp.
    /// Full Row 63 acceptance (30-pane fixture preparation, card-grid structure verification,
    /// and presentation token callback <150ms) remains catalogued as OPEN in docs/feature_registry.md.
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

        // 3. Pre-Open Baseline Capture (Absent-Content Negative Control for Pane Overview within Window ROI)
        let preOpenScreenshot = XCUIScreen.main.screenshot()
        let preOpenAttachment = XCTAttachment(screenshot: preOpenScreenshot)
        preOpenAttachment.name = "PreOpen-NegativeControl"
        preOpenAttachment.lifetime = .keepAlways
        self.add(preOpenAttachment)

        // Negative Control: Verify that before triggering Pane Overview, "Pane Overview" text is absent within window ROI.
        // Conversion and Vision failures throw explicit errors so failures are never counted as successful absence.
        let preOpenWindowCGImage = try cropToWindowROI(screenshot: preOpenScreenshot, window: appWindow)
        let preOpenTexts = try extractRecognizedText(from: preOpenWindowCGImage)
        let preOpenHasOverview = preOpenTexts.contains { $0.text.localizedCaseInsensitiveContains("Pane Overview") }
        XCTAssertFalse(preOpenHasOverview, "Pane Overview header text must be absent within the window ROI before open action")

        // 4. Trigger Production Open Action (`Cmd+Shift+O` for Row 63) & Measure Capture Latency Upper Bound
        let tTrigger = CFAbsoluteTimeGetCurrent()
        app.typeKey("o", modifierFlags: [.command, .shift])

        // Capture post-trigger compositor frame
        let overviewScreenshot = XCUIScreen.main.screenshot()
        let captureElapsedMs = (CFAbsoluteTimeGetCurrent() - tTrigger) * 1000.0
        print("[SCREEN_OBSERVATION] Post-trigger capture completed in \(String(format: "%.1f", captureElapsedMs))ms (conservative upper bound)")

        let postTriggerAttachment = XCTAttachment(screenshot: overviewScreenshot)
        postTriggerAttachment.name = "PostTrigger-PaneOverview"
        postTriggerAttachment.lifetime = .keepAlways
        self.add(postTriggerAttachment)

        // 5. Expected-Content Recognition & Spatial Verification within Window ROI:
        // Use Apple Vision text recognition on window ROI to prove the rendered frame contains the expected "Pane Overview" header
        let postOpenWindowCGImage = try cropToWindowROI(screenshot: overviewScreenshot, window: appWindow)
        let postOpenTexts = try extractRecognizedText(from: postOpenWindowCGImage)
        let matchedOverview = postOpenTexts.first { $0.text.localizedCaseInsensitiveContains("Pane Overview") }
        XCTAssertNotNil(matchedOverview, "Expected content 'Pane Overview' must be recognized within the window ROI after open action")

        if let match = matchedOverview {
            print("[SCREEN_OBSERVATION] Recognized expected content in window ROI: '\(match.text)' at bounding box \(match.box)")
            // Verify spatial location: Vision bounding boxes have origin at bottom-left in normalized coordinates (0..1)
            // The overview header is located in the upper region of the window
            XCTAssertGreaterThan(match.box.origin.y, 0.5, "Recognized header must be located in upper window region")
        }

        // 6. Dismiss via Escape and verify recovery
        app.typeKey(.escape, modifierFlags: [])
        let overviewHeaderAX = app.descendants(matching: .any)["PaneOverviewHeader"]
        XCTAssertTrue(overviewHeaderAX.waitForNonExistence(timeout: 5), "Pane Overview should dismiss on Escape")

        // 7. Header Visibility Timing Probe & Budget Feasibility Evaluation (< 150 ms):
        // Note: Capture elapsed time is evaluated as a conservative capture roundtrip upper bound.
        // Full Row 63 acceptance remains catalogued as OPEN in docs/feature_registry.md.
        print("[SCREEN_OBSERVATION] Header visibility capture roundtrip: elapsed=\(String(format: "%.1f", captureElapsedMs))ms (conservative upper bound) vs 150.0ms budget")
        XCTAssertLessThan(captureElapsedMs, 150.0, "Overview header visibility capture roundtrip must complete within 150ms budget")
    }
}

