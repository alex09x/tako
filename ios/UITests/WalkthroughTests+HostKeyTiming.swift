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
    /// Fills the SSH form for the test server and taps Connect. Returns two
    /// origins: `tapStarted`, monotonic uptime read just before the Connect tap
    /// is sent (nothing can mount before it), and `tapReturned`, the wall
    /// clock when XCTest returned from that tap (the default-policy timing
    /// test's original origin).
    private func connectToAFreshHost(extraArguments: [String] = []) -> (tapStarted: TimeInterval, tapReturned: Date) {
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
        let tapStarted = ProcessInfo.processInfo.systemUptime
        connect.tap()
        return (tapStarted, Date())
    }

    /// The host-key decision must never open under the Connect tap that
    /// started it. Two delays hold that, and both are measured here on the
    /// running app against the real test server, at their real defaults: the
    /// prompt mounts 750 ms after the key is found, and its Trust and Cancel
    /// are dead labels for a further second. (Tapping a dead label is
    /// `testATapOnADeadTrustLabelDecidesNothing`.)
    func testTheHostKeyPromptMountsLateAndItsButtonsArmLater() {
        let tappedConnect = connectToAFreshHost().tapReturned

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

    /// A real tap on the dead Trust label decides nothing. The Debug-only
    /// `-takoHostKeyArmingHold` keeps the labels dead for 5 s, but that alone
    /// does not make the tap land before arming. The prompt cannot mount
    /// before the Connect tap is sent, so it cannot arm before that moment
    /// + 5 s: the dead-label tap must have completed (returned) within 5 s of
    /// the monotonic time read just before Connect, or the run says its
    /// timing was inconclusive and judges nothing. This does not rely on how
    /// long XCTest took to return from the Connect tap.
    func testATapOnADeadTrustLabelDecidesNothing() {
        let tapStarted = connectToAFreshHost(extraArguments: ["-takoHostKeyArmingHold"]).tapStarted

        let title = app.staticTexts["Unknown host"]
        XCTAssertTrue(title.waitForExistence(timeout: 30), "no host key prompt on a first connection")

        // Admission: the unarmed label, not a button.
        XCTAssertFalse(app.buttons["Trust"].exists, "Trust was a live button before the dead-label tap")
        XCTAssertFalse(app.buttons["Cancel"].exists, "Cancel was a live button before the dead-label tap")
        let deadTrust = app.staticTexts["Trust"]
        XCTAssertTrue(deadTrust.exists, "the dead Trust label is missing")
        deadTrust.tap()
        let tapAge = ProcessInfo.processInfo.systemUptime - tapStarted
        guard tapAge < 5 else {
            XCTFail("fixture timing inconclusive: the dead-label tap completed \(tapAge) s after the Connect tap was sent, not within the 5 s hold; nothing about the prompt is judged")
            return
        }
        print("dead-label tap completed \(tapAge) s after the Connect tap was sent")

        // The delivered tap decided nothing: the prompt is still there and no
        // terminal opened behind it.
        XCTAssertTrue(title.exists, "a tap on the dead Trust label decided the prompt")
        XCTAssertFalse(app.buttons["key.esc"].exists, "a tap on the dead Trust label opened the terminal")

        // Then they arm, and an armed Cancel closes it.
        XCTAssertTrue(app.buttons["Trust"].waitForExistence(timeout: 10), "Trust never became a button")
        XCTAssertTrue(app.buttons["Cancel"].exists, "Cancel did not arm with Trust")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5), "an armed Cancel did not close the prompt")
    }
}
