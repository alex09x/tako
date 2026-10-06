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


}
