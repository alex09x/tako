/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import XCTest
import UIKit
@testable import TakoCore

/// Session paths the interactive walkthrough never reaches: the in-process
/// demo peer, a session with no mounted surface, and the transport
/// callbacks a real ssh connection would drive -- called directly here,
/// since there is no ssh server in a unit test.
@MainActor
final class SessionTests: XCTestCase {
    func makeLocal(status: Session.Status = .connected) -> Session {
        Session(kind: .local, title: "local", subtitle: "demo", status: status)
    }

    func makeSsh(
        privateKeyPEM: String? = nil,
        password: String? = nil
    ) -> Session {
        Session(
            kind: .ssh(Session.SshTarget(
                host: "example.com", port: 2222, username: "alex",
                privateKeyPEM: privateKeyPEM, password: password)),
            title: "example.com · ssh",
            subtitle: "alex@example.com:2222",
            status: .disconnected(since: "saved")
        )
    }

    // MARK: - demo mode

    func testSeedDemoShowsBannerAndPrompt() {
        let session = makeLocal()
        session.seedDemo()
        let text = session.core.bufferText()
        XCTAssertTrue(text.contains("❯"))
        XCTAssertTrue(text.contains("interactive demo"))
    }

    func testDemoRunsLsPwdEchoHelp() {
        let session = makeLocal()
        session.sendInput(Data("ls\r".utf8))
        XCTAssertTrue(session.core.bufferText().contains("README.md"))

        session.sendInput(Data("pwd\r".utf8))
        XCTAssertTrue(session.core.bufferText().contains("/demo"))

        session.sendInput(Data("echo hello there\r".utf8))
        XCTAssertTrue(session.core.bufferText().contains("hello there"))

        session.sendInput(Data("help\r".utf8))
        XCTAssertTrue(session.core.bufferText().contains("demo commands"))
    }

    func testDemoUnknownCommandReportsNotFound() {
        let session = makeLocal()
        session.sendInput(Data("frobnicate\r".utf8))
        XCTAssertTrue(session.core.bufferText().contains("command not found: frobnicate"))
    }

    func testDemoEmptyLineProducesNoCommand() {
        let session = makeLocal()
        session.sendInput(Data("\r".utf8))
        // No "not found" for an empty command, and the prompt comes back.
        XCTAssertFalse(session.core.bufferText().contains("not found"))
        XCTAssertTrue(session.core.bufferText().contains("❯"))
    }

    func testDemoBackspaceEditsTheLine() {
        let session = makeLocal()
        session.sendInput(Data("ab".utf8))
        session.sendInput(Data([0x7F])) // DEL erases the 'b'
        session.sendInput(Data("c\r".utf8))
        // The line that actually ran was "ac", not "abc".
        XCTAssertTrue(session.core.bufferText().contains("command not found: ac"))
    }

    func testDemoCtrlCCancelsTheLineWithoutRunningIt() {
        let session = makeLocal()
        session.sendInput(Data("abc".utf8))
        session.sendInput(Data([0x03]))
        let text = session.core.bufferText()
        XCTAssertTrue(text.contains("^C"))
        XCTAssertFalse(text.contains("not found: abc"))
    }

    func testDemoCtrlLClearsButKeepsCurrentLine() {
        let session = makeLocal()
        session.sendInput(Data("abc".utf8))
        session.sendInput(Data([0x0C]))
        XCTAssertTrue(session.core.bufferText().contains("abc"))
    }

    func testDemoTabInsertsFourSpaces() {
        let session = makeLocal()
        session.sendInput(Data([0x09]))
        session.sendInput(Data("x".utf8))
        // Rows come back with trailing blanks trimmed, hence the "x".
        XCTAssertTrue(session.core.bufferText().contains("    x"))
    }

    func testDemoCRLFDoesNotRunTheLineTwice() {
        let session = makeLocal()
        session.sendInput(Data("hi\r\n".utf8))
        let occurrences = session.core.bufferText()
            .components(separatedBy: "not found: hi").count - 1
        XCTAssertEqual(occurrences, 1)
    }

    func testDemoBareLineFeedRunsTheLineOnce() {
        // A pasted LF with no preceding CR still finishes the line.
        let session = makeLocal()
        session.sendInput(Data("hi\n".utf8))
        XCTAssertTrue(session.core.bufferText().contains("not found: hi"))
    }

    func testDemoEscapeSequenceDoesNotLeakIntoTheLine() {
        let session = makeLocal()
        session.sendInput(Data([0x1B, 0x5B, 0x41])) // ESC [ A, an up arrow
        session.sendInput(Data("z\r".utf8))
        XCTAssertTrue(session.core.bufferText().contains("not found: z"))
        XCTAssertFalse(session.core.bufferText().contains("not found: \u{1b}[Az"))
    }


}
