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
    private func makeLocal(status: Session.Status = .connected) -> Session {
        Session(kind: .local, title: "local", subtitle: "demo", status: status)
    }

    private func makeSsh(
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

    // MARK: - needsCredentials / draft

    func testNeedsCredentialsFalseForLocal() {
        XCTAssertFalse(makeLocal().needsCredentials)
    }

    func testNeedsCredentialsTrueWhenNothingToAuthenticateWith() {
        XCTAssertTrue(makeSsh().needsCredentials)
    }

    func testNeedsCredentialsFalseWithKey() {
        XCTAssertFalse(makeSsh(privateKeyPEM: "pem").needsCredentials)
    }

    func testNeedsCredentialsFalseWithPassword() {
        XCTAssertFalse(makeSsh(password: "pw").needsCredentials)
    }

    func testDraftNilForLocal() {
        XCTAssertNil(makeLocal().draft)
    }

    func testDraftRoundTripsHostPortUsername() {
        let session = makeSsh()
        let draft = session.draft
        XCTAssertEqual(draft?.host, "example.com")
        XCTAssertEqual(draft?.port, "2222")
        XCTAssertEqual(draft?.username, "alex")
    }

    // MARK: - receive without a mounted surface

    func testReceiveWithoutSurfaceUpdatesTitle() {
        let session = makeLocal()
        session.receive(Data("\u{1b}]0;My Title\u{07}".utf8))
        XCTAssertEqual(session.title, "My Title")
    }

    func testReceiveWithoutSurfaceTracksCommandLifecycleSuccess() {
        let session = makeLocal()
        session.receive(Data("\u{1b}]133;C\u{07}".utf8))
        XCTAssertEqual(session.crab, .running)
        session.receive(Data("\u{1b}]133;D;0\u{07}".utf8))
        XCTAssertEqual(session.crab, .succeeded)
    }

    func testReceiveWithoutSurfaceTracksCommandLifecycleFailure() {
        let session = makeLocal()
        session.receive(Data("\u{1b}]133;C\u{07}".utf8))
        session.receive(Data("\u{1b}]133;D;7\u{07}".utf8))
        XCTAssertEqual(session.crab, .failed)
    }

    func testReceiveWithoutSurfaceCommandEndWithNoCodeCountsAsSuccess() {
        let session = makeLocal()
        session.receive(Data("\u{1b}]133;C\u{07}".utf8))
        session.receive(Data("\u{1b}]133;D\u{07}".utf8))
        XCTAssertEqual(session.crab, .succeeded)
    }

    func testReceiveWithoutSurfaceBellSetsAttention() {
        let session = makeLocal()
        session.receive(Data([0x07]))
        XCTAssertEqual(session.crab, .attention)
    }

    func testReceiveWithoutSurfaceRoutesDeviceRepliesWithoutCrashing() {
        let session = makeLocal()
        // A cursor-position query makes the engine produce reply bytes;
        // with no ssh transport attached this is a no-op send, but the
        // "route the reply back" branch still runs.
        session.receive(Data("\u{1b}[6n".utf8))
    }

    func testReceiveWithoutSurfaceSetsLastReceivedAt() {
        let session = makeLocal()
        XCTAssertNil(session.lastReceivedAt)
        session.receive(Data("hi".utf8))
        XCTAssertNotNil(session.lastReceivedAt)
    }

    // MARK: - receive with a mounted surface

    func testReceiveWithSurfaceRoutesTitleThroughTheDelegate() async {
        let session = makeLocal()
        _ = MountedSurface(session: session)
        session.receive(Data("\u{1b}]0;Mounted Title\u{07}".utf8))
        let updated = await pollUntil { session.title == "Mounted Title" }
        XCTAssertTrue(updated)
    }

    func testReceiveWithSurfaceRoutesCommandLifecycleThroughTheDelegate() async {
        let session = makeLocal()
        _ = MountedSurface(session: session)
        session.receive(Data("\u{1b}]133;C\u{07}".utf8))
        let running = await pollUntil { session.crab == .running }
        XCTAssertTrue(running)
        session.receive(Data("\u{1b}]133;D;0\u{07}".utf8))
        let succeeded = await pollUntil { session.crab == .succeeded }
        XCTAssertTrue(succeeded)
    }

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
