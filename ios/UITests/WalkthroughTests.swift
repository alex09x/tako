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

/// The app, used the way a person uses it: taps and typing, no launch
/// arguments, no reaching past the interface.
///
/// Everything else that drives this app hands it a host on the command line
/// and pokes bytes at the session. That proves the engine and the transport
/// and skips the part in between -- the sheet, the form, the host key prompt,
/// the keyboard -- which is the part a person actually touches, and the part
/// that had never once been exercised before this file existed.
///
/// A screenshot is attached at every step, so the run is not only a pass or a
/// fail but a record of what each screen looked like on the way through.
final class WalkthroughTests: XCTestCase {
    /// Where the test server is. simtest.py starts one and passes the port
    /// through the environment; the default matches its own.
    var host: String {
        ProcessInfo.processInfo.environment["TAKO_TEST_HOST"]
            ?? testSetting("TakoTestHost")
            ?? "127.0.0.1"
    }
    var port: String {
        ProcessInfo.processInfo.environment["TAKO_TEST_PORT"]
            ?? testSetting("TakoTestEchoPort")
            ?? "2227"
    }
    var user: String {
        ProcessInfo.processInfo.environment["TAKO_TEST_USER"]
            ?? testSetting("TakoTestUser")
            ?? "tester"
    }
    var password: String {
        ProcessInfo.processInfo.environment["TAKO_TEST_PASSWORD"]
            ?? "correct horse battery staple"
    }
    var mfaPort: String {
        ProcessInfo.processInfo.environment["TAKO_TEST_MFA_PORT"]
            ?? testSetting("TakoTestMFAPort")
            ?? "2228"
    }
    var mfaCode: String {
        ProcessInfo.processInfo.environment["TAKO_TEST_MFA_CODE"]
            ?? testSetting("TakoTestMFACode")
            ?? "246810"
    }
    var mfaDevice: String {
        ProcessInfo.processInfo.environment["TAKO_TEST_MFA_DEVICE"]
            ?? testSetting("TakoTestMFADevice")
            ?? "Simulator"
    }
    var openSSHPort: String {
        ProcessInfo.processInfo.environment["TAKO_TEST_OPENSSH_PORT"]
            ?? testSetting("TakoTestOpenSSHPort")
            ?? "2224"
    }
    var secondOpenSSHPort: String {
        ProcessInfo.processInfo.environment["TAKO_TEST_OPENSSH_SECOND_PORT"]
            ?? testSetting("TakoTestSecondOpenSSHPort")
            ?? "2225"
    }
    var faultProxyPort: String {
        ProcessInfo.processInfo.environment["TAKO_TEST_FAULT_PROXY_PORT"]
            ?? testSetting("TakoTestFaultProxyPort")
            ?? "2229"
    }
    var faultControlPort: UInt16 {
        UInt16(ProcessInfo.processInfo.environment["TAKO_TEST_FAULT_CONTROL_PORT"]
               ?? testSetting("TakoTestFaultControlPort")
               ?? "2230")
            ?? 2230
    }
    var keyPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // UITests
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("target/simtest/sshd/client_ed25519")
            .path
    }

    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        addUIInterruptionMonitor(withDescription: "Paste permission") { alert in
            for label in ["Allow Paste", "Allow"] {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
    }

    /// The empty-state demo is part of the shipped app, not a launch-argument
    /// shortcut. Open it and come back through the same controls a person
    /// sees before they have saved any server.
    func testFirstLaunchDemoAndNavigation() {
        app.launchArguments = ["-takoResetState"]
        app.launch()

        let demo = app.buttons["session.local · demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10), "the first launch has no demo card")
        XCTAssertTrue(app.buttons["newSession"].exists, "the first launch has no add button")
        shot("01 first launch")

        demo.tap()
        XCTAssertTrue(app.buttons["terminal.back"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForTerminal(toContain: "tail -f api.log"),
                      "the demo card opened an empty terminal: \(terminalText())")
        shot("02 demo terminal")

        // A demo terminal must still have a peer behind it. Exercise the
        // visible software keyboard rather than injecting a string: a plain
        // `ls` followed by Return must execute, print output and give the
        // user another prompt.
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5),
                      "the demo terminal never exposed the software keyboard")
        tapSoftwareKey("l")
        tapSoftwareKey("s")
        tapSoftwareReturn()
        XCTAssertTrue(waitForTerminal(toContain: "README.md"),
                      "demo Return did not execute ls: \(terminalText())")
        shot("03 demo ls executed")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForSettledOrientation(landscape: true),
                      "the app never finished rotating to landscape")
        // Landscape has fewer terminal rows while the software keyboard is
        // present, so the oldest seed line may correctly move to scrollback.
        // The command just executed is the live-tail invariant here.
        XCTAssertTrue(waitForTerminal(toContain: "README.md"),
                      "rotation lost the demo command output")
        shot("04 demo landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForSettledOrientation(landscape: false),
                      "the app never finished rotating back to portrait")
        XCTAssertTrue(waitForTerminal(toContain: "README.md"),
                      "rotating back lost the demo command output")
        shot("05 demo portrait again")

        app.buttons["terminal.back"].tap()
        XCTAssertTrue(app.buttons["newSession"].waitForExistence(timeout: 5))
        shot("06 back at session list")
    }

    /// The form must prevent an incomplete connection before it can become a
    /// network error, and become actionable as soon as the required fields
    /// are valid.
    func testConnectionFormValidation() {
        app.launchArguments = ["-takoResetState"]
        app.launch()
        XCTAssertTrue(app.buttons["newSession"].waitForExistence(timeout: 10))
        app.buttons["newSession"].tap()
        app.buttons["choice.ssh"].tap()

        let connect = app.buttons["Connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertFalse(connect.isEnabled, "an empty SSH form can connect")
        shot("01 invalid empty form")

        app.textFields["field.host"].tap()
        app.textFields["field.host"].typeText(host)
        app.textFields["field.user"].tap()
        app.textFields["field.user"].typeText(user)
        XCTAssertTrue(connect.isEnabled, "a host, user and valid default port cannot connect")

        app.buttons["auth.password"].tap()
        XCTAssertTrue(app.secureTextFields["field.password"].exists)
        shot("02 valid password form")

        app.buttons["auth.key"].tap()
        let keyEditor = app.textViews["field.key"]
        XCTAssertTrue(keyEditor.waitForExistence(timeout: 5))
        keyEditor.tap()
        keyEditor.typeText("-----BEGIN OPENSSH PRIVATE KEY-----")
        let passphrase = app.secureTextFields["field.passphrase"]
        XCTAssertTrue(passphrase.waitForExistence(timeout: 5),
                      "pasting a private key did not expose its optional passphrase")
        XCTAssertTrue(passphrase.isHittable,
                      "the optional passphrase exists but is hidden behind the keyboard")
        passphrase.tap()
        passphrase.typeText("correct horse")
        XCTAssertFalse((passphrase.value as? String ?? "").isEmpty,
                       "the visible passphrase field did not accept keyboard input")
        shot("03 key passphrase form")
    }

    /// A rejected credential is not merely a grey dot: the reason the
    /// transport supplied must be visible and readable on the terminal
    /// screen so a person knows what to correct.
    func testWrongPasswordExplainsTheFailure() {
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
        replace(app.textFields["field.port"], with: port)
        app.buttons["auth.password"].tap()
        app.secureTextFields["field.password"].tap()
        app.secureTextFields["field.password"].typeText("definitely-wrong")
        shot("01 wrong password ready")
        app.buttons["Connect"].tap()

        let trust = app.buttons["Trust"]
        XCTAssertTrue(trust.waitForExistence(timeout: 30))
        shot("02 host key before rejected auth")
        trust.tap()
        XCTAssertTrue(app.buttons["key.esc"].waitForExistence(timeout: 30))
        // The system password-saving offer is part of the user's path and
        // temporarily owns Accessibility focus. Dismiss it before asking
        // whether the app itself explains the rejected authentication.
        dismissSystemPrompt()

        let status = app.descendants(matching: .any)
            .matching(identifier: "session.status").firstMatch
        let authenticationFailure = NSPredicate(
            format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
            "authentication", "authentication"
        )
        expectation(for: authenticationFailure, evaluatedWith: status)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(terminalText().contains("TYPE SOMETHING"),
                       "a rejected password nevertheless opened a shell")
        shot("03 rejected password explained")
    }

    /// Password partial-success followed by two keyboard-interactive rounds
    /// must remain a single usable SSH connection. The fixture asks first
    /// for a hidden OTP and then for an echoed device name, so this catches
    /// both prompt kinds as well as challenge replacement while a sheet is
    /// already presented.

}
