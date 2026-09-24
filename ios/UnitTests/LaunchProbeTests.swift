import Foundation
import XCTest
@testable import TakoCore

/// `LaunchProbe` drives a session the way a person driving the software
/// keyboard and key row would, so these tests give it a demo-mode
/// `Session`: no ssh transport, but a real input path and a real (if
/// unmounted-by-default) `TakoTerminalView` surface, per `TestSupport`.
@MainActor
final class LaunchProbeTests: XCTestCase {
    private let originalArguments = LaunchOptions.arguments

    override func tearDown() {
        LaunchOptions.arguments = originalArguments
        super.tearDown()
    }

    private func makeSession(status: Session.Status = .connected) -> Session {
        Session(kind: .local, title: "t", subtitle: "s", status: status)
    }

    // MARK: - deliver: plain text

    func testDeliverWithNoSurfaceSendsWholeStepAtOnce() {
        let session = makeSession()
        XCTAssertNil(session.surface)

        LaunchProbe.deliver("hi", to: session)

        // No surface: `deliver` falls back to handing the whole step to
        // `sendInput` in one call, and the demo loop (synchronous with no
        // surface mounted) echoes it straight into the engine's buffer.
        XCTAssertTrue(session.core.bufferText().contains("hi"))
    }

    func testDeliverWithSurfaceSendsOneInsertTextPerCharacter() {
        let session = makeSession()
        let mounted = MountedSurface(session: session)

        LaunchProbe.deliver("hi", to: session)

        // `insertText` calls its delegate synchronously, so this needs no
        // waiting: two characters in, two `sendInputData` calls out.
        XCTAssertEqual(mounted.delegate.sentInputs.count, 2)
        let joined = mounted.delegate.sentInputs
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined()
        XCTAssertEqual(joined, "hi")
    }

    func testDeliverEmptyStepSendsNothing() {
        let session = makeSession()
        let mounted = MountedSurface(session: session)

        LaunchProbe.deliver("", to: session)

        XCTAssertEqual(mounted.delegate.sentInputs.count, 0)
    }

    // MARK: - deliver: key-row steps ("@name+name")

    func testDeliverKeyRowControlCArmsAndFolds() {
        let session = makeSession()
        // No surface: key-row steps go straight through `sendInput`
        // regardless, but keeping this one unmounted keeps the assertion on
        // the synchronous no-surface `receive` path simple.
        LaunchProbe.deliver("@ctrl+c", to: session)

        // The demo peer answers Ctrl+C by cancelling the line and printing
        // "^C" -- proof the fold from "ctrl" + "c" actually produced 0x03,
        // not the literal letter.
        XCTAssertTrue(session.core.bufferText().contains("^C"))
    }

    func testDeliverKeyRowDashAndPipeSendLiteralGlyphs() {
        let session = makeSession()
        LaunchProbe.deliver("@dash", to: session)
        LaunchProbe.deliver("@pipe", to: session)

        XCTAssertTrue(session.core.bufferText().contains("-|"))
    }

    func testDeliverKeyRowTabInsertsFourSpaces() {
        let session = makeSession()
        LaunchProbe.deliver("@tab", to: session)
        LaunchProbe.deliver("x", to: session)

        // `bufferText()` trims each row's trailing blanks, so the spaces
        // only show once something follows them.
        XCTAssertTrue(session.core.bufferText().contains("    x"))
    }

    func testDeliverKeyRowUpArrowDoesNotLeakIntoTypedText() {
        let session = makeSession()
        LaunchProbe.deliver("@up", to: session)
        LaunchProbe.deliver("y", to: session)

        // The arrow's CSI bytes (ESC [ A) are swallowed whole by the demo's
        // escape-sequence state machine; only the plain character after it
        // should ever reach the buffer.
        let text = session.core.bufferText()
        XCTAssertTrue(text.contains("y"))
        XCTAssertFalse(text.contains("\u{1b}"))
    }

    // MARK: - send: step pacing

    func testSendDeliversStepsStepPauseApart() async {
        let session = makeSession()
        LaunchProbe.send(["a", "b", "c"][...], to: session)

        // The first step is delivered synchronously, before `send` returns.
        XCTAssertEqual(session.screenText, "a")

        let sawB = await pollUntil(timeout: LaunchProbe.stepPause + 2) {
            session.screenText == "ab"
        }
        XCTAssertTrue(sawB, "expected 'b' after one stepPause")

        let sawC = await pollUntil(timeout: LaunchProbe.stepPause + 2) {
            session.screenText == "abc"
        }
        XCTAssertTrue(sawC, "expected 'c' after a second stepPause")
    }

    func testSendOfSingleStepSchedulesNoFollowUp() async {
        let session = makeSession()
        LaunchProbe.send(["only"][...], to: session)
        XCTAssertEqual(session.screenText, "only")

        // Nothing else queued: waiting past a stepPause changes nothing.
        try? await Task.sleep(nanoseconds: UInt64((LaunchProbe.stepPause + 0.3) * 1_000_000_000))
        XCTAssertEqual(session.screenText, "only")
    }

