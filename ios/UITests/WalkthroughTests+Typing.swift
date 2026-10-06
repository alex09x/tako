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
    func testConnectsToAHostAndTypesInIt() {
        // Starting clean, so the host key prompt is a first connection every
        // time rather than only the first time this ever ran.
        app.launchArguments = ["-takoResetState"]
        app.launch()
        shot("01 session list")

        // ── the sheet ────────────────────────────────────────────────────
        let newSession = app.buttons["newSession"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 10), "no new-session button")
        newSession.tap()

        let sshChoice = app.buttons["choice.ssh"]
        XCTAssertTrue(sshChoice.waitForExistence(timeout: 5), "the sheet has no SSH host row")
        shot("02 new session sheet")
        sshChoice.tap()

        // ── the form ─────────────────────────────────────────────────────
        let hostField = app.textFields["field.host"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 5), "no host field")
        shot("03 empty form")

        hostField.tap()
        hostField.typeText(host)

        let userField = app.textFields["field.user"]
        userField.tap()
        userField.typeText(user)

        // The port field's number pad has no return key, so the value is
        // cleared and retyped rather than appended to the placeholder's 22.
        let portField = app.textFields["field.port"]
        portField.tap()
        portField.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) {
            app.menuItems["Select All"].tap()
        }
        portField.typeText(port)

        // Password rather than a key: a PEM is 400 characters of base64 and
        // typing it through the simulator's keyboard is a test of the
        // keyboard, not of the form. The key path is covered in simtest.py.
        app.buttons["auth.password"].tap()
        let passwordField = app.secureTextFields["field.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5), "no password field")
        passwordField.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5),
                      "the keyboard never came up for the password field")
        passwordField.typeText(password)
        // A secure field reports dots rather than the text, so this only says
        // that something landed -- which is exactly the thing that silently
        // did not, and cost a connection failure that looked like the server's
        // fault.
        XCTAssertFalse((passwordField.value as? String ?? "").isEmpty,
                       "the password did not go into the field")
        shot("04 filled form")

        app.buttons["Connect"].tap()

        // ── the host key ─────────────────────────────────────────────────
        // A first connection must stop here. If this prompt ever stops
        // appearing, the app has started trusting strangers silently, and
        // that is worth a test failing over.
        let trust = app.buttons["Trust"]
        XCTAssertTrue(trust.waitForExistence(timeout: 30), "no host key prompt on a first connection")
        shot("05 host key prompt")
        trust.tap()
        // ── the terminal ─────────────────────────────────────────────────
        let escKey = app.buttons["key.esc"]
        XCTAssertTrue(escKey.waitForExistence(timeout: 30), "never reached the terminal")

        // The save-password offer arrives once the form is gone, which is
        // after the trust decision -- so it lands on the terminal, and
        // anything typed while it is up goes to it instead of the app.
        // The far end announces itself when the shell opens. Waiting for that
        // rather than for a duration is the difference between a test and a
        // hope.
        // The far end writes this before the view's first layout and before
        // the software keyboard shortens the terminal. It must remain on the
        // visible screen across both resizes, not merely survive in history.
        XCTAssertTrue(waitForTerminal(toContain: "PTY xterm-256color"),
                      "the login banner never reached the visible screen: \(terminalText())")
        // The password-saving offer is asynchronous and can appear after the
        // terminal itself. Dismiss it immediately before typing so the bytes
        // cannot land in a system dialog instead of the PTY.
        dismissSystemPrompt()
        XCTAssertFalse(app.sheets["Save Password?"].exists,
                       "the system password offer still covers the terminal")
        shot("06 connected")

        // A renderer resize is only half the contract: the process on the
        // far end must receive SSH_MSG_CHANNEL_REQUEST `window-change`, or a
        // real shell keeps laying out to the old width. The test server prints
        // every size it receives, so rotate as a person would and require the
        // remote observation to change in both directions.
        guard let portraitSize = waitForReportedSize() else {
            XCTFail("the SSH server never reported the initial terminal size: \(terminalText())")
            return
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForSettledOrientation(landscape: true),
                      "the SSH terminal never finished rotating to landscape")
        guard let landscapeSize = waitForReportedSize(differentFrom: portraitSize) else {
            XCTFail("the SSH server received no landscape resize after \(portraitSize)")
            return
        }
        XCTAssertGreaterThan(landscapeSize.cols, portraitSize.cols,
                             "landscape did not give the remote shell more columns")
        shot("07 connected landscape \(landscapeSize)")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForSettledOrientation(landscape: false),
                      "the SSH terminal never finished rotating back to portrait")
        guard let portraitAgain = waitForReportedSize(differentFrom: landscapeSize) else {
            XCTFail("the SSH server received no portrait resize after \(landscapeSize)")
            return
        }
        XCTAssertLessThan(portraitAgain.cols, landscapeSize.cols,
                          "portrait did not restore the remote shell's narrower width")
        shot("08 connected portrait \(portraitAgain)")

        // Select across the first login-banner row with the same long press
        // and drag a finger uses, then invoke the system edit menu. This
        // crosses Metal cell geometry, the engine selection and UIPasteboard.
        let terminal = app.textViews["terminal"]
        let selectionStart = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.03))
        let selectionEnd = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: 0.03))
        selectionStart.press(forDuration: 0.8, thenDragTo: selectionEnd)
        let copyMenuItem = app.menuItems["Copy"]
        let copyButton = app.buttons["Copy"]
        XCTAssertTrue(copyMenuItem.waitForExistence(timeout: 5)
                      || copyButton.waitForExistence(timeout: 1),
                      "long-press selection did not show Copy")
        shot("09 selection menu")
        (copyMenuItem.exists ? copyMenuItem : copyButton).tap()
        shot("10 after copy")

        // Do not read the app's pasteboard from the XCTest runner: iOS quite
        // correctly asks whether one process may paste from the other, which
        // turns a clipboard test into a permission-dialog test. Paste back
        // through the app's own explicit PasteButton instead. The echo server
        // naming the leading PTY bytes proves Copy -> UIPasteboard -> Paste
        // end to end, exactly as a person uses it.
        app.buttons["key.paste"].tap()
        XCTAssertTrue(waitForTerminal(toContain: "GOT [50 54 59"),
                      "the copied login banner did not paste back into the terminal")
        shot("11 copied banner pasted")

        // Type on the visible iOS keyboard one key at a time. `app.typeText`
        // still enters through the responder, but it can hide a broken or
        // missing software keyboard. These taps are the literal user path:
        // h, i, then the keyboard's Return key.
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5),
                      "the terminal never exposed the software keyboard")
        tapSoftwareKey("h")
        tapSoftwareKey("i")
        tapSoftwareReturn()
        for byte in ["68", "69", "0d"] {
            XCTAssertTrue(waitForTerminal(toContain: "GOT [\(byte)]"),
                          "typed byte 0x\(byte) never reached the far end: \(terminalText())")
        }
        shot("12 after typing")

        // The space bar, tapped twice between two letters. In prose iOS turns
        // a double space into ". ", capitalises after it and corrects what it
        // thinks is a word; a shell given any of that runs something nobody
        // typed. The far end must receive exactly the four keys: z, space,
        // space, q -- no full stop, no backspace erasing the first space, no
        // capital.
        tapSoftwareKey("z")
        tapSoftwareSpace()
        tapSoftwareSpace()
        tapSoftwareKey("q")
        XCTAssertTrue(waitForTerminal(toContain: "GOT [71]"),
                      "the letter after the spaces never reached the far end: \(terminalText())")
        XCTAssertEqual(bytesReceived(after: "7a", before: "71"), ["20", "20"],
                       "the space bar did not arrive as two plain spaces: \(terminalText())")
        shot("12b after double space")

        // And the row a phone keyboard does not have.
        app.buttons["key.ctrl"].tap()
        shot("13 control armed")
        app.typeText("c")
        XCTAssertTrue(waitForTerminal(toContain: "GOT [03]"),
                      "control-c did not fold into 0x03: \(terminalText())")
        shot("14 after control c")

        escKey.tap()
        XCTAssertTrue(waitForTerminal(toContain: "GOT [1b]"), "esc sent nothing")
        app.buttons["key.tab"].tap()
        XCTAssertTrue(waitForTerminal(toContain: "GOT [09]"), "tab sent nothing")
        app.buttons["key.up"].tap()
        XCTAssertTrue(waitForTerminal(toContain: "GOT [1b 5b 41]"), "up sent nothing")
        shot("15 after key row")

        UIPasteboard.general.string = "paste-ok"
        app.buttons["key.paste"].tap()
        XCTAssertTrue(waitForTerminal(toContain: "GOT [70 61 73 74 65 2d 6f 6b]"),
                      "paste did not reach the far end: \(terminalText())")
        shot("16 after paste")

        // Make enough output to leave the login banner in history, scroll to
        // it with finger gestures, and then return to the live tail.
        let tail = "SCROLL-" + String(repeating: "x", count: 2_000) + "-TAIL"
        UIPasteboard.general.string = tail
        app.buttons["key.paste"].tap()
        XCTAssertTrue(waitForTerminal(toContain: "TAIL", timeout: 20),
                      "large pasted output never reached the live screen")
        var reachedLogin = false
        for _ in 0..<30 {
            terminal.swipeDown()
            if waitForTerminal(toContain: "PTY xterm-256color", timeout: 0.8) {
                reachedLogin = true
                break
            }
        }
        if !reachedLogin {
            // The Metal frame can become visible just after the final swipe
            // while Accessibility is still publishing the previous grid.
            reachedLogin = waitForTerminal(toContain: "PTY xterm-256color", timeout: 5)
        }
        XCTAssertTrue(reachedLogin, "scrolling up did not reach retained login output")
        Thread.sleep(forTimeInterval: 0.5) // let the Metal frame catch the verified viewport
        shot("17 scrolled into history")
        var reachedTail = false
        for _ in 0..<30 {
            terminal.swipeUp()
            if waitForTerminal(toContain: "TAIL", timeout: 0.8) {
                reachedTail = true
                break
            }
        }
        if !reachedTail {
            reachedTail = waitForTerminal(toContain: "TAIL", timeout: 5)
        }
        XCTAssertTrue(reachedTail, "scrolling down did not return to the live screen")
        Thread.sleep(forTimeInterval: 0.5)
        shot("18 back at live bottom")

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        XCTAssertTrue(app.buttons["key.esc"].waitForExistence(timeout: 10),
                      "backgrounding discarded the terminal screen")
        XCTAssertTrue(waitForTerminal(toContain: "TAIL"),
                      "backgrounding lost the live SSH terminal")
        shot("19 after background and resume")
    }

    /// A real login shell, used for the jobs that make a terminal more than
    /// an echo box: alternate-screen programs, a multiline bracketed paste,
    /// sustained output, background delivery and a burst of typed input.

}
