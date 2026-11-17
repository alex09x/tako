/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import XCTest

class TakoFloatingTerminalCase: TakoCustomConfigCase {
    /// Frozen desktop reference: `DesktopCanvasMetrics.paneHeaderHeight`.
    static let expectedPaneHeaderHeight: CGFloat = 28
    /// `DesktopCanvasMetrics.paneGap`: a tile and the maximized card sit this far in from the canvas.
    static let canvasPaneGap: CGFloat = 8
    /// `FloatingPaneGeometry.bodyInsets.bottom`: the terminal's margin inside its card.
    static let paneBodyBottomInset: CGFloat = 6
    private var launchedApp: XCUIApplication?
    private var persistentFixture = false
    private var loggedWindowInventory = false
    private var fixtureFiles: [URL] = []

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        await MainActor.run { [self] in
            guard let app = self.launchedApp else { return }
            if self.persistentFixture {
                if app.state == .notRunning { app.launch() }
                app.activate()
                if app.windows.firstMatch.waitForExistence(timeout: 5) {
                    // Explicitly close this fixture's whole window group, including minimized panes.
                    app.typeKey("w", modifierFlags: [.command, .shift])
                    _ = app.windows.firstMatch.waitForNonExistence(timeout: 5)
                }
            }
            app.terminate()
            for file in self.fixtureFiles { try? FileManager.default.removeItem(at: file) }
            self.fixtureFiles.removeAll()
        }
        try await super.tearDown()
    }

    @MainActor
    func launchFloatingApp(persistent: Bool = false, confirmClose: Bool = false) throws -> XCUIApplication {
        try updateConfig("""
        macos-titlebar-style = tabs
        window-width = 110
        window-height = 32
        confirm-close-surface = \(confirmClose ? "true" : "false")
        auto-update = off
        window-save-state = \(persistent ? "always" : "never")
        session-persistence = \(persistent ? "true" : "false")
        """)
        persistentFixture = persistent
        let app = try takoApplication()
        launchedApp = app
        app.launch()
        XCTAssertTrue(canvas(in: app).waitForExistence(timeout: 10))
        waitForPaneCount(1, in: app)
        if persistent {
            // Start this fixture fresh; only its deliberate subsequent relaunch may restore state.
            app.launchArguments.removeAll { $0 == "-ApplePersistenceIgnoreState" || $0 == "YES" }
        }
        return app
    }

    @MainActor
    func activeWindow(in app: XCUIApplication) -> XCUIElement {
        let owners = app.windows.matching(identifier: "TerminalWindowRestoration").allElementsBoundByIndex
        let candidates = (owners.isEmpty ? app.windows.allElementsBoundByIndex : owners)
            .filter { $0.frame.height > 100 }
        if !loggedWindowInventory {
            loggedWindowInventory = true
            logTestProgress("floating fixture window candidates: \(candidates.count)")
        }
        if candidates.count == 1 { return candidates[0] }
        return candidates.first(where: \.isHittable) ?? app.windows.firstMatch
    }

    @MainActor
    func canvas(in app: XCUIApplication) -> XCUIElement {
        activeWindow(in: app).descendants(matching: .any)["FloatingTerminalCanvas"].firstMatch
    }

    @MainActor
    func paneIDs(in app: XCUIApplication) -> [String] {
        var seen: Set<String> = []
        return canvas(in: app).descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'FloatingPane-'"))
            .allElementsBoundByIndex.compactMap { element in
                let id = String(element.identifier.dropFirst("FloatingPane-".count))
                guard UUID(uuidString: id) != nil, seen.insert(id).inserted else { return nil }
                return id
            }
    }

    @MainActor
    func pane(_ id: String, in app: XCUIApplication) -> XCUIElement {
        canvas(in: app).descendants(matching: .any)["FloatingPane-\(id)"].firstMatch
    }

    @MainActor
    func header(_ id: String, in app: XCUIApplication) -> XCUIElement {
        canvas(in: app).descendants(matching: .any)["FloatingPaneHeader-\(id)"].firstMatch
    }

    @MainActor
    func control(_ action: String, pane id: String, in app: XCUIApplication) -> XCUIElement {
        canvas(in: app).buttons["FloatingPane\(action)-\(id)"].firstMatch
    }

    @MainActor
    func minimizedCard(_ id: String, in app: XCUIApplication) -> XCUIElement {
        canvas(in: app).buttons["FloatingMinimizedCard-\(id)"].firstMatch
    }

    /// Out of maximized, back to a normal pane. Panes tile by default, and a tile
    /// has no resize handles: a test that drags or resizes a pane floats it first.
    @MainActor
    func restorePaneToNormal(_ id: String, in app: XCUIApplication) {
        let zoom = control("Maximize", pane: id, in: app)
        if (zoom.value as? String) != "normal" { zoom.click() }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'normal'"), object: zoom)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        XCTAssertTrue(header(id, in: app).waitForExistence(timeout: 5))
    }

    /// Takes a pane out of the grid with its own Float control, as a person
    /// does, and waits for the handles only a floating pane has.
    @MainActor
    func floatPane(_ id: String, in app: XCUIApplication) {
        let toggle = control("Float", pane: id, in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if (toggle.value as? String) != "floating" { toggle.click() }
        let floating = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'floating'"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [floating], timeout: 5), .completed)
        let corner = canvas(in: app).descendants(matching: .any)["FloatingPaneResize-bottomTrailing-\(id)"].firstMatch
        XCTAssertTrue(corner.waitForExistence(timeout: 5))
        let interactive = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in corner.isHittable }, object: corner)
        XCTAssertEqual(XCTWaiter.wait(for: [interactive], timeout: 5), .completed)
    }

    @MainActor
    func focusThroughSidebar(_ id: String, in app: XCUIApplication) throws {
        let sidebar = activeWindow(in: app).descendants(matching: .any)["SessionSidebar"].firstMatch
        let childRows = sidebar.descendants(matching: .any)
            .matching(identifier: "session-pane-\(id)")
            .allElementsBoundByIndex.filter(\.isHittable)
        let matches = childRows.isEmpty ? sidebar.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier ENDSWITH %@", id))
            .allElementsBoundByIndex.filter(\.isHittable) : childRows
        let row = try XCTUnwrap(matches.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        row.click()
    }

    @MainActor
    func waitForPaneCount(_ count: Int, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        logTestProgress("floating fixture wait for \(count) mounted panes")
        let predicate = NSPredicate { [self] _, _ in paneIDs(in: app).count == count }
        let ready = XCTNSPredicateExpectation(predicate: predicate, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 7), .completed,
                       "Expected \(count) mounted terminal windows", file: file, line: line)
    }

    @MainActor
    func waitForFullscreen(_ enabled: Bool, normalFrame: CGRect, in app: XCUIApplication) {
        let predicate = NSPredicate { [self] _, _ in
            let frame = activeWindow(in: app).frame
            if enabled { return frame.height > normalFrame.height + 20 }
            return abs(frame.height - normalFrame.height) < 3 && abs(frame.width - normalFrame.width) < 3
        }
        let ready = XCTNSPredicateExpectation(predicate: predicate, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, "Outer fullscreen transition must finish")
    }

    @MainActor
    func waitForStatus(_ status: String, on element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", status, status)
        let ready = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 7), .completed,
                       "Expected live status \(status)", file: file, line: line)
    }

    @MainActor
    func shellPID(_ id: String, phase: String, in app: XCUIApplication, focus: Bool = true) throws -> Int {
        let terminal = pane(id, in: app).textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        if focus { terminal.click() }
        let marker = "FLOAT-PID-\(phase)-"
        let command = #"/bin/sh -c 'printf "FLOAT""-PID-\#(phase)-%s\n" "$PPID"'"#
        app.typeText(command + "\n")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", marker), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 7), .completed, "Input must reach the intended terminal")
        let text = try XCTUnwrap(terminal.value as? String)
        let regex = try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: marker) + "([0-9]+)")
        let match = try XCTUnwrap(regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).last)
        let range = try XCTUnwrap(Range(match.range(at: 1), in: text))
        return try XCTUnwrap(Int(text[range]))
    }

    @MainActor
    func emitStatusUntilSignalled(_ id: String, in app: XCUIApplication) throws -> URL {
        let shared = URL(fileURLWithPath: "/private/tmp/tkui")
        let stem = "floating-status-\(UUID().uuidString)"
        let flag = shared.appendingPathComponent(stem + ".done")
        let programFile = shared.appendingPathComponent(stem + ".py")
        fixtureFiles.append(contentsOf: [flag, programFile])
        let encoded = try JSONSerialization.data(withJSONObject: flag.path, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        let path = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let program = #"""
        import pathlib, sys, time
        flag = pathlib.Path(\#(path))
        def emit(state):
            sys.stdout.write("\x1b]7501;state=" + state + ":app=codex\x1b\\")
            sys.stdout.flush()
        emit("working")
        deadline = time.monotonic() + 90
        while not flag.exists():
            if time.monotonic() > deadline:
                raise RuntimeError("fixture timeout")
            time.sleep(0.05)
        emit("done")
        """#
        try program.write(to: programFile, atomically: true, encoding: .utf8)
        pane(id, in: app).textViews.firstMatch.click()
        app.typeText("/usr/bin/python3 '\(programFile.path)'\n")
        waitForStatus("working", on: pane(id, in: app))
        return flag
    }

    @MainActor
    func assertRect(_ actual: CGRect, equals expected: CGRect, accuracy: CGFloat = 3,
                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, file: file, line: line)
    }

    @MainActor
    func attachCanvas(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: activeWindow(in: app).screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
