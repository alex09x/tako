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

@MainActor
extension SessionTests {
    // MARK: - transport callbacks (status transitions, reconnect/close)

    func testTransportConnectedClearsChallengeAndSetsStatus() {
        let session = makeLocal(status: .connecting)
        session.authenticationChallenge = SSHAuthenticationChallenge(
            id: 1, name: "n", instructions: "i", prompts: [])
        session.transportConnected()
        XCTAssertEqual(session.status, .connected)
        XCTAssertNil(session.authenticationChallenge)
    }

    func testTransportClosedWithReason() {
        let session = makeLocal(status: .connected)
        session.transportClosed("boom")
        XCTAssertEqual(session.status, .disconnected(since: "boom"))
        XCTAssertEqual(session.crab, .failed)
    }

    func testTransportClosedWithNoReasonIsIdleNotFailed() {
        let session = makeLocal(status: .connected)
        session.transportClosed("")
        XCTAssertEqual(session.status, .disconnected(since: "closed"))
        XCTAssertEqual(session.crab, .idle)
    }

    func testTransportAuthenticationChallengeMapsPromptsInOrder() {
        let session = makeLocal()
        session.transportAuthenticationChallenge(
            challengeId: 42,
            name: "keyboard-interactive",
            instructions: "Enter your code",
            prompts: [
                SshPrompt(prompt: "Code: ", echo: false),
                SshPrompt(prompt: "Again: ", echo: true),
            ]
        )
        guard let challenge = session.authenticationChallenge else {
            return XCTFail("expected a challenge to be set")
        }
        XCTAssertEqual(challenge.id, 42)
        XCTAssertEqual(challenge.name, "keyboard-interactive")
        XCTAssertEqual(challenge.prompts.count, 2)
        XCTAssertEqual(challenge.prompts[0].id, 0)
        XCTAssertEqual(challenge.prompts[0].text, "Code: ")
        XCTAssertEqual(challenge.prompts[0].echo, false)
        XCTAssertEqual(challenge.prompts[1].id, 1)
        XCTAssertEqual(challenge.prompts[1].echo, true)
    }

    // MARK: - authentication challenge answers

    func testSubmitAuthenticationChallengeClearsIt() {
        let session = makeLocal()
        session.authenticationChallenge = SSHAuthenticationChallenge(
            id: 1, name: "", instructions: "", prompts: [])
        session.submitAuthenticationChallenge(["answer"])
        XCTAssertNil(session.authenticationChallenge)
    }

    func testSubmitAuthenticationChallengeWithNoneIsANoOp() {
        let session = makeLocal()
        session.submitAuthenticationChallenge(["answer"])
        XCTAssertNil(session.authenticationChallenge)
    }

    func testCancelAuthenticationChallengeClearsIt() {
        let session = makeLocal()
        session.authenticationChallenge = SSHAuthenticationChallenge(
            id: 1, name: "", instructions: "", prompts: [])
        session.cancelAuthenticationChallenge()
        XCTAssertNil(session.authenticationChallenge)
    }

    func testCancelAuthenticationChallengeWithNoneIsANoOp() {
        let session = makeLocal()
        session.cancelAuthenticationChallenge()
        XCTAssertNil(session.authenticationChallenge)
    }

    // MARK: - restoreTerminalFocusAfterAuthentication

    func testRestoreFocusIsNoOpWhileAChallengeIsPresented() {
        let session = makeLocal()
        session.authenticationChallenge = SSHAuthenticationChallenge(
            id: 1, name: "", instructions: "", prompts: [])
        session.restoreTerminalFocusAfterAuthentication() // must not crash
    }

    func testRestoreFocusIsNoOpWithNoSurface() {
        let session = makeLocal()
        session.restoreTerminalFocusAfterAuthentication()
    }

    func testRestoreFocusIsNoOpWhenSurfaceHasNoWindow() {
        let session = makeLocal()
        _ = MountedSurface(session: session)
        session.restoreTerminalFocusAfterAuthentication()
    }

    func testRestoreFocusBecomesFirstResponderWhenWindowed() throws {
        let session = makeLocal()
        let mounted = MountedSurface(session: session)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "hosted unit tests run inside the live app, which always has a scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        window.addSubview(mounted.view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        XCTAssertNotNil(mounted.view.window)
        session.restoreTerminalFocusAfterAuthentication()
        XCTAssertTrue(mounted.view.isFirstResponder)
    }

    // MARK: - resize / device replies / connect guards

    func testHandleResizeUpdatesTheEngine() {
        let session = makeLocal()
        session.handleResize(cols: 40, rows: 12)
        let snapshot = session.core.snapshot()
        XCTAssertEqual(snapshot.cols, 40)
        XCTAssertEqual(snapshot.rows, 12)
    }

    func testSendDeviceReplyRoutesThroughSendInput() {
        let session = makeLocal()
        session.sendDeviceReply(Data("x".utf8))
        XCTAssertTrue(session.core.bufferText().contains("x"))
    }

    func testConnectIsANoOpForALocalSession() {
        let session = makeLocal(status: .connected)
        session.connect()
        XCTAssertEqual(session.status, .connected)
    }

    func testDisconnectWithoutATransportIsSafe() {
        let session = makeLocal()
        session.authenticationChallenge = SSHAuthenticationChallenge(
            id: 1, name: "", instructions: "", prompts: [])
        session.disconnect()
        XCTAssertNil(session.authenticationChallenge)
    }

    // MARK: - status / crab presentation

    func testStatusLabels() {
        XCTAssertEqual(Session.Status.connected.label, "connected")
        XCTAssertEqual(Session.Status.connecting.label, "connecting")
        XCTAssertEqual(Session.Status.disconnected(since: "x").label, "disconnected · x")
    }

    func testStatusColors() {
        XCTAssertEqual(makeLocal(status: .connected).statusColor, Brand.ok)
        XCTAssertEqual(makeLocal(status: .connecting).statusColor, Brand.claw)
        XCTAssertEqual(makeLocal(status: .disconnected(since: "x")).statusColor, Brand.dim)
    }

    func testSessionEqualityAndHashingAreIdentityBased() {
        let a = makeLocal()
        let b = makeLocal()
        XCTAssertEqual(a, a)
        XCTAssertNotEqual(a, b)

        var set: Set<Session> = [a, b]
        XCTAssertEqual(set.count, 2)
        set.insert(a)
        XCTAssertEqual(set.count, 2)
    }
}

}
