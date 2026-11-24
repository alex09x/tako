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

extension WalkthroughTests {
    /// Fills the SSH form and records when XCTest returns from the Connect tap.
    private func connectToAFreshHost(extraArguments: [String] = []) -> Date {
        app.launchArguments = ["-takoResetState"] + extraArguments
        app.launch()

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
        app.buttons["auth.password"].tap()
        let passwordField = app.secureTextFields["field.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5), "no password field")
        passwordField.tap()
        passwordField.typeText(password)

        let connect = app.buttons["Connect"]
        connect.tap()
        return Date()
    }

    /// The host-key decision must never open under the Connect tap that
    /// started it. Two delays hold that, and both are measured here on the
    /// running app against the real test server, at their real defaults: the
    /// prompt mounts 750 ms after the key is found, and its Trust and Cancel
    /// are dead labels for a further second. (Tapping a dead label is
    /// `testATapOnADeadTrustLabelDecidesNothing`.)
    func testTheHostKeyPromptMountsLateAndItsButtonsArmLater() {
        let tappedConnect = connectToAFreshHost()

        // The prompt's title exists from the moment it mounts.
        let title = app.staticTexts["Unknown host"]
        XCTAssertTrue(title.waitForExistence(timeout: 30), "no host key prompt on a first connection")
        let mounted = Date()
        let mountDelay = mounted.timeIntervalSince(tappedConnect)
        // 750 ms of waiting plus a loopback probe; the lower bound leaves
        // room for the tap returning late, and is far above the probe alone.
        XCTAssertGreaterThanOrEqual(mountDelay, 0.7,
                                    "the prompt mounted \(mountDelay) s after Connect, before the 0.75 s hold")
        XCTAssertLessThan(mountDelay, 6, "the prompt took \(mountDelay) s to mount")

        // Just mounted: Trust and Cancel are labels, not buttons.
        XCTAssertFalse(app.buttons["Trust"].exists, "Trust was a live button the moment the prompt mounted")
        XCTAssertFalse(app.buttons["Cancel"].exists, "Cancel was a live button the moment the prompt mounted")
        XCTAssertTrue(app.staticTexts["Trust"].exists, "the dead Trust label is missing")

        // Then they arm, a second after the mount.
        let trust = app.buttons["Trust"]
        XCTAssertTrue(trust.waitForExistence(timeout: 10), "Trust never became a button")
        let armDelay = Date().timeIntervalSince(mounted)
        XCTAssertGreaterThanOrEqual(armDelay, 0.5, "Trust armed after \(armDelay) s, well before its second")
        XCTAssertLessThan(armDelay, 4, "Trust took \(armDelay) s to arm")
        XCTAssertTrue(app.buttons["Cancel"].exists, "Cancel did not arm with Trust")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5), "an armed Cancel did not close the prompt")
    }

    /// Hold arming in this DEBUG fixture so XCTest idleness waits cannot race
    /// the tap. The default-policy test above verifies timed arming and cancel.
    func testATapOnADeadTrustLabelDecidesNothing() {
        _ = connectToAFreshHost(extraArguments: ["-takoHostKeyArmingHold"])

        let title = app.staticTexts["Unknown host"]
        XCTAssertTrue(title.waitForExistence(timeout: 30), "no host key prompt on a first connection")

        // Admission: the unarmed label, not a button.
        XCTAssertFalse(app.buttons["Trust"].exists, "Trust was a live button before the dead-label tap")
        XCTAssertFalse(app.buttons["Cancel"].exists, "Cancel was a live button before the dead-label tap")
        let deadTrust = app.staticTexts["Trust"]
        XCTAssertTrue(deadTrust.exists, "the dead Trust label is missing")
        deadTrust.tap()

        // The delivered tap decided nothing: the prompt is still there and no
        // terminal opened behind it.
        XCTAssertTrue(title.exists, "a tap on the dead Trust label decided the prompt")
        XCTAssertFalse(app.buttons["key.esc"].exists, "a tap on the dead Trust label opened the terminal")
        XCTAssertTrue(deadTrust.exists, "the tap changed the inert label")
    }
}
