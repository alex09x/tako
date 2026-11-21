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

/// The Settings journeys open what Cmd+, opens: the native DesktopSettings
/// panel (`DesktopSettingsRoot`), driven by its Keys page.
final class TakoFeatureJourneysUITests: TakoDesktopDesignCase {

    @MainActor
    func testSettingsDialogPresentationAndDismissal() async throws {
        let app = try launchDesktop()
        let root = openSettings(in: app)
        XCTAssertTrue(root.buttons["DesktopSettingsClose"].firstMatch.waitForExistence(timeout: 5),
                      "Settings must open with its Close button")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(root.waitForNonExistence(timeout: 5), "Escape must close Settings")
    }

    @MainActor
    func testSettingsKeybindingRecorderCancel() async throws {
        let app = try launchDesktop()
        let before = try configText()
        let root = openSettings(in: app)
        showShortcut("new_tab", in: app)
        startRecording("new_tab", in: app)
        // The first Escape ends the recording only: Settings stays open, nothing is saved.
        app.typeKey(.escape, modifierFlags: [])
        assertRecording(false, "new_tab", in: app)
        XCTAssertTrue(root.exists && root.buttons["DesktopSettingsClose"].firstMatch.exists,
                      "Settings must stay open after Escape cancels the recording")
        XCTAssertEqual(try configText(), before, "A cancelled recording must not change the configuration")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(root.waitForNonExistence(timeout: 5), "The second Escape must close Settings")
    }

    @MainActor
    func testSettingsKeybindingRecorderSaveAndReset() async throws {
        let app = try launchDesktop()
        let root = openSettings(in: app)
        showShortcut("new_tab", in: app)
        startRecording("new_tab", in: app)
        app.typeKey("k", modifierFlags: [.command, .option, .control])
        assertRecording(false, "new_tab", in: app)
        XCTAssertTrue(try configText().contains("keybind = ctrl+opt+cmd+k=new_tab"), "The recorded chord must be saved")
        let reset = shortcutControl("Reset", of: "new_tab", in: app)
        XCTAssertTrue(reset.waitForExistence(timeout: 5), "A custom shortcut must offer its row's Reset")
        reveal(reset, in: app)
        reset.click()
        XCTAssertTrue(reset.waitForNonExistence(timeout: 5), "Reset must leave no custom shortcut to reset")
        XCTAssertFalse(try configText().contains("=new_tab"), "Reset must remove the saved chord")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(root.waitForNonExistence(timeout: 5), "Escape must close Settings")
    }

    @MainActor
    func testSettingsConflictModalCancelAndReassign() async throws {
        let app = try launchDesktop()
        let root = openSettings(in: app)
        showShortcut("new_tab", in: app)
        let conflict = root.descendants(matching: .any)["DesktopShortcutConflict"].firstMatch
        // Cmd+D belongs to Split Right: recording it asks first; Escape cancels.
        startRecording("new_tab", in: app)
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(conflict.waitForExistence(timeout: 5), "Recording a taken chord must show the conflict")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(conflict.waitForNonExistence(timeout: 5), "Escape must cancel the conflict")
        XCTAssertFalse(try configText().contains("=new_tab"), "A cancelled reassignment must not be saved")
        // Again, and Return reassigns.
        startRecording("new_tab", in: app)
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(conflict.waitForExistence(timeout: 5), "The same chord must show the conflict again")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(conflict.waitForNonExistence(timeout: 5), "Return must confirm the reassignment")
        XCTAssertTrue(try configText().contains("keybind = cmd+d=new_tab"), "Reassign must save Cmd+D for New Tab")
        XCTAssertEqual(paneIDs(in: app).count, 1, "Recording Cmd+D must not split the terminal")
        // Restore the default; with Settings closed, Cmd+D splits again.
        let reset = shortcutControl("Reset", of: "new_tab", in: app)
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reveal(reset, in: app)
        reset.click()
        XCTAssertFalse(try configText().contains("=new_tab"), "Reset must restore the default")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(root.waitForNonExistence(timeout: 5), "Escape must close Settings")
        app.typeKey("d", modifierFlags: .command)
        waitForPaneCount(2, in: app)
    }

    @MainActor
    func testModalEventContainment() async throws {
        let app = try launchDesktop()
        let paneID = try XCTUnwrap(paneIDs(in: app).first)
        let root = openSettings(in: app)
        // A menu shortcut stops at open Settings instead of acting on the terminal under it.
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(root.exists, "Settings must stay open")
        XCTAssertEqual(paneIDs(in: app), [paneID], "Cmd+D must not split the terminal behind Settings")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(root.waitForNonExistence(timeout: 5), "Escape must close Settings")
        // The same key splits once Settings is closed, so the check above was not vacuous.
        app.typeKey("d", modifierFlags: .command)
        waitForPaneCount(2, in: app)
    }

    /// The Keys page, filtered to `action`'s row (`DesktopShortcut-<action>`).
    @MainActor private func showShortcut(_ action: String, in app: XCUIApplication) {
        selectSection("keys", in: app)
        setText(action, field: settings(in: app).textFields["DesktopShortcutFilter"].firstMatch, in: app)
        let row = settings(in: app).descendants(matching: .any)["DesktopShortcut-\(action)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The Keys filter must show \(action)")
    }

