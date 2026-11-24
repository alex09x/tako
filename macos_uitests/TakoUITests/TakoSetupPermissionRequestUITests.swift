// Tako — opt-in native permission request journeys on the test Mac
// Copyright (c) 2026 Alexander Panasenko
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import AppKit
import Vision
import XCTest

@MainActor
final class TakoSetupPermissionRequestUITests: TakoCustomConfigCase {
    private var nativeMonitor: NSObjectProtocol?
    private var monitoredDeclines = 0

    override func setUp() async throws {
        let mode = try? String(contentsOfFile: "/private/tmp/tkui/native-permission-actions.mode", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == "deny" {
            let metadata = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("TakoCore.app/Contents/Info.plist")
            let read = Task.detached { (try? Data(contentsOf: metadata)) != nil }
            _ = try await declineNativeRequests(containing: ["local network", "devices"])
            let readable = await read.value
            XCTAssertTrue(readable, "Authorize only this runner's public test-host metadata before any app lifecycle operation")
        }
        try await super.setUp()
    }

    override func tearDown() async throws {
        try await super.tearDown()
        if let nativeMonitor { removeUIInterruptionMonitor(nativeMonitor) }
        nativeMonitor = nil
    }

    func testFolderCheckFinishesAfterNativeRequests() async throws {
        let app = try await openPermissions()
        let card = app.buttons["SetupPermission-protectedFolders"]
        card.click()
        app.staticTexts["Permissions"].firstMatch.click()
        _ = try await declineNativeRequests(containing: ["Desktop", "Documents", "Downloads"])
        app.activate()
        let result = NSPredicate { _, _ in (card.value as? String)?.contains("of 3 readable") == true }
        await fulfillment(of: [expectation(for: result, evaluatedWith: card)], timeout: 8)
        XCTAssertTrue(card.isEnabled)
        attach(app, name: "Folder check result after native consent")
    }

    func testMicrophoneRequestAndDeniedSettingsRoute() async throws {
        let app = try await openPermissions()
        let card = app.buttons["SetupPermission-microphone"]
        let before = card.value as? String
        monitoredDeclines = 0
        card.click()
        app.staticTexts["Permissions"].firstMatch.click()
        let declined = try await declineNativeRequests(containing: ["microphone"])
        if before == "Not Requested" { XCTAssertEqual(declined + monitoredDeclines, 1, "The native microphone prompt must appear") }
        app.activate()
        if before != "Allowed" {
            let denied = NSPredicate(format: "value == %@", "Denied")
            await fulfillment(of: [expectation(for: denied, evaluatedWith: card)], timeout: 5)
        }
        card.click()
        try await assertSettingsPage(["Microphone"])
        app.activate()
        XCTAssertTrue(card.isHittable)
        attach(app, name: "Microphone status after native response")
    }

    func testScreenRequestThenOffersSettings() async throws {
        let app = try await openPermissions()
        let card = app.buttons["SetupPermission-screenCapture"]
        let before = card.value as? String
        card.click()
        app.staticTexts["Permissions"].firstMatch.click()
        _ = try await declineNativeRequests(containing: ["screen", "record"])
        app.activate()
        XCTAssertEqual(card.value as? String, before == "Allowed" ? "Allowed" : "Not Allowed")
        // Public preflight cannot distinguish an earlier denial from not asked.
        // A completed attempt must still give the user a useful next action.
        card.click()
        try await assertSettingsPage(["Screen & System Audio Recording", "Screen Recording"])
        app.activate()
        XCTAssertTrue(card.isHittable)
        attach(app, name: "Screen access after native response")
    }

    func testLocalNetworkAttemptThenOpensSettings() async throws {
        let app = try await openPermissions()
        let card = app.buttons["SetupPermission-localNetwork"]
        card.click()
        app.staticTexts["Permissions"].firstMatch.click()
        _ = try await declineNativeRequests(containing: ["local network", "devices"])
        app.activate()
        let attempted = NSPredicate(format: "value == %@", "Open Settings")
        await fulfillment(of: [expectation(for: attempted, evaluatedWith: card)], timeout: 5)
        card.click()
        // Tahoe may ignore the Local Network anchor. The app must expose
        // the remaining native path rather than imply that a grant happened.
        try await assertSettingsPage(["Local Network", "Privacy & Security"])
        app.activate()
        XCTAssertTrue(card.isHittable)
        let path = app.staticTexts["SetupMessage"]
        XCTAssertTrue(path.exists)
        XCTAssertTrue((path.label + " " + (path.value as? String ?? "")).contains("Privacy & Security → Local Network"))
        XCTAssertNotEqual(card.value as? String, "Allowed", "A UDP attempt is not a verified grant")
        attach(app, name: "Local Network after explicit request")
    }

    func testAppControlOpensAutomationSettingsDirectly() async throws {
        let app = try await openPermissions()
        let card = app.buttons["SetupPermission-automation"]
        card.click()
        try await assertSettingsPage(["Automation"])
        app.activate()
        XCTAssertFalse(app.descendants(matching: .any)["SetupPermissionExplanation-automation"].exists)
        XCTAssertTrue(card.isHittable)
        attach(app, name: "App control returns to the same permission page")
    }

    private func openPermissions() async throws -> XCUIApplication {
        let mode = try? String(contentsOfFile: "/private/tmp/tkui/native-permission-actions.mode", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try XCTSkipUnless(mode == "deny", "Native consent tests require explicit test-Mac arming; no TCC reset")
        nativeMonitor = addUIInterruptionMonitor(withDescription: "Only this isolated Tako permission request") { [weak self] alert in
            let text = ([alert.label] + alert.staticTexts.allElementsBoundByIndex.map {
                $0.label + " " + ($0.value as? String ?? "")
            }).joined(separator: " ")
            let ownsHost = text.contains("TakoCore") || text.contains("“Tako”") || text.contains("\"Tako\"")
            if (ownsHost || text.contains("TakoUITests-Runner")) && text.localizedCaseInsensitiveContains("removable volume") {
                let allow = alert.buttons["Allow"].firstMatch
                guard allow.exists else { return false }
                allow.click()
                return true
            }
            let capabilities = ["Desktop", "Documents", "Downloads", "microphone", "screen", "record", "local network", "devices"]
            guard ownsHost, capabilities.contains(where: { text.localizedCaseInsensitiveContains($0) }) else { return false }
            let decline = ["Don't Allow", "Don’t Allow", "Not Now", "Later", "Cancel"]
                .map { alert.buttons[$0].firstMatch }.first { $0.exists && $0.isHittable }
            guard let decline else { return false }
            let image = XCTAttachment(screenshot: alert.screenshot())
            image.name = "Native system permission handled by XCTest"
            image.lifetime = .keepAlways
            self?.add(image)
            print("NATIVE_PERMISSION_MONITOR \(text)")
            decline.click()
            self?.monitoredDeclines += 1
            return true
        }
        let app = try takoApplication()
        app.launch()
        _ = try await declineNativeRequests(containing: ["local network", "devices"])
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        app.menuBars.menuBarItems.element(boundBy: 1).click()
        app.menuItems["Set Up Tako…"].click()
        // The welcome hero (A14) has no stage bar: Get Started leads to it. The Permissions
        // stage is named by its first step, notifications.
        let permissions = app.buttons["SetupStep-notifications"]
        XCTAssertTrue(app.buttons["SetupNext"].waitForExistence(timeout: 5))
        if !permissions.exists {
            XCTAssertEqual(app.buttons["SetupNext"].label, "Get Started")
            app.buttons["SetupNext"].click()
        }
        XCTAssertTrue(permissions.waitForExistence(timeout: 5))
        permissions.click()
        XCTAssertTrue(app.buttons["SetupPermission-microphone"].waitForExistence(timeout: 5))
        return app
    }

    private func declineNativeRequests(containing keywords: [String]) async throws -> Int {
        let agents = ["com.apple.UserNotificationCenter", "com.apple.coreservices.uiagent"]
            .map { ($0, XCUIApplication(bundleIdentifier: $0)) }
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = "Screen after requesting \(keywords.first ?? "test-volume")"
        screen.lifetime = .keepAlways
        add(screen)
        let deadline = Date().addingTimeInterval(6)
        var declined = 0
        while Date() < deadline {
          for (agentID, system) in agents where system.state != .notRunning {
            let dialogs = system.dialogs.allElementsBoundByIndex
            let surfaces = dialogs + system.alerts.allElementsBoundByIndex + system.windows.allElementsBoundByIndex
            for window in surfaces {
                let text = window.staticTexts.allElementsBoundByIndex.map {
                    $0.label + " " + ($0.value as? String ?? "")
                }.joined(separator: " ")
                let ownsDialog = text.contains("TakoCore") || text.contains("TakoUITests-Runner")
                if ownsDialog && text.localizedCaseInsensitiveContains("removable volume") {
                    let allow = window.buttons["Allow"].firstMatch
                    if allow.exists && allow.isHittable {
                        allow.click()
                        print("TEST_STAND_VOLUME_ALLOWED \(text)")
                    }
                    continue
                }
                let isHost = text.contains("TakoCore") || text.contains("“Tako”") || text.contains("\"Tako\"")
                guard isHost, keywords.contains(where: { text.localizedCaseInsensitiveContains($0) }) else { continue }
                // UserNotificationCenter exposes its action title to identifier
                // lookup even when XCUIElement.label is empty on macOS 26.
                let decline = ["Don't Allow", "Don’t Allow", "Not Now", "Later", "Cancel"]
                    .map { window.buttons[$0].firstMatch }.first { $0.exists && $0.isHittable }
                guard let decline else { continue }
                let image = XCTAttachment(screenshot: window.screenshot())
                image.name = "Native permission request \(keywords[0])"
                image.lifetime = .keepAlways
                add(image)
                print("NATIVE_PERMISSION_RESPONSE agent=\(agentID) keywords=\(keywords) action=\(decline.identifier)")
                decline.click()
                declined += 1
            }
          }
            try await Task.sleep(for: .milliseconds(200))
        }
        return declined
    }

    private func assertSettingsPage(_ titles: [String], file: StaticString = #filePath, line: UInt = #line) async throws {
        _ = try await declineNativeRequests(containing: [])
        let settings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        let deadline = Date().addingTimeInterval(8)
        var observed: [String] = []
        while Date() < deadline {
            let screenshot = XCUIScreen.main.screenshot()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.regionOfInterest = try settingsTitleRegion()
            try VNImageRequestHandler(data: screenshot.pngRepresentation).perform([request])
            observed = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let normalize: (String) -> String = { $0.lowercased().filter { !$0.isWhitespace } }
            if settings.state == .runningForeground && titles.contains(where: { expected in
                observed.contains { normalize($0) == normalize(expected) }
            }) {
                let image = XCTAttachment(screenshot: screenshot)
                image.name = "System Settings route \(titles[0])"
                image.lifetime = .keepAlways
                add(image)
                print("SETTINGS_HEADER_CONFIRMED \(observed)")
                await closeTestSettings()
                return
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "Unexpected System Settings route"
        image.lifetime = .keepAlways
        add(image)
        print("SETTINGS_HEADER_MISMATCH expected=\(titles) observed=\(observed)")
        let evidence = URL(fileURLWithPath: "/private/tmp/tkui/settings-route-mismatch.png")
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: evidence)
        await closeTestSettings()
        XCTFail("Expected Settings title \(titles), observed \(observed)", file: file, line: line)
    }

    private func closeTestSettings() async {
        // The test owns this Settings presentation. Close it before XCTest's
        // failure collector tries to snapshot its entire app/permission list.
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else { return }
        _ = app.terminate()
        for _ in 0..<30 {
            if app.isTerminated { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func settingsTitleRegion() throws -> CGRect {
        // Settings' AX snapshot enumerates app icons and can re-enter TCC on
        // removable storage. Keep Tako assertions in AX; read the OS page title
        // from its real window's toolbar, without enumerating its app list.
        let pid = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first).processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let bounds = windows.compactMap { info -> CGRect? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let dictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  rect.width > 300, rect.height > 200 else { return nil }
            return rect
        }.max { $0.width * $0.height < $1.width * $1.height }
        let window = try XCTUnwrap(bounds, "The native Settings window must be visible")
        let display = CGDisplayBounds(CGMainDisplayID())
        let title = CGRect(x: window.minX + window.width * 0.36, y: window.minY,
                           width: window.width * 0.64, height: 60)
        return CGRect(x: (title.minX - display.minX) / display.width,
                      y: 1 - (title.maxY - display.minY) / display.height,
                      width: title.width / display.width, height: title.height / display.height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let wizard = app.descendants(matching: .any)["SetupWizard"].firstMatch
        let image = XCTAttachment(screenshot: wizard.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
