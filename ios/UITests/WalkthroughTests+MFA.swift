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
    func testKeyboardInteractiveMFACompletesEveryRound() {
        beginMFAChallenge(screenshotPrefix: "mfa success")

        let code = app.secureTextFields["auth.challenge.prompt.0"]
        XCTAssertTrue(code.waitForExistence(timeout: 20),
                      "the server's hidden verification-code prompt never appeared")
        XCTAssertTrue(waitForHittable(code, timeout: 10),
                      "the verification-code prompt stayed covered")
        code.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5),
                      "tapping the verification-code prompt showed no keyboard")
        code.typeText(mfaCode)
        shot("03 mfa success · verification code entered")
        app.buttons["auth.challenge.submit"].tap()

        let device = app.textFields["auth.challenge.prompt.0"]
        XCTAssertTrue(device.waitForExistence(timeout: 15),
                      "the second, echoed MFA round never replaced the first")
        XCTAssertTrue(waitForHittable(device, timeout: 10),
                      "the second MFA prompt stayed covered")
        device.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5),
                      "tapping the second MFA prompt showed no keyboard")
        device.typeText(mfaDevice)
        shot("04 mfa success · device confirmation entered")
        app.buttons["auth.challenge.submit"].tap()

        XCTAssertTrue(app.buttons["key.esc"].waitForExistence(timeout: 30),
                      "successful MFA never opened the terminal")
        XCTAssertTrue(waitForTerminal(toContain: "AUTH keyboard-interactive MFA", timeout: 20),
                      "the terminal did not prove MFA authentication: \(terminalText())")
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5),
                      "the terminal did not reclaim keyboard focus after MFA")
        typeCommand("mfa-check")
        XCTAssertTrue(waitForTerminal(toContain: "GOT [0d]", timeout: 15),
                      "Return never reached SSH after MFA")
        let transcript = terminalText()
        let expectedBytes = [
            ("6d", "m"), ("66", "f"), ("61", "a"), ("2d", "-"),
            ("63", "c"), ("68", "h"), ("65", "e"), ("63", "c"),
            ("6b", "k"), ("0d", "."),
        ]
        var remainder = transcript[...]
        for (hex, printable) in expectedBytes {
            let marker = "GOT [\(hex)] \"\(printable)\""
            guard let range = remainder.range(of: marker) else {
                XCTFail("post-MFA input was missing or reordered at \(marker): \(transcript)")
                return
            }
            remainder = remainder[range.upperBound...]
        }
        shot("05 mfa success · live terminal input")
    }

    /// A wrong OTP must fail closed: no shell, no silent retry with a weaker
    /// method, and a reason visible to the person holding the phone.
    func testKeyboardInteractiveMFARejectsWrongCode() {
        beginMFAChallenge(screenshotPrefix: "mfa wrong")

        let code = app.secureTextFields["auth.challenge.prompt.0"]
        XCTAssertTrue(code.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForHittable(code, timeout: 10),
                      "the rejected-code prompt stayed covered")
        code.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5),
                      "tapping the rejected-code prompt showed no keyboard")
        code.typeText("000000")
        shot("03 mfa wrong · rejected code entered")
        app.buttons["auth.challenge.submit"].tap()

        let disconnected = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "disconnected")
        ).firstMatch
        XCTAssertTrue(disconnected.waitForExistence(timeout: 20),
                      "a rejected MFA response neither failed nor explained itself")
        XCTAssertFalse(terminalText().contains("TYPE SOMETHING"),
                       "the server opened a shell after a wrong MFA response")
        shot("04 mfa wrong · connection refused")
    }

    /// Cancel is a protocol action, not merely hiding the sheet. It must
    /// release the pending authentication and close the transport without
    /// ever entering a shell.
    func testKeyboardInteractiveMFACancelClosesAuthentication() {
        beginMFAChallenge(screenshotPrefix: "mfa cancel")

        XCTAssertTrue(app.secureTextFields["auth.challenge.prompt.0"]
            .waitForExistence(timeout: 20))
        shot("03 mfa cancel · challenge visible")
        app.buttons["auth.challenge.cancel"].tap()

        let disconnected = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "disconnected")
        ).firstMatch
        XCTAssertTrue(disconnected.waitForExistence(timeout: 20),
                      "cancel left the SSH runtime waiting for an answer")
        XCTAssertFalse(terminalText().contains("TYPE SOMETHING"),
                       "canceling MFA nevertheless opened a shell")
        shot("04 mfa cancel · transport closed")
    }

    /// Opens a session by filling the form in, then types in the terminal.

}
