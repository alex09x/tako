/*
 * tako — Real CLI/socket control reflected by native terminal windows and settings
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import CryptoKit
import XCTest

final class TakoControlCLIUITests: TakoDesktopDesignCase {
    private var controlSocket: String?

    private func launchControlledDesktop() throws -> XCUIApplication {
        let app = try launchDesktop(configuration: "remote-control = on")
        let id = try XCTUnwrap(paneIDs(in: app).first)
        let path = designDirectory.appendingPathComponent("control-socket")
        pane(id, in: app).textViews.firstMatch.click()
        app.typeText("printf '%s' \"$TAKO_SOCKET\" > '\(path.path)'\n")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: path.path)
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 7), .completed)
        let socket = try String(contentsOf: path, encoding: .utf8)
        let digest = SHA256.hash(data: Data(Self.testBundleID.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(URL(fileURLWithPath: socket).lastPathComponent, "tako-ctl-\(digest.prefix(12)).sock")
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket), "The test host must actually serve its socket")
        controlSocket = socket
        return app
    }

    /// Resolves only this fixture's running host, never the installed app or an inherited socket.
    private func cli(_ arguments: [String], succeeds: Bool = true) throws -> [String: Any] {
        let hosts = NSRunningApplication.runningApplications(withBundleIdentifier: Self.testBundleID)
        XCTAssertEqual(hosts.count, 1)
        let host = try XCTUnwrap(hosts.first?.bundleURL)
        let process = Process(), output = Pipe()
        process.executableURL = host.appendingPathComponent("Contents/MacOS/takoctl")
        // The runner's confstr temp directory is container-relative and too long
        // for sockaddr_un. Use the address this test host gave its own shell.
        process.arguments = ["--bundle-id", Self.testBundleID, "--socket", try XCTUnwrap(controlSocket), "--json"] + arguments
        var environment = ProcessInfo.processInfo.environment
        for key in ["TAKO_SOCKET", "TAKO_SURFACE_ID", "TAKO_CLIENT", "TAKO_CLIENT_ID"] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Drain before wait: a tree/config response may exceed the pipe's capacity.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        if !succeeds {
            XCTAssertNotEqual(process.terminationStatus, 0, "Malformed request ran: \(arguments): \(text)")
            return [:]
        }
        XCTAssertEqual(process.terminationStatus, 0, "\(arguments): \(text)")
        let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(response["ok"] as? Bool, true, text)
        return try XCTUnwrap(response["result"] as? [String: Any])
    }

    private func treePanes() throws -> [[String: Any]] {
        let windows = try XCTUnwrap(try cli(["tree"])["windows"] as? [[String: Any]])
        return windows.flatMap { ($0["tabs"] as? [[String: Any]] ?? []).flatMap {
            $0["panes"] as? [[String: Any]] ?? []
        } }
    }

    private func assertFocus(_ id: String) throws {
        let focused = try treePanes().filter { $0["focused"] as? Bool == true }
        XCTAssertEqual(focused.compactMap { $0["id"] as? String }, [id])
    }

    /// Check the actual keyboard target as well as the controller's reported focus.
    private func assertKeyboard(_ id: String, in app: XCUIApplication) {
        let marker = UUID().uuidString
        app.typeText("printf 'CLI'\"\"'-KEYBOARD-\(marker)\\n'\n")
        let terminal = pane(id, in: app).textViews.firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "CLI-KEYBOARD-\(marker)"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 7), .completed,
                       "Typing without a click must still reach the original terminal")
    }

    func testCLIControlsTheSamePaneAndWritesWhileItIsOnTheShelf() throws {
        let app = try launchControlledDesktop()
        let original = try XCTUnwrap(paneIDs(in: app).first)
        let originalProcess = try shellPID(original, phase: "CLI_ORIGINAL", in: app)
        let made = try cli(["split", "right", "--target", original, "--state", "floating", "--no-select"])
        let id = try XCTUnwrap(made["id"] as? String)
        XCTAssertEqual(made["state"] as? String, "floating")
        waitForPaneCount(2, in: app)
        XCTAssertEqual(control("Float", pane: id, in: app).value as? String, "floating")
        try assertFocus(original)
        assertKeyboard(original, in: app)
        let process = try shellPID(id, phase: "CLI_FLOATING", in: app)

        _ = try cli(["pane", "frame", "40", "60", "420", "300", "--target", id])
        XCTAssertEqual(pane(id, in: app).frame.width, 420, accuracy: 2)
        XCTAssertEqual(pane(id, in: app).frame.height, 300, accuracy: 2)
        _ = try cli(["focus", "--target", original])
        _ = try cli(["pane", "minimize", "--target", id, "--no-select"])
        XCTAssertTrue(minimizedCard(id, in: app).waitForExistence(timeout: 5))
        try assertFocus(original)

        let suffix = UUID().uuidString
        // Echoed input does not contain the contiguous marker; only executed output does.
        _ = try cli(["send", "printf 'CLI'\"\"'-SHELF-\(suffix)\\n'", "--target", id])
        XCTAssertEqual(try cli(["pane", "state", "--target", id])["state"] as? String, "minimized")
        try assertFocus(original)
        assertKeyboard(original, in: app)
        _ = try cli(["pane", "restore", "--target", id])
        waitForPaneCount(2, in: app)
        let terminal = pane(id, in: app).textViews.firstMatch
        let output = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "CLI-SHELF-\(suffix)"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [output], timeout: 7), .completed)
        XCTAssertEqual(try shellPID(id, phase: "CLI_RESTORED", in: app), process)

        _ = try cli(["pane", "maximize", "--target", id])
        _ = try cli(["pane", "minimize", "--target", id])
        _ = try cli(["pane", "restore", "--target", id])
        XCTAssertEqual(control("Maximize", pane: id, in: app).value as? String, "maximized")
        _ = try cli(["pane", "unmaximize", "--target", id])
        XCTAssertEqual(control("Float", pane: id, in: app).value as? String, "floating")
        _ = try cli(["pane", "dock", "--target", id])
        let docked = pane(id, in: app).frame
        _ = try cli(["pane", "dock", "--target", id])
        XCTAssertEqual(control("Float", pane: id, in: app).value as? String, "tiled")
        assertRect(pane(id, in: app).frame, equals: docked)
        XCTAssertEqual(try shellPID(original, phase: "CLI_ORIGINAL_AFTER", in: app), originalProcess)
    }

    func testCLICreatesResizesMinimizesAndClosesANativeWindow() throws {
        let app = try launchControlledDesktop()
        let original = try XCTUnwrap(paneIDs(in: app).first)
        let process = try shellPID(original, phase: "CLI_WINDOW_BEFORE", in: app)
        let made = try cli(["window", "new", "--state", "floating", "--frame", "120,140,900,560"])
        let id = try XCTUnwrap(made["id"] as? String)
        let window = try XCTUnwrap(made["window"] as? String)
        XCTAssertTrue(pane(id, in: app).waitForExistence(timeout: 7))
        XCTAssertEqual(control("Float", pane: id, in: app).value as? String, "floating")
        let normal = activeWindow(in: app).frame
        _ = try cli(["window", "fullscreen", "on", "--window", window])
        waitForFullscreen(true, normalFrame: normal, in: app)
        _ = try cli(["window", "fullscreen", "off", "--window", window])
        waitForFullscreen(false, normalFrame: normal, in: app)

        _ = try cli(["window", "minimize", "--window", window])
        let minimized = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            (try? cli(["window", "state", "--window", window])["minimized"] as? Bool) == true
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [minimized], timeout: 7), .completed)
        _ = try cli(["window", "restore", "--window", window])
        _ = try cli(["window", "focus", "--window", window])
        XCTAssertTrue(pane(id, in: app).isHittable)
        let closed = try cli(["window", "close", "--window", window])
        XCTAssertEqual(closed["state"] as? String, "closed")
        let remaining = try XCTUnwrap(try cli(["window", "list"])["windows"] as? [[String: Any]])
        XCTAssertFalse(remaining.contains { $0["id"] as? String == window }, "Hidden is not closed")
        XCTAssertTrue(pane(id, in: app).waitForNonExistence(timeout: 5))
        XCTAssertEqual(try shellPID(original, phase: "CLI_WINDOW_AFTER", in: app), process)
    }

    func testCLISettingsChangeThePrivateConfigAndTheNativeSettingsView() throws {
        let app = try launchControlledDesktop()
        XCTAssertEqual(try cli(["config", "path"])["path"] as? String, designConfig.path)
        _ = try cli(["config", "set", "font-size=13.5", "app-appearance=light", "status-animate=false"])
        let saved = try configText()
        XCTAssertTrue(saved.contains("font-size = 13.5"))
        _ = openSettings(in: app)
        selectSection("appearance", in: app)
        assertSize("13.5", in: app)
        closeSettings(in: app)
        _ = try cli(["config", "set", "font-size=999"], succeeds: false)
        XCTAssertEqual(try configText(), saved, "Invalid values must not change the file")
        _ = try cli(["config", "shortcut", "set", "new_tab", "ctrl+opt+shift+f12"])
        let shortcuts = try XCTUnwrap(try cli(["config", "shortcut", "list"])["shortcuts"] as? [[String: Any]])
        let newTab = try XCTUnwrap(shortcuts.first { $0["action"] as? String == "new_tab" })
        XCTAssertEqual(newTab["trigger"] as? String, "ctrl+opt+shift+f12")
        XCTAssertTrue(try configText().contains("keybind = ctrl+opt+shift+f12=new_tab"))
        _ = try cli(["config", "shortcut", "unset", "new_tab"])
        _ = try cli(["config", "unset", "font-size"])
        XCTAssertFalse(try configText().contains("font-size ="))
    }
}