    /// The row's own Record or Reset button, by its exact identifier:
    /// `DesktopShortcut<kind>-<action>` unselected, `DesktopShortcut<kind>` selected.
    @MainActor private func shortcutControl(_ kind: String, of action: String, in app: XCUIApplication) -> XCUIElement {
        let row = settings(in: app).descendants(matching: .any)["DesktopShortcut-\(action)"].firstMatch
        let ids = ["DesktopShortcut\(kind)-\(action)", "DesktopShortcut\(kind)"]
        return row.buttons.matching(NSPredicate(format: "identifier IN %@", ids)).firstMatch
    }

    @MainActor private func startRecording(_ action: String, in app: XCUIApplication) {
        let record = shortcutControl("Record", of: action, in: app)
        XCTAssertTrue(record.waitForExistence(timeout: 5), "\(action) must have its Record button")
        reveal(record, in: app)
        record.click()
        assertRecording(true, action, in: app)
    }

    @MainActor private func assertRecording(_ recording: Bool, _ action: String, in app: XCUIApplication,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let label = recording ? "Recording Shortcut" : "Record Shortcut"
        let state = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label),
                                              object: shortcutControl("Record", of: action, in: app))
        XCTAssertEqual(XCTWaiter.wait(for: [state], timeout: 3), .completed,
                       "\(action) must be \(recording ? "recording" : "idle")", file: file, line: line)
    }

    @MainActor
    func testSessionSidebarToggle() async throws {
        let app = try takoApplication()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "Terminal window should appear")

        let sidebar = app.descendants(matching: .any)["SessionSidebar"].firstMatch
        let sessionsHeader = app.descendants(matching: .any)["SessionSidebarHeader"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "Permanent session sidebar must be visible from launch")
        XCTAssertTrue(sessionsHeader.exists, "Session sidebar header must be visible from launch")

        // Legacy shortcut Cmd+Option+S and Escape must NOT hide the permanent sidebar
        app.typeKey("s", modifierFlags: [.command, .option])
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sidebar.exists && sessionsHeader.exists, "Session sidebar must remain permanently open")
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
        request.recognitionLevel = .accurate
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
        // NSImage's nominal size can be pixel-sized. AX frames use display
        // points, so derive Retina scaling from the actual display bounds.
        let displayBounds = CGDisplayBounds(CGMainDisplayID())
        let screenWidthPts = displayBounds.width
        let screenHeightPts = displayBounds.height
        guard screenWidthPts > 0, screenHeightPts > 0 else {
            throw ScreenObservationError.windowROICropFailed(windowFrame)
        }

        let scaleX = CGFloat(fullCGImage.width) / screenWidthPts
        let scaleY = CGFloat(fullCGImage.height) / screenHeightPts

        // XCUIElement.frame coordinates are top-left screen points (Quartz display coordinates).
        // CGImage pixel coordinates also place (0, 0) at the top-left row/column.
        let visibleFrame = windowFrame.intersection(displayBounds)
        let cropPixelRect = CGRect(
            x: (visibleFrame.origin.x - displayBounds.origin.x) * scaleX,
            y: (visibleFrame.origin.y - displayBounds.origin.y) * scaleY,
            width: visibleFrame.size.width * scaleX,
            height: visibleFrame.size.height * scaleY
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

        let app = try takoApplication()
        app.activate()
        let appWindow = app.windows.firstMatch
        XCTAssertTrue(appWindow.waitForExistence(timeout: 5), "Terminal window should appear")

        let preOpenScreenshot = XCUIScreen.main.screenshot()
        let preOpenAttachment = XCTAttachment(screenshot: preOpenScreenshot)
        preOpenAttachment.name = "PreOpen-NegativeControl"
        preOpenAttachment.lifetime = .keepAlways
        self.add(preOpenAttachment)

        // Vision failures throw; they cannot satisfy this negative control.
        let preOpenWindowCGImage = try cropToWindowROI(screenshot: preOpenScreenshot, window: appWindow)
        let preOpenTexts = try extractRecognizedText(from: preOpenWindowCGImage)
        let preOpenHasOverview = preOpenTexts.contains { $0.text.localizedCaseInsensitiveContains("Pane Overview") }
        XCTAssertFalse(preOpenHasOverview, "Pane Overview header text must be absent within the window ROI before open action")

        let tTrigger = CFAbsoluteTimeGetCurrent()
        app.typeKey("o", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.descendants(matching: .any)["PaneOverviewHeader"].waitForExistence(timeout: 2),
                      "Pane Overview must be visible before capturing its frame")

        // Capture-only latency excludes the UI driver's key injection and
        // one-second AX polling interval. Full Row 63 input-to-frame remains open.
        let captureStart = CFAbsoluteTimeGetCurrent()
        let overviewScreenshot = XCUIScreen.main.screenshot()
        let captureElapsedMs = (CFAbsoluteTimeGetCurrent() - captureStart) * 1000.0
        let triggerToCaptureMs = (CFAbsoluteTimeGetCurrent() - tTrigger) * 1000.0
        print("[SCREEN_OBSERVATION] Capture=\(captureElapsedMs)ms; trigger-to-capture including UI automation=\(triggerToCaptureMs)ms")

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

        // Full Row 63 acceptance remains catalogued as OPEN in docs/feature_registry.md.
        print("[SCREEN_OBSERVATION] Capture-only roundtrip: \(captureElapsedMs)ms vs 150.0ms budget")
        XCTAssertLessThan(captureElapsedMs, 150.0, "Screen capture roundtrip must complete within 150ms budget")
    }
}

