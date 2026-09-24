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
    private var host: String {
        ProcessInfo.processInfo.environment["TAKO_TEST_HOST"]
            ?? testSetting("TakoTestHost")
            ?? "127.0.0.1"
    }
    private var port: String {
        ProcessInfo.processInfo.environment["TAKO_TEST_PORT"]
            ?? testSetting("TakoTestEchoPort")
            ?? "2227"
    }
    private var user: String {
        ProcessInfo.processInfo.environment["TAKO_TEST_USER"]
            ?? testSetting("TakoTestUser")
            ?? "tester"
    }
    private var password: String {
        ProcessInfo.processInfo.environment["TAKO_TEST_PASSWORD"]
            ?? "correct horse battery staple"
    }
    private var mfaPort: String {
        ProcessInfo.processInfo.environment["TAKO_TEST_MFA_PORT"]
            ?? testSetting("TakoTestMFAPort")
            ?? "2228"
    }
    private var mfaCode: String {
        ProcessInfo.processInfo.environment["TAKO_TEST_MFA_CODE"]
            ?? testSetting("TakoTestMFACode")
            ?? "246810"
    }
    private var mfaDevice: String {
        ProcessInfo.processInfo.environment["TAKO_TEST_MFA_DEVICE"]
            ?? testSetting("TakoTestMFADevice")
            ?? "Simulator"
    }
    private var openSSHPort: String {
        ProcessInfo.processInfo.environment["TAKO_TEST_OPENSSH_PORT"]
            ?? testSetting("TakoTestOpenSSHPort")
            ?? "2224"
    }
    private var secondOpenSSHPort: String {
        ProcessInfo.processInfo.environment["TAKO_TEST_OPENSSH_SECOND_PORT"]
            ?? testSetting("TakoTestSecondOpenSSHPort")
            ?? "2225"
    }
    private var faultProxyPort: String {
        ProcessInfo.processInfo.environment["TAKO_TEST_FAULT_PROXY_PORT"]
            ?? testSetting("TakoTestFaultProxyPort")
            ?? "2229"
    }
    private var faultControlPort: UInt16 {
        UInt16(ProcessInfo.processInfo.environment["TAKO_TEST_FAULT_CONTROL_PORT"]
               ?? testSetting("TakoTestFaultControlPort")
               ?? "2230")
            ?? 2230
    }
    private var keyPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // UITests
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("target/simtest/sshd/client_ed25519")
            .path
    }

    private var app: XCUIApplication!

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
    func testRealOpenSSHHandlesDailyInteractiveWorkloads() {
        openRealSSHSession(port: openSSHPort, resetState: true)
        shot("01 real OpenSSH shell")

        // less: alternate screen, navigation to both ends, then a clean
        // return to the same shell and scrollback.
        typeCommand(
            "seq 1 200 | sed '1s/.*/LESS-FIRST/;200s/.*/LESS-LAST/' "
                + "> /tmp/tako-ui-less.txt; less /tmp/tako-ui-less.txt"
        )
        XCTAssertTrue(waitForTerminal(toContain: "LESS-FIRST"), "less never drew its first page")
        shot("02 less first page")
        app.typeText("G")
        XCTAssertTrue(waitForTerminal(toContain: "LESS-LAST"), "less did not navigate to the end")
        shot("03 less last page")
        app.typeText("q")
        typeCommand("printf 'AFTER-LESS\\n'")
        XCTAssertTrue(waitForTerminal(toContain: "AFTER-LESS"), "less did not restore the shell")

        // Vim advertises bracketed-paste mode. Paste enough multiline and
        // Unicode data through the native Paste button to make any missing,
        // reordered or accidentally executed line visible after saving.
        typeCommand("vim -Nu NONE -n /tmp/tako-ui-vim.txt")
        app.typeText("i")
        let pastedLines = (1...96).map {
            String(format: "VIM-LINE-%03d-你好-🐙", $0)
        }
        UIPasteboard.general.string = pastedLines.joined(separator: "\n")
        app.buttons["key.paste"].tap()
        XCTAssertTrue(waitForTerminal(toContain: "VIM-LINE-096-你好-🐙", timeout: 20),
                      "Vim never displayed the tail of the multiline paste")
        shot("04 vim multiline Unicode paste")
        app.buttons["key.esc"].tap()
        app.typeText(":wq")
        tapSoftwareReturn()
        typeCommand(
            "awk 'END { print NR }' /tmp/tako-ui-vim.txt; head -1 /tmp/tako-ui-vim.txt; "
                + "tail -1 /tmp/tako-ui-vim.txt"
        )
        for marker in ["96", "VIM-LINE-001-你好-🐙", "VIM-LINE-096-你好-🐙"] {
            XCTAssertTrue(waitForTerminal(toContain: marker), "Vim lost pasted data: \(marker)")
        }
        shot("05 vim paste saved exactly")

        // Nano exercises real Ctrl+O / Ctrl+X handling through the sticky
        // phone-only control key, not a launch script or injected raw byte.
        typeCommand("nano /tmp/tako-ui-nano.txt")
        app.typeText("NANO-EDITED")
        app.buttons["key.ctrl"].tap()
        app.typeText("o")
        // Nano repaints this bottom-row prompt in place. Keep visual evidence
        // of the intermediate state, then prove the control sequence by the
        // file that exists after save+exit instead of making a cached AX
        // snapshot the authority over pixels that are already on screen.
        Thread.sleep(forTimeInterval: 0.5)
        shot("06 nano write prompt")
        tapSoftwareReturn()
        app.buttons["key.ctrl"].tap()
        app.typeText("x")
        typeCommand("cat /tmp/tako-ui-nano.txt; printf 'AFTER-NANO\\n'")
        XCTAssertTrue(waitForTerminal(toContain: "NANO-EDITED"), "Nano did not save the edit")
        XCTAssertTrue(waitForTerminal(toContain: "AFTER-NANO"), "Nano did not restore the shell")
        shot("07 nano control-key save")

        // tmux is a nested PTY and alternate screen. A marker produced inside
        // it and another after its shell exits prove both halves rendered.
        typeCommand("/opt/homebrew/bin/tmux -L tako-ui -f /dev/null new-session")
        typeCommand("printf 'TMUX-INSIDE\\n'")
        XCTAssertTrue(waitForTerminal(toContain: "TMUX-INSIDE"), "tmux never became interactive")
        shot("08 tmux nested shell")
        typeCommand("exit")
        typeCommand("printf 'AFTER-TMUX\\n'")
        XCTAssertTrue(waitForTerminal(toContain: "AFTER-TMUX"), "tmux did not return to the host shell")

        // top is continuously redrawn rather than appended. Its screen must
        // be legible and q must hand control back without corrupting history.
        typeCommand("top -o cpu")
        XCTAssertTrue(waitForTerminal(toContain: "Processes", timeout: 20), "top never drew")
        shot("09 top live screen")
        app.typeText("q")
        typeCommand("printf 'AFTER-TOP\\n'")
        XCTAssertTrue(waitForTerminal(toContain: "AFTER-TOP"), "top did not restore the shell")

        // A single, fast UIKit insertion is deliberately different from a
        // paste. The far end counts 1024 alphanumeric bytes so a dropped or
        // duplicated chunk cannot hide behind terminal echo.
        let burst = String(repeating: "0123456789abcdef", count: 64)
        typeCommand("printf %s \(burst) | wc -c")
        XCTAssertTrue(waitForTerminal(toContain: "1024"), "fast typing lost or duplicated bytes")
        shot("10 1024-byte typing burst")

        // Keep receiving while the app is backgrounded. This is the common
        // `tail -f`, lock-phone, return-later path rather than backgrounding
        // only after the output has already stopped.
        typeCommand(
            "sleep 1; seq 1 2000 | sed 's/^/BG-STREAM-/'"
        )
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        XCTAssertTrue(app.buttons["key.esc"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitForTerminal(toContain: "BG-STREAM-2000", timeout: 20),
                      "output received in the background never reached the screen: \(terminalText())")
        shot("11 background stream completed")

        // Thousands of real shell lines exercise the renderer, scrollback
        // and accessibility mirror under sustained output, not a 2 KB echo.
        typeCommand("seq 1 5000 | sed 's/^/LOAD-LINE-/'")
        XCTAssertTrue(waitForTerminal(toContain: "LOAD-LINE-5000", timeout: 30),
                      "the live tail stalled under sustained output")
        shot("12 five thousand line tail")

        typeCommand(
            "/opt/homebrew/bin/tmux -L tako-ui kill-server >/dev/null 2>&1; "
                + "rm -f /tmp/tako-ui-less.txt /tmp/tako-ui-vim.txt /tmp/tako-ui-nano.txt; "
                + "printf 'WORKLOADS-DONE\\n'"
        )
        XCTAssertTrue(waitForTerminal(toContain: "WORKLOADS-DONE"))
        shot("13 real workloads complete")
    }

    /// Two ports on one host are two SSH endpoints. Both connections must
    /// coexist, keep their own remote working directory, and survive card
    /// switching without an implicit reconnect destroying shell state.
    func testTwoRealOpenSSHSessionsRemainIndependent() {
        openRealSSHSession(port: openSSHPort, resetState: true)
        typeCommand("cd /tmp; printf 'SESSION-ONE-READY\\n'")
        XCTAssertTrue(waitForTerminal(toContain: "SESSION-ONE-READY"))
        shot("01 first SSH session")
        app.buttons["terminal.back"].tap()

        openRealSSHSession(port: secondOpenSSHPort, resetState: false)
        typeCommand("cd /System/Library; printf 'SESSION-TWO-READY\\n'")
        XCTAssertTrue(waitForTerminal(toContain: "SESSION-TWO-READY"))
        shot("02 second SSH session")
        app.buttons["terminal.back"].tap()

        let first = sessionCard(port: openSSHPort)
        let second = sessionCard(port: secondOpenSSHPort)
        XCTAssertTrue(first.waitForExistence(timeout: 5), "the first endpoint was replaced")
        XCTAssertTrue(second.waitForExistence(timeout: 5), "the second endpoint was not saved")
        shot("03 two live session cards")

        first.tap()
        XCTAssertTrue(app.buttons["key.esc"].waitForExistence(timeout: 10))
        typeCommand("pwd; printf 'SESSION-ONE-STILL-LIVE\\n'")
        XCTAssertTrue(waitForTerminal(toContain: "/tmp"),
                      "opening the first card restarted its remote shell")
        XCTAssertTrue(waitForTerminal(toContain: "SESSION-ONE-STILL-LIVE"))
        shot("04 first shell state retained")
        app.buttons["terminal.back"].tap()

        sessionCard(port: secondOpenSSHPort).tap()
        XCTAssertTrue(app.buttons["key.esc"].waitForExistence(timeout: 10))
        typeCommand("pwd; printf 'SESSION-TWO-STILL-LIVE\\n'")
        XCTAssertTrue(waitForTerminal(toContain: "/System/Library"),
                      "opening the second card restarted its remote shell")
        XCTAssertTrue(waitForTerminal(toContain: "SESSION-TWO-STILL-LIVE"))
        shot("05 second shell state retained")
    }

    /// The fault proxy aborts the encrypted TCP stream while leaving its
    /// listener and the real OpenSSH server running. The UI must explain the
    /// loss and its Reconnect path must perform a fresh working handshake.
    func testAbruptNetworkLossCanReconnectThroughTheUI() {
        openRealSSHSession(port: faultProxyPort, resetState: true)
        typeCommand("printf 'BEFORE-NETWORK-DROP\\n'")
        XCTAssertTrue(waitForTerminal(toContain: "BEFORE-NETWORK-DROP"))
        shot("01 before abrupt network loss")

        dropFaultProxyConnections()
        // `.accessibilityElement(children: .combine)` intentionally lets
        // SwiftUI choose the semantic element type, so do not hard-code it
        // as `Other` (it may be exposed as static text on another iOS).
        let status = app.descendants(matching: .any)
            .matching(identifier: "session.status").firstMatch
        let disconnected = NSPredicate(
            format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
            "disconnected", "disconnected"
        )
        expectation(for: disconnected, evaluatedWith: status)
        waitForExpectations(timeout: 15)
        shot("02 network loss explained")

        app.buttons["terminal.back"].tap()
        let card = sessionCard(port: faultProxyPort)
        XCTAssertTrue(card.waitForExistence(timeout: 5), "the lost session vanished from the list")
        card.tap()
        XCTAssertTrue(app.buttons["key.esc"].waitForExistence(timeout: 15),
                      "Reconnect did not reopen the terminal")
        typeCommand("printf 'AFTER-NETWORK-RECONNECT\\n'")
        XCTAssertTrue(waitForTerminal(toContain: "AFTER-NETWORK-RECONNECT", timeout: 20),
                      "the reconnected SSH session could not run a command")
        shot("03 fresh SSH after network loss")
    }

    /// A remembered fingerprint that no longer matches is not another first
    /// connection. The app must refuse to offer Trust, explain the mismatch,
    /// and still let the person back out to inspect the address or contact an
    /// administrator.
    func testChangedHostKeyBlocksTrustAndStillAllowsCancel() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyPath),
                      "the disposable OpenSSH key was not generated")
        app.launchArguments = [
            "-takoResetState",
            "-takoCredentialResource", "ui_test_key",
            "-takoKnownHost", host,
            "-takoKnownPort", openSSHPort,
            "-takoKnownFingerprint", "SHA256:deliberately-stale-ui-test-key",
        ]
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
        replace(app.textFields["field.port"], with: openSSHPort)
        app.buttons["auth.key"].tap()
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 5))
        app.buttons["paste from clipboard"].tap()
        XCTAssertTrue(app.secureTextFields["field.passphrase"].waitForExistence(timeout: 5))
        app.buttons["Connect"].tap()

        let changed = app.staticTexts["Host key changed"]
        XCTAssertTrue(changed.waitForExistence(timeout: 30),
                      "a stale fingerprint was not reported as a changed host key")
        XCTAssertFalse(app.buttons["Trust"].exists,
                       "a changed host key exposed a one-tap Trust escape hatch")
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5),
                      "the changed-key warning trapped the user in its sheet")
        shot("01 changed host key blocks trust")
        cancel.tap()
        XCTAssertTrue(hostField.waitForExistence(timeout: 5),
                      "Cancel did not return to the SSH form")
        shot("02 changed host key cancelled")
    }

    /// The list is what you come back to, so it has to survive a relaunch.
    func testASavedHostIsStillThereAfterRelaunch() {
        // The same server under a different name. Trusted host keys are
        // remembered per host *string*, so two tests spelling it the same way
        // share an entry -- and whichever ran second stopped seeing the
        // first-connection prompt it was there to check.
        let host = "localhost"
        app.launchArguments = ["-takoResetState"]
        app.launch()
        let newSession = app.buttons["newSession"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 10))
        newSession.tap()
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
        app.secureTextFields["field.password"].typeText(password)
        app.buttons["Connect"].tap()

        if app.buttons["Trust"].waitForExistence(timeout: 30) {
            app.buttons["Trust"].tap()
        }
        XCTAssertTrue(app.buttons["key.esc"].waitForExistence(timeout: 30))
        XCTAssertTrue(waitForTerminal(toContain: "PTY xterm-256color"))
        dismissSystemPrompt()

        app.terminate()
        // Not reset this time: whether the host survived is the whole point.
        app.launchArguments = []
        app.launch()

        // The card names the host, which is how you recognise it in a list.
        let card = app.buttons["session.\(host) · ssh"]
        XCTAssertTrue(card.waitForExistence(timeout: 10),
                      "the host was not in the list after a relaunch")
        shot("01 list after relaunch")

        // A recent remembers where to go, not what got us in. Open it through
        // the card exactly as a returning user does and prove both halves:
        // the address is filled back in, while neither authentication mode
        // contains a credential from the previous process.
        card.tap()
        let restoredHost = app.textFields["field.host"]
        XCTAssertTrue(restoredHost.waitForExistence(timeout: 5),
                      "a saved host did not reopen its connection form")
        XCTAssertEqual(restoredHost.value as? String, host)
        XCTAssertEqual(app.textFields["field.user"].value as? String, user)
        XCTAssertEqual(app.textFields["field.port"].value as? String, port)
        XCTAssertEqual(app.textViews["field.key"].value as? String ?? "", "",
                       "a private key survived the process relaunch")
        app.buttons["auth.password"].tap()
        let restoredPassword = app.secureTextFields["field.password"]
        XCTAssertTrue(restoredPassword.waitForExistence(timeout: 3))
        XCTAssertTrue((restoredPassword.value as? String ?? "").isEmpty,
                      "a password survived the process relaunch")
        shot("02 saved host requires credentials")

        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.exists, "the saved-host form has no way back to the list")
        back.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))

        card.press(forDuration: 1.0)
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the saved host has no delete action")
        delete.tap()
        XCTAssertFalse(card.waitForExistence(timeout: 2), "delete left the host card visible")
        // Wait for the removal animation too: the existence assertion sees
        // the model first, while an immediate screenshot still caught the
        // outgoing card's last animation frame.
        Thread.sleep(forTimeInterval: 0.5)
        shot("03 after delete")

        app.terminate()
        app.launch()
        XCTAssertFalse(card.waitForExistence(timeout: 5),
                       "the deleted host returned after another relaunch")
        XCTAssertTrue(app.buttons["session.local · demo"].exists,
                      "an empty saved list did not restore the demo card")
        shot("04 deletion survived relaunch")
    }

    /// iOS offers to save a password it saw typed into a secure field. The
    /// offer belongs to the system, not the app, so it cannot be turned off
    /// -- it can only be answered, and a run that does not answer it stalls
    /// behind it.
    @discardableResult
    private func dismissSystemPrompt(timeout: TimeInterval = 15) -> Bool {
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

    private func replace(_ field: XCUIElement, with value: String) {
        field.tap()
        field.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) {
            app.menuItems["Select All"].tap()
        }
        field.typeText(value)
    }

    private func beginMFAChallenge(screenshotPrefix: String) {
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

    private func openRealSSHSession(port: String, resetState: Bool) {
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

    private func sessionCard(port: String) -> XCUIElement {
        let endpoint = "\(user)@\(host):\(port)"
        return app.buttons.matching(NSPredicate(format: "label CONTAINS %@", endpoint)).firstMatch
    }

    private func testSetting(_ key: String) -> String? {
        let value = Bundle(for: WalkthroughTests.self).object(forInfoDictionaryKey: key) as? String
        return value?.isEmpty == false ? value : nil
    }

    private func typeCommand(_ command: String) {
        app.typeText(command)
        tapSoftwareReturn()
    }

    private func dropFaultProxyConnections() {
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
    private func tapSoftwareKey(
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

    private func tapSoftwareSpace(
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
    private func bytesReceived(after first: String, before last: String) -> [String] {
        let reads = terminalText().components(separatedBy: "GOT [").dropFirst().compactMap {
            $0.split(separator: "]", maxSplits: 1).first.map(String.init)
        }
        guard let start = reads.lastIndex(of: first) else { return ["no read of \(first)"] }
        let rest = reads[reads.index(after: start)...]
        guard let end = rest.firstIndex(of: last) else { return ["no read of \(last) after \(first)"] }
        return Array(rest[..<end])
    }

    private func tapSoftwareReturn(
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
    private func waitForSettledOrientation(
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
    private func latestReportedSize() -> TerminalSize? {
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

    private func waitForReportedSize(
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
    private func terminalText() -> String {
        app.textViews["terminal"].value as? String ?? ""
    }

    private func waitForTerminal(toContain needle: String, timeout: TimeInterval = 15) -> Bool {
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
    private func waitForHittable(
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

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
