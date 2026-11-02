/*
 * tako — Isolated macOS appearance UI fixtures
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import XCTest

@MainActor final class TakoScopedAppearanceHelpers {
    enum ObservationError: Error { case unavailable(String) }
    static let bundleID = "com.tako-core.terminal.uitest"
    let testRoot: URL
    let configFile: URL
    let defaultsSuite: String
    let support: URL
    private let savedSupport: URL
    private let previousApp: NSRunningApplication?
    private(set) var app: XCUIApplication?

    init() throws {
        testRoot = FileManager.default.temporaryDirectory.appendingPathComponent("tako-ui-\(UUID().uuidString)")
        configFile = testRoot.appendingPathComponent("config")
        defaultsSuite = "TAKO_UI_TESTS_SCOPED_\(UUID().uuidString)"
        support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(Self.bundleID)
        savedSupport = testRoot.appendingPathComponent("previous-test-support")
        previousApp = NSWorkspace.shared.frontmostApplication
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        let initial = """
        window-save-state = never
        macos-titlebar-style = tabs
        tab-style = pill
        session-persistence = false
        confirm-close-surface = never
        remote-control = on
        auto-update = off
        command = /bin/sh
        shell-integration = none
        cursor-style-blink = false
        theme = TakoCore
        working-directory = \(testRoot.path)
        """
        try initial.write(to: configFile, atomically: true, encoding: .utf8)
        if FileManager.default.fileExists(atPath: support.path) { try FileManager.default.moveItem(at: support, to: savedSupport) }
    }

    func launchIsolatedApp() throws -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "--no-update", "--no-launch-notices"]
        application.launchEnvironment["TAKO_CONFIG_PATH"] = configFile.path
        application.launchEnvironment["TAKO_USER_DEFAULTS_SUITE"] = defaultsSuite
        application.launchEnvironment["TAKO_SESSIONS_HOME"] = testRoot.appendingPathComponent("sessions").path
        application.launchEnvironment["TAKO_AGENT_HOOKS_HOME"] = testRoot.appendingPathComponent("hooks").path
        application.launchEnvironment["CODEX_HOME"] = testRoot.appendingPathComponent("hooks/.codex").path
        application.launchEnvironment["TAKO_NO_UPDATE"] = "1"
        application.launchEnvironment["TAKO_NO_LAUNCH_NOTICES"] = "1"
        application.launch()
        self.app = application
        XCTAssertTrue(application.windows.firstMatch.waitForExistence(timeout: 10))
        let id = try XCTUnwrap(paneIDs().first)
        _ = try control(["title", "Scope Primary", "--target", id])
        return application
    }

    func cleanup() {
        if let app, app.state != .notRunning { app.terminate() }
        guard app == nil || app?.state == .notRunning else {
            XCTFail("Isolated test app did not stop; profile and backup retained at \(testRoot.path)")
            return
        }
        // The fixed test bundle is separate from the installed operator app.
        do {
            if FileManager.default.fileExists(atPath: support.path) { try FileManager.default.removeItem(at: support) }
            if FileManager.default.fileExists(atPath: savedSupport.path) { try FileManager.default.moveItem(at: savedSupport, to: support) }
            try FileManager.default.removeItem(at: testRoot)
        } catch {
            XCTFail("Test cleanup failed; backup retained at \(testRoot.path): \(error)")
        }
        UserDefaults(suiteName: defaultsSuite)?.removePersistentDomain(forName: defaultsSuite)
        previousApp?.activate(options: [])
    }

    func control(_ args: [String]) throws -> String {
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first,
              let bundle = process.bundleURL else { throw ObservationError.unavailable("Isolated app is not running") }
        let child = Process()
        child.executableURL = bundle.appendingPathComponent("Contents/MacOS/takoctl")
        child.arguments = ["--bundle-id", Self.bundleID] + args
        let out = Pipe(), err = Pipe()
        child.standardOutput = out; child.standardError = err
        try child.run()
        child.waitUntilExit()
        guard child.terminationStatus == 0 else {
            throw ObservationError.unavailable(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func paneIDs() throws -> [String] {
        guard let outer = try JSONSerialization.jsonObject(with: Data(control(["tree", "--json"]).utf8)) as? [String: Any] else {
            throw ObservationError.unavailable("Malformed tree response")
        }
        let result = outer["result"] as? [String: Any] ?? outer
        return (result["windows"] as? [[String: Any]] ?? []).flatMap { $0["tabs"] as? [[String: Any]] ?? [] }
            .flatMap { $0["panes"] as? [[String: Any]] ?? [] }.compactMap { $0["id"] as? String }
    }

    func paneStyle(_ id: String) throws -> [String: String] {
        let data = try Data(contentsOf: support.appendingPathComponent("Appearance.json"))
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ObservationError.unavailable("Malformed style document")
        }
        return (document["panes"] as? [String: [String: String]])?[id.uppercased()] ?? [:]
    }

    static func wait(_ predicate: @escaping () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    static func assertValue(_ element: XCUIElement, contains text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(wait { (element.value as? String)?.contains(text) == true }, "Expected '\(text)', got '\(element.value ?? "nil")'", file: file, line: line)
    }

    static func openSidebar(in app: XCUIApplication) {
        let header = app.descendants(matching: .any)["SessionSidebarHeader"]
        if !header.exists { app.typeKey("s", modifierFlags: [.command, .option]) }
        XCTAssertTrue(header.waitForExistence(timeout: 5))
    }

    static func openWorkspaceAppearance(in app: XCUIApplication) -> XCUIElement {
        openSidebar(in: app)
        let row = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH[c] 'DEFAULT' OR label BEGINSWITH[c] 'DEFAULT'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        let item = app.menuItems["Workspace Appearance…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.click()
        let dialog = app.groups["TerminalSettingsDialog"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        return dialog
    }

    static func openPaneAppearance(in app: XCUIApplication, title: String = "Scope Primary", isChild: Bool = false) -> XCUIElement {
        openSidebar(in: app)
        let predicate = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", title, title)
        XCTAssertTrue(wait { app.staticTexts.matching(predicate).count > 0 })
        let edge = app.descendants(matching: .any)["SessionSidebarHeader"].frame.maxX + 20
        let rows = app.staticTexts.matching(predicate).allElementsBoundByIndex.filter { $0.frame.minX < edge }.sorted { $0.frame.midY < $1.frame.midY }
        guard let row = isChild ? rows.last : rows.first else { XCTFail("Missing exact sidebar row '\(title)'"); return app.groups["missing"] }
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        let item = app.menuItems[isChild ? "Pane Appearance…" : "Terminal Appearance…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.click()
        let dialog = app.groups["TerminalSettingsDialog"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        return dialog
    }

    static func search(_ text: String, in dialog: XCUIElement) {
        let field = dialog.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.click()
        field.typeKey("a", modifierFlags: .command); field.typeKey(.delete, modifierFlags: [])
        if !text.isEmpty { field.typeText(text) }
        field.typeKey(.downArrow, modifierFlags: [])
    }

    static func dismissDialog(_ dialog: XCUIElement, in app: XCUIApplication) {
        let button = app.buttons["SettingsCloseButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5)); button.click()
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 5))
    }

    static func attachScreenshot(_ screenshot: XCUIScreenshot, name: String, to test: XCTestCase) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways
        test.add(attachment)
    }
}
