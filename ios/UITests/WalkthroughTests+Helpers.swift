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
import UIKit
import Network

extension WalkthroughTests {
    /// iOS offers to save a password it saw typed into a secure field. The
    /// offer belongs to the system, not the app, so it cannot be turned off
    /// -- it can only be answered, and a run that does not answer it stalls
    /// behind it.
    @discardableResult
    func dismissSystemPrompt(timeout: TimeInterval = 15) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // CredentialUI is a separate process, but XCTest grafts its
            // accessibility tree onto the application it is covering. On
            // current iOS the button is therefore found through `app`; older
            // releases exposed it through SpringBoard. Check both rather than
            // sleeping and hoping that the overlay has gone away.
            for owner in [app!, springboard] {
                for label in ["Not Now", "Not now"] {
                    let button = owner.buttons[label]
                    if button.exists {
                        button.tap()
                        _ = button.waitForNonExistence(timeout: 5)
                        return true
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    func replace(_ field: XCUIElement, with value: String) {
        field.tap()
        field.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) {
            app.menuItems["Select All"].tap()
        }
        field.typeText(value)
    }

    func beginMFAChallenge(screenshotPrefix: String) {
        app.launchArguments = ["-takoResetState"]
        app.launch()
        XCTAssertTrue(app.buttons["newSession"].waitForExistence(timeout: 10))
        app.buttons["newSession"].tap()
        app.buttons["choice.ssh"].tap()

        let hostField = app.textFields["field.host"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 5))
        hostField.tap()
        hostField.typeText(host)
        app.textFields["field.user"].tap()
        app.textFields["field.user"].typeText(user)
        replace(app.textFields["field.port"], with: mfaPort)
        app.buttons["auth.password"].tap()

        let passwordField = app.secureTextFields["field.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5))
        passwordField.tap()
        passwordField.typeText(password)
        shot("01 \(screenshotPrefix) · connection ready")
        app.buttons["Connect"].tap()

        let trust = app.buttons["Trust"]
        XCTAssertTrue(trust.waitForExistence(timeout: 30),
                      "the MFA endpoint skipped host-key review")
        shot("02 \(screenshotPrefix) · host key review")
        trust.tap()
        _ = dismissSystemPrompt(timeout: 3)
    }

    func openRealSSHSession(port: String, resetState: Bool) {
        if resetState {
            XCTAssertTrue(FileManager.default.fileExists(atPath: keyPath),
                          "the disposable OpenSSH key was not generated")
            app.launchArguments = [
                "-takoResetState", "-takoCredentialResource", "ui_test_key",
            ]
            app.launch()
        }
        let newSession = app.buttons["newSession"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 10), "no new-session button")
        newSession.tap()
        app.buttons["choice.ssh"].tap()

        let hostField = app.textFields["field.host"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 5), "no host field")
        hostField.tap()
        hostField.typeText(host)
        app.textFields["field.user"].tap()
        app.textFields["field.user"].typeText(user)
        replace(app.textFields["field.port"], with: port)

        // The number pad covers the paste row. XCTest will still resolve the
        // off-screen accessibility element and try to tap it, but SwiftUI
        // scrolls the form under that synthesized gesture; the coordinate can
        // then land on Connect. A person moves from the port to the visible
        // authentication choice, which also dismisses the number pad.
        let keyMode = app.buttons["auth.key"]
        XCTAssertTrue(keyMode.waitForExistence(timeout: 5),
                      "the form has no visible step after the port")
        keyMode.tap()
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 5),
                      "choosing key authentication did not dismiss the number pad")
        let pasteButton = app.buttons["paste from clipboard"]
        let pasteIsHittable = NSPredicate(format: "exists == true AND isHittable == true")
        expectation(for: pasteIsHittable, evaluatedWith: pasteButton)
        waitForExpectations(timeout: 5)
        pasteButton.tap()
        XCTAssertTrue(app.secureTextFields["field.passphrase"].waitForExistence(timeout: 5),
                      "the disposable key did not reach the SSH form")
        app.buttons["Connect"].tap()

        let trust = app.buttons["Trust"]
        XCTAssertTrue(trust.waitForExistence(timeout: 30),
                      "a first connection to \(host):\(port) skipped host-key review")
        let trustEnabled = NSPredicate(format: "isEnabled == true")
        expectation(for: trustEnabled, evaluatedWith: trust)
        waitForExpectations(timeout: 5)
        trust.tap()
        XCTAssertTrue(app.buttons["key.esc"].waitForExistence(timeout: 30),
                      "OpenSSH \(host):\(port) never reached a terminal")
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 10),
                      "the real SSH terminal has no software keyboard")
        typeCommand("printf 'OPENSSH-READY-\(port)\\n'")
        XCTAssertTrue(waitForTerminal(toContain: "OPENSSH-READY-\(port)", timeout: 20),
                      "the real OpenSSH shell did not expose executed input: \(terminalText())")
    }

    func sessionCard(port: String) -> XCUIElement {
        let endpoint = "\(user)@\(host):\(port)"
        return app.buttons.matching(NSPredicate(format: "label CONTAINS %@", endpoint)).firstMatch
    }

    func testSetting(_ key: String) -> String? {
        let value = Bundle(for: WalkthroughTests.self).object(forInfoDictionaryKey: key) as? String
        return value?.isEmpty == false ? value : nil
    }

    func typeCommand(_ command: String) {
        app.typeText(command)
        tapSoftwareReturn()
    }

    func dropFaultProxyConnections() {
        let dropped = expectation(description: "fault proxy dropped the active TCP stream")
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: faultControlPort)!,
            using: .tcp
        )
        var reply = ""
        connection.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            connection.send(content: Data("drop\n".utf8), completion: .contentProcessed { error in
                guard error == nil else {
                    dropped.fulfill()
                    return
                }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 128) {
                    data, _, _, _ in
                    if let data { reply = String(decoding: data, as: UTF8.self) }
                    dropped.fulfill()
                }
            })
        }
        connection.start(queue: DispatchQueue(label: "tako.ui-test.fault-proxy"))
        wait(for: [dropped], timeout: 5)
        connection.cancel()
        XCTAssertTrue(reply.hasPrefix("OK "), "fault proxy rejected the drop command: \(reply)")
    }

    /// Press a character on the system software keyboard. Keyboard labels
    /// vary in case across iOS releases, so accept either spelling while
    /// still requiring a real key element rather than injecting text.
    func tapSoftwareKey(
        _ character: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for label in [character, character.uppercased()] {
            let key = app.keys[label]
            if key.exists {
                key.tap()
                return
            }
        }
        XCTFail("the software keyboard has no \(character) key", file: file, line: line)
    }

    func tapSoftwareSpace(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for label in ["space", "Space"] {
            for key in [app.keys[label], app.buttons[label]] where key.exists {
                key.tap()
                return
            }
        }
        XCTFail("the software keyboard has no space bar", file: file, line: line)
    }

    /// What the echo server reported receiving between the last read that
    /// was exactly `first` and the next read that was exactly `last`, one
    /// entry per read, in order.
    ///
    /// The server prints `GOT [hh hh]` per read, and the software keyboard
    /// delivers one key per read, so a substitution shows up here as an
    /// extra read: `7f` for a backspace, `2e 20` for an inserted ". ".
    func bytesReceived(after first: String, before last: String) -> [String] {
        let reads = terminalText().components(separatedBy: "GOT [").dropFirst().compactMap {
            $0.split(separator: "]", maxSplits: 1).first.map(String.init)
        }
        guard let start = reads.lastIndex(of: first) else { return ["no read of \(first)"] }
        let rest = reads[reads.index(after: start)...]
        guard let end = rest.firstIndex(of: last) else { return ["no read of \(last) after \(first)"] }
        return Array(rest[..<end])
    }

    func tapSoftwareReturn(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for label in ["return", "Return"] {
            for key in [app.keys[label], app.buttons[label]] where key.exists {
                key.tap()
                return
            }
        }
        XCTFail("the software keyboard has no Return key", file: file, line: line)
    }

    /// Setting `XCUIDevice.orientation` returns while UIKit is still
    /// animating between geometries. Starting the reverse rotation during
    /// that transition produced a tilted screenshot and transient terminal
    /// dimensions, then made a valid buffer look missing to Accessibility.
    /// Require the app window to hold the requested aspect for half a second
    /// before asserting content or asking for another rotation.
    func waitForSettledOrientation(
        landscape: Bool,
        timeout: TimeInterval = 8
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var matchingSince: Date?
        let window = app.windows.firstMatch

        while Date() < deadline {
            let frame = window.frame
            let matches = landscape ? frame.width > frame.height : frame.height > frame.width
            if matches {
                matchingSince = matchingSince ?? Date()
                if Date().timeIntervalSince(matchingSince!) >= 0.5 {
                    return true
                }
            } else {
                matchingSince = nil
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private struct TerminalSize: Equatable, CustomStringConvertible {
        let cols: Int
        let rows: Int

        var description: String { "\(cols)x\(rows)" }
    }

    /// The byte-level SSH peer prints `RESIZE CxR` only after receiving a
    /// channel window-change request. Reading this from the visible terminal
    /// therefore verifies the whole chain: UIKit geometry -> Metal surface ->
    /// Session.handleResize -> russh -> the remote peer.
    func latestReportedSize() -> TerminalSize? {
        let text = terminalText()
        let pattern = #"RESIZE ([0-9]+)x([0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ).last,
              let colsRange = Range(match.range(at: 1), in: text),
              let rowsRange = Range(match.range(at: 2), in: text),
              let cols = Int(text[colsRange]),
              let rows = Int(text[rowsRange]) else {
            return nil
        }
        return TerminalSize(cols: cols, rows: rows)
    }

    func waitForReportedSize(
        differentFrom baseline: TerminalSize? = nil,
        timeout: TimeInterval = 15
    ) -> TerminalSize? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let size = latestReportedSize(), size != baseline {
                return size
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    /// What the terminal is showing.
    ///
    /// Read through the accessibility value, which is what a screen reader
    /// would be given: the grid is drawn by Metal and has no text for a test
    /// to find any other way.
    func terminalText() -> String {
        app.textViews["terminal"].value as? String ?? ""
    }

    func waitForTerminal(toContain needle: String, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if terminalText().contains(needle) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    /// Existence is published before a SwiftUI sheet has finished crossing
    /// the system window that presented it. A real finger cannot tap through
    /// that transition, so a UI test should wait for the same condition.
    func waitForHittable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return element.exists && element.isHittable
    }

    func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

}