    // MARK: - waitForConnection: connected + mounted + quiet gate

    func testWaitForConnectionSendsImmediatelyWhenAlreadyQuiet() async {
        let session = makeSession(status: .connected)
        let mounted = MountedSurface(session: session)
        session.receive(Data())
        // Let "just received" age past `promptQuiet` before asking.
        try? await Task.sleep(nanoseconds: UInt64((LaunchProbe.promptQuiet + 0.2) * 1_000_000_000))

        LaunchOptions.arguments = ["TakoCore", "-takoSend", "hi"]
        LaunchProbe.waitForConnection(session: session, giveUpAfter: 5)

        // The gate was already open, so `send` runs synchronously inside
        // this call -- no polling needed.
        XCTAssertEqual(mounted.delegate.sentInputs.count, 2)
    }

    func testWaitForConnectionWaitsOutQuietPeriodBeforeSending() async {
        let session = makeSession(status: .connected)
        let mounted = MountedSurface(session: session)
        session.receive(Data()) // freshly "loud"; not quiet yet

        LaunchOptions.arguments = ["TakoCore", "-takoSend", "x"]
        LaunchProbe.waitForConnection(session: session, giveUpAfter: 5)

        // Immediately: the quiet gate has not opened yet.
        XCTAssertEqual(mounted.delegate.sentInputs.count, 0)

        let sent = await pollUntil(timeout: LaunchProbe.promptQuiet + 2) {
            mounted.delegate.sentInputs.count == 1
        }
        XCTAssertTrue(sent, "expected a send once the quiet period elapsed")
    }

    func testWaitForConnectionGivesUpWhenNeverConnected() async {
        let session = makeSession(status: .connecting)
        let mounted = MountedSurface(session: session)

        LaunchOptions.arguments = ["TakoCore", "-takoSend", "never"]
        LaunchProbe.waitForConnection(session: session, giveUpAfter: 0.3)

        try? await Task.sleep(nanoseconds: UInt64(0.7 * 1_000_000_000))
        XCTAssertEqual(mounted.delegate.sentInputs.count, 0)
    }

    func testWaitForConnectionWithNoSendStepsDoesNothing() {
        let session = makeSession(status: .connected)
        LaunchOptions.arguments = ["TakoCore"] // no -takoSend
        // Should return immediately (empty `sendSteps` guard) rather than
        // scheduling polling work against a session nobody armed.
        LaunchProbe.waitForConnection(session: session, giveUpAfter: 5)
        XCTAssertEqual(session.screenText, "")
    }

    // MARK: - armIfAsked

    func testArmIfAskedWithNoDumpArgDoesNothing() {
        let session = makeSession()
        LaunchOptions.arguments = ["TakoCore"]
        LaunchProbe.armIfAsked(session: session) // must not schedule or crash
        XCTAssertEqual(session.screenText, "")
    }

    func testArmIfAskedSendsAndDumpsOnDeadline() async throws {
        let session = makeSession(status: .connected)
        let mounted = MountedSurface(session: session)
        session.receive(Data())
        try? await Task.sleep(nanoseconds: UInt64((LaunchProbe.promptQuiet + 0.2) * 1_000_000_000))

        let docs = try XCTUnwrap(FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first)
        let dump = docs.appendingPathComponent("dump.txt")
        try? FileManager.default.removeItem(at: dump)

        LaunchOptions.arguments = ["TakoCore", "-takoSend", "hi", "-takoDump", "0.2"]
        LaunchProbe.armIfAsked(session: session)

        let sent = await pollUntil(timeout: 3) { mounted.delegate.sentInputs.count == 2 }
        XCTAssertTrue(sent)

        let wrote = await pollUntil(timeout: 3) { FileManager.default.fileExists(atPath: dump.path) }
        XCTAssertTrue(wrote)
    }

    // MARK: - write

    func testWriteWithNoSurfaceReportsNoSurface() throws {
        let session = makeSession(status: .connected)
        let docs = try XCTUnwrap(FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first)
        let dump = docs.appendingPathComponent("dump.txt")
        try? FileManager.default.removeItem(at: dump)

        LaunchProbe.write(session: session)

        let contents = try String(contentsOf: dump, encoding: .utf8)
        XCTAssertTrue(contents.contains("<no surface>"))
        XCTAssertTrue(contents.contains("status: connected"))
    }

    func testWriteWithSurfaceIncludesBufferedText() async throws {
        let session = makeSession(status: .connected)
        let mounted = MountedSurface(session: session)
        session.receive(Data("hello".utf8))

        let landed = await pollUntil(timeout: 3) { mounted.view.bufferText.contains("hello") }
        XCTAssertTrue(landed)

        let docs = try XCTUnwrap(FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first)
        let dump = docs.appendingPathComponent("dump.txt")
        try? FileManager.default.removeItem(at: dump)

        LaunchProbe.write(session: session)

        let contents = try String(contentsOf: dump, encoding: .utf8)
        XCTAssertTrue(contents.contains("hello"))
    }
}
