import Foundation
import XCTest
@testable import TakoCoreUI

#if canImport(UIKit)
import QuartzCore
import UIKit

/// A long press whose state a test can set. A real recognizer only takes a
/// state inside UIKit's recognition cycle; set from a test, it stays
/// `.possible` and the handler does nothing.
private final class MockLongPressGestureRecognizer: UILongPressGestureRecognizer {
    private var mockState: UIGestureRecognizer.State = .possible

    override var state: UIGestureRecognizer.State {
        get { mockState }
        set { mockState = newValue }
    }
}

private final class MockPanGestureRecognizer: UIPanGestureRecognizer {
    private var mockState: UIGestureRecognizer.State = .possible
    private var mockTranslation: CGPoint = .zero
    private var mockLocation: CGPoint = .zero
    private var mockVelocity: CGPoint = .zero

    override var state: UIGestureRecognizer.State {
        get { mockState }
        set { mockState = newValue }
    }

    override func translation(in view: UIView?) -> CGPoint {
        mockTranslation
    }

    override func setTranslation(_ translation: CGPoint, in view: UIView?) {
        mockTranslation = translation
    }

    override func location(in view: UIView?) -> CGPoint {
        mockLocation
    }

    func setMockLocation(_ point: CGPoint) {
        mockLocation = point
    }

    override func velocity(in view: UIView?) -> CGPoint {
        mockVelocity
    }

    func setMockVelocity(_ velocity: CGPoint) {
        mockVelocity = velocity
    }
}

@MainActor
final class MockTerminalViewDelegate: TakoTerminalViewDelegate {
    var inputDataReceived = Data()
    var deviceReplyDataReceived = Data()
    var lastResizedCols: Int?
    var lastResizedRows: Int?
    var resizeCount = 0
    var lastTitle: String?
    var onTitleChange: ((String) -> Void)?
    var bellCount = 0

    func terminalView(_ view: TakoTerminalView, sendInputData data: Data) {
        inputDataReceived.append(data)
    }

    func terminalView(_ view: TakoTerminalView, sendDeviceReplyData data: Data) {
        deviceReplyDataReceived.append(data)
    }

    func terminalView(_ view: TakoTerminalView, didResizeCols cols: Int, rows: Int) {
        resizeCount += 1
        lastResizedCols = cols
        lastResizedRows = rows
    }

    func terminalView(_ view: TakoTerminalView, didChangeTitle title: String) {
        lastTitle = title
        onTitleChange?(title)
    }

    func terminalViewDidBell(_ view: TakoTerminalView) {
        bellCount += 1
    }

    var clipboardCopies: [String] = []
    var lastWorkingDirectory: String?
    var scrollPositions: [Double] = []
    var contentChangeCount = 0
    var commandStartCount = 0
    var commandExitCodes: [Int32?] = []

    func terminalView(_ view: TakoTerminalView, didRequestClipboardCopy text: String) {
        clipboardCopies.append(text)
    }

    func terminalView(_ view: TakoTerminalView, didChangeWorkingDirectory url: String) {
        lastWorkingDirectory = url
    }

    func terminalView(_ view: TakoTerminalView, didScrollTo position: Double) {
        scrollPositions.append(position)
    }

    func terminalViewDidChangeContent(_ view: TakoTerminalView) {
        contentChangeCount += 1
    }

    func terminalViewCommandDidStart(_ view: TakoTerminalView) {
        commandStartCount += 1
    }

    func terminalView(_ view: TakoTerminalView, commandDidEnd exitCode: Int32?) {
        commandExitCodes.append(exitCode)
    }
}
#endif

/// A stand-in for the main queue: an application lands here instead of being
/// dispatched, so a test decides exactly when it runs and can see how many
/// were ever outstanding at once.
private final class RecordedMainQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [() -> Void] = []
    private var peak = 0

    func dispatch(_ block: @escaping () -> Void) {
        lock.lock()
        blocks.append(block)
        peak = max(peak, blocks.count)
        lock.unlock()
    }

    /// Run everything queued, including anything queued while running.
    @discardableResult
    func drain() -> Int {
        var ran = 0
        while true {
            lock.lock()
            let next = blocks.isEmpty ? nil : blocks.removeFirst()
            lock.unlock()
            guard let next else { return ran }
            next()
            ran += 1
        }
    }

    /// The most applications ever waiting here at one time.
    var peakDepth: Int { lock.withLock { peak } }
}

/// Records what a main application was handed, in the order it was handed it.
private final class AppliedOutcomeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var applications: [[FfiFeedOutcome]] = []

    func record(_ outcomes: [FfiFeedOutcome]) {
        lock.lock()
        applications.append(outcomes)
        lock.unlock()
    }

    var applicationCount: Int { lock.withLock { applications.count } }
    var outcomes: [FfiFeedOutcome] { lock.withLock { applications.flatMap { $0 } } }
    var events: [FfiEvent] { outcomes.flatMap { $0.events } }
    var deviceReplies: Data { outcomes.reduce(into: Data()) { $0.append($1.output) } }

    /// How many outcomes would have scheduled a redraw, by the same rule the
    /// view applies: damage that mode 2026 is not holding back.
    var redrawCount: Int {
        outcomes.filter { $0.hasDamage && !$0.synchronizedOutputActive }.count
    }

    var titles: [String] {
        events.compactMap {
            if case .titleChanged(let title) = $0 { return title }
            return nil
        }
    }
}

@MainActor
final class TakoTerminalViewTests: XCTestCase {
    func testCoreFeedOutcomeRedrawDecisionsForNormalDamageOpenSyncAndCloseFlush() {
        let core = TakoCore(cols: 80, rows: 24)

        // 1. Normal damage: outcome.hasDamage == true, outcome.synchronizedOutputActive == false
        let normalOutcome = core.feedWithOutcome(bytes: Data("Normal Damage\r\n".utf8))
        XCTAssertTrue(normalOutcome.hasDamage)
        XCTAssertFalse(normalOutcome.synchronizedOutputActive)

        // 2. Open synchronized output: mode 2026 active
        let syncOpenOutcome = core.feedWithOutcome(bytes: Data("\u{001B}[?2026h".utf8))
        XCTAssertTrue(syncOpenOutcome.synchronizedOutputActive)

        let syncDamageOutcome = core.feedWithOutcome(bytes: Data("Sync output text\r\n".utf8))
        XCTAssertTrue(syncDamageOutcome.synchronizedOutputActive)
        XCTAssertFalse(syncDamageOutcome.hasDamage, "Damage notification is suppressed while synchronized output mode is open")

        // 3. Close/flush: mode 2026 inactive, damage is flushed
        let syncCloseOutcome = core.feedWithOutcome(bytes: Data("\u{001B}[?2026l".utf8))
        XCTAssertFalse(syncCloseOutcome.synchronizedOutputActive)
        XCTAssertTrue(syncCloseOutcome.hasDamage, "Flushed damage must be present when sync output closes")

        // Redraw decision criteria: outcome.hasDamage && !outcome.synchronizedOutputActive
        XCTAssertTrue(normalOutcome.hasDamage && !normalOutcome.synchronizedOutputActive)
        XCTAssertFalse(syncDamageOutcome.hasDamage && !syncDamageOutcome.synchronizedOutputActive)
        XCTAssertTrue(syncCloseOutcome.hasDamage && !syncCloseOutcome.synchronizedOutputActive)
    }

    // MARK: - Off-main parser coordination

    private func makeCoordinator(
        core: TakoCore,
        main: RecordedMainQueue,
        recorder: AppliedOutcomeRecorder
    ) -> TerminalParserCoordinator {
        let coordinator = TerminalParserCoordinator(core: core, mainDispatch: main.dispatch)
        coordinator.setMainApplicationHandler(recorder.record)
        return coordinator
    }

    /// The engine is driven on the parser queue even when the feed came from
    /// the main thread -- which is the one thing the whole coordinator is
    /// for. The feed is posted to Main explicitly so the assertion is about
    /// where parsing happened, not about where the test runner happens to
    /// run.
    func testParserNeverDrivesTheEngineFromTheMainThread() {
        let main = RecordedMainQueue()
        let recorder = AppliedOutcomeRecorder()
        let core = TakoCore(cols: 80, rows: 24)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        let fed = expectation(description: "fed from the main thread")
        DispatchQueue.main.async {
            XCTAssertTrue(Thread.isMainThread)
            coordinator.feedSynchronously(Data("Parsed off Main\r\n".utf8))
            coordinator.enqueue(Data("So is this\r\n".utf8))
            fed.fulfill()
        }
        waitForExpectations(timeout: 10)
        coordinator.waitForParserQuiescence()
        main.drain()

        XCTAssertEqual(coordinator.mainThreadBatchCount, 0, "the engine must never be driven from Main")
        XCTAssertGreaterThanOrEqual(coordinator.batchCount, 1)
        XCTAssertEqual(coordinator.appliedOutcomeCount, coordinator.batchCount, "every batch applied exactly once")
        XCTAssertTrue(core.getPlainText(startRow: 0, maxRows: 4).contains("Parsed off Main"))
    }

    /// A synchronous feed has already been parsed and applied by the time it
    /// returns, so a device reply is delivered before any input that depends
    /// on it -- and it needs no second hop through Main to do it.
    func testSynchronousFeedAppliesDeviceRepliesBeforeReturning() {
        let main = RecordedMainQueue()
        let recorder = AppliedOutcomeRecorder()
        let core = TakoCore(cols: 80, rows: 24)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        coordinator.feedSynchronously(Data("\u{001B}[5n".utf8))

        XCTAssertFalse(recorder.deviceReplies.isEmpty, "the DSR reply is in hand before the feed returns")
        XCTAssertEqual(main.peakDepth, 0, "a synchronous feed applies inline, not through a second hop")
        XCTAssertEqual(coordinator.mainThreadBatchCount, 0)
    }

    /// Batches are applied in the order they were parsed, and the order they
    /// were parsed is the order they were fed. Each chunk names itself, so
    /// the applied event stream is the feed order written out.
    func testParserAppliesBatchesInStrictFeedOrder() {
        let main = RecordedMainQueue()
        let recorder = AppliedOutcomeRecorder()
        let core = TakoCore(cols: 80, rows: 24)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        let expected = (0..<64).map { "title-\($0)" }
        for title in expected {
            coordinator.enqueue(Data("\u{001B}]0;\(title)\u{0007}".utf8))
        }
        // A batch parsed after the last application was drained schedules
        // one of its own, so keep going until both sides are quiet.
        for _ in 0..<8 {
            coordinator.waitForParserQuiescence()
            if main.drain() == 0 { break }
        }

        XCTAssertEqual(recorder.titles, expected, "no title dropped, duplicated or reordered")
        XCTAssertLessThanOrEqual(main.peakDepth, 1, "at most one application outstanding")
        XCTAssertEqual(coordinator.peakOutstandingMainApplications, 1)
    }

    /// A burst past the batch bound becomes several batches rather than one
    /// unbounded call -- and still one application, carrying every one of
    /// them, in order.
    func testParserBoundsBatchesAndApplicationsUnderALargeBurst() {
        let main = RecordedMainQueue()
        let recorder = AppliedOutcomeRecorder()
        let core = TakoCore(cols: 80, rows: 24)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        // One byte short of the bound, then a four-byte code point straddling
        // it, then a marker that has to survive to the far side of the cut.
        var burst = Data(repeating: UInt8(ascii: "A"), count: TerminalParserCoordinator.maxBatchBytes - 1)
        burst.append(Data("\u{1F389}\r\nEDGE-MARKER\r\n".utf8))
        coordinator.enqueue(burst)
        coordinator.waitForParserQuiescence()
        let applications = main.drain()

        XCTAssertEqual(coordinator.batchCount, 2, "a burst past the bound is two batches, not one")
        XCTAssertEqual(
            coordinator.largestBatchByteCount,
            TerminalParserCoordinator.maxBatchBytes - 1,
            "the cut backs off the bound rather than splitting the code point"
        )
        XCTAssertLessThanOrEqual(coordinator.largestBatchByteCount, TerminalParserCoordinator.maxBatchBytes)
        XCTAssertEqual(applications, 1, "two batches, one application")
        XCTAssertEqual(main.peakDepth, 1)
        XCTAssertEqual(coordinator.peakOutstandingMainApplications, 1)
        XCTAssertEqual(coordinator.appliedOutcomeCount, 2, "no batch dropped, none applied twice")
        XCTAssertEqual(recorder.applicationCount, 1)
        XCTAssertTrue(core.getPlainText(startRow: 0, maxRows: 24).contains("EDGE-MARKER"))
    }

    /// Where the bound falls inside a UTF-8 sequence the cut moves back to
    /// the sequence's own start, so no batch boundary can ever change what
    /// the bytes decode to.
    func testBatchCutNeverSplitsAUtf8Sequence() {
        func length(_ bytes: [UInt8], limit: Int) -> Int {
            TerminalParserCoordinator.batchLength(for: Data(bytes), limit: limit)
        }

        // Everything that fits is one batch.
        XCTAssertEqual(length([0x41, 0x42], limit: 8), 2)
        XCTAssertEqual(length([], limit: 8), 0)
        // ASCII cuts exactly at the bound.
        XCTAssertEqual(length([UInt8](repeating: 0x41, count: 10), limit: 4), 4)
        // Two-, three- and four-byte sequences straddling the bound are held
        // back whole for the next batch.
        XCTAssertEqual(length([0x41, 0x41, 0x41, 0xC3, 0xA9, 0x41], limit: 4), 3)
        XCTAssertEqual(length([0x41, 0x41, 0x41, 0xE2, 0x82, 0xAC, 0x41], limit: 5), 3)
        XCTAssertEqual(length([0x41, 0x41, 0x41, 0xF0, 0x9F, 0x8E, 0x89, 0x41], limit: 6), 3)
        // A sequence that ends exactly on the bound is already whole.
        XCTAssertEqual(length([0x41, 0xC3, 0xA9, 0x41, 0x41], limit: 3), 3)
        // Malformed input keeps the full bound rather than starving the
        // batch: a continuation run no code point could produce, and one
        // that reaches the start of the buffer.
        XCTAssertEqual(length([UInt8](repeating: 0x80, count: 10), limit: 5), 5)
        XCTAssertEqual(length([0x80, 0x80, 0x80], limit: 1), 1)
    }

    /// A code point split across two feeds still decodes: the parser's own
    /// state carries across batches, and the coordinator never re-orders or
    /// re-feeds the halves.
    func testSplitUtf8AcrossFeedsDecodesAsOneCodePoint() {
        let main = RecordedMainQueue()
        let recorder = AppliedOutcomeRecorder()
        let core = TakoCore(cols: 80, rows: 24)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        // "\u{1F389} Split" with the emoji cut after its first two bytes.
        coordinator.enqueue(Data([0xF0, 0x9F]))
        coordinator.enqueue(Data([0x8E, 0x89]))
        coordinator.enqueue(Data(" Split\r\n".utf8))
        coordinator.waitForParserQuiescence()
        main.drain()

        XCTAssertEqual(core.getPlainText(startRow: 0, maxRows: 2), "\u{1F389} Split")
    }

    /// Mode 2026 holds every redraw back while it is open, and the feed that
    /// closes it reports the accumulated damage exactly once.
    func testSynchronizedOutputSuppressesThenFlushesOnClose() {
        let main = RecordedMainQueue()
        let recorder = AppliedOutcomeRecorder()
        let core = TakoCore(cols: 80, rows: 24)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        // Separate feeds, so the three states stay separable batches.
        coordinator.feedSynchronously(Data("\u{001B}[?2026h".utf8))
        coordinator.feedSynchronously(Data("Buffered during sync\r\n".utf8))
        XCTAssertTrue(core.isSynchronizedOutputActive())
        XCTAssertEqual(recorder.redrawCount, 0, "nothing is painted while mode 2026 is open")

        coordinator.feedSynchronously(Data("\u{001B}[?2026l".utf8))
        XCTAssertFalse(core.isSynchronizedOutputActive())
        XCTAssertEqual(recorder.redrawCount, 1, "closing mode 2026 flushes the held damage")

        main.drain()
        XCTAssertEqual(recorder.redrawCount, 1, "and does not repeat it on a later hop")
    }

    /// A host torn down with parser work still queued stops receiving work,
    /// releases its coordinator, and leaves the engine it was driving intact.
    func testShutDownWithParserWorkInFlight() {
        let main = RecordedMainQueue()
        let recorder = AppliedOutcomeRecorder()
        let core = TakoCore(cols: 80, rows: 24)
        weak var weakCoordinator: TerminalParserCoordinator?

        autoreleasepool {
            let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)
            weakCoordinator = coordinator
            for i in 0..<256 {
                coordinator.enqueue(Data("in flight \(i)\r\n".utf8))
            }
            coordinator.shutDown()
            coordinator.waitForParserQuiescence()
        }

        let appliedBeforeDrain = recorder.outcomes.count
        main.drain()
        XCTAssertEqual(recorder.outcomes.count, appliedBeforeDrain, "nothing reaches a host that has gone")
        XCTAssertNil(weakCoordinator, "queued parser work must not outlive its own coordinator")

        // The engine outlives its coordinator, so an in-flight batch can
        // never have been parsing into freed state.
        core.feed(bytes: Data("after teardown\r\n".utf8))
        XCTAssertTrue(core.getPlainText(startRow: 0, maxRows: 24).contains("after teardown"))
    }

#if canImport(UIKit)
    func testInitializationAndDefaults() {
        let core = TakoCore(cols: 80, rows: 24)
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), core: core)
        XCTAssertEqual(view.cols, 80)
        XCTAssertEqual(view.rows, 24)
        XCTAssertEqual(view.viewportOffset, 0)
        XCTAssertEqual(view.scrollbackLength, 0)
        XCTAssertTrue(view.autoFocusKeyboardOnTap)
        XCTAssertTrue(view.canBecomeFirstResponder)
        XCTAssertTrue(view.hasText)
    }

    func testFeedAndDeviceReply() {
        let core = TakoCore(cols: 80, rows: 24)
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), core: core)
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        let testText = "Hello TakoTerminalView\r\n"
        view.feed(data: Data(testText.utf8))

        let plainText = view.plainText(startRow: 0, maxRows: 5)
        XCTAssertTrue(plainText.contains("Hello TakoTerminalView"))

        // Feed DSR query sequence \e[5n
        view.feed(data: Data("\u{001B}[5n".utf8))
        XCTAssertFalse(delegate.deviceReplyDataReceived.isEmpty)
    }

    func testPTYOutputAndSplitUTF8Chunks() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        // Multi-byte UTF-8 emoji "🎉" is [0xF0, 0x9F, 0x8E, 0x89]
        let chunk1 = Data([0xF0, 0x9F])
        let chunk2 = Data([0x8E, 0x89, 0x20, 0x54, 0x65, 0x73, 0x74, 0x0D, 0x0A]) // "🎉 Test\r\n"

        view.feed(data: chunk1)
        // Mid-sequence feed should not crash
        view.feed(data: chunk2)

        let text = view.plainText(startRow: 0, maxRows: 2)
        XCTAssertTrue(text.contains("🎉 Test") || text.contains("Test"))
    }

    func testSoftwareKeyboardInput() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        view.insertText("a")
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "a")

        delegate.inputDataReceived = Data()
        view.insertText("\n")
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)

        delegate.inputDataReceived = Data()
        view.deleteBackward()
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        XCTAssertEqual(delegate.inputDataReceived.first, 0x7f)

        delegate.inputDataReceived = Data()
        view.insertText("e\u{0301}")
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "e\u{0301}")

        delegate.inputDataReceived = Data()
        view.insertText("👨‍👩‍👧‍👦")
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "👨‍👩‍👧‍👦")
    }

    func testHardwareInputOrderingAndKeyCommands() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        let keyCommands = view.keyCommands
        XCTAssertNotNil(keyCommands)
        XCTAssertFalse(keyCommands?.isEmpty ?? true)

        let sel = Selector(("handleKeyCommand:"))

        // Test Up Arrow command
        let upCommand = UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: sel)
        _ = view.perform(sel, with: upCommand)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)

        // Test Ctrl+C command
        delegate.inputDataReceived = Data()
        let ctrlCCommand = UIKeyCommand(input: "c", modifierFlags: .control, action: sel)
        _ = view.perform(sel, with: ctrlCCommand)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        XCTAssertEqual(delegate.inputDataReceived, Data([0x03]))
    }

    func testAlternateScreenPromptCtrlCQuickKeyUsesInterruptByte() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        // Alternate screen + Kitty flag 1.
        view.feed(data: Data("\u{1b}[?1049h\u{1b}[?2004h\u{1b}[=1;1u\u{1b}[?u".utf8))
        XCTAssertEqual(view.core.kittyKeyboardFlags(), 1)

        view.feed(data: Data("prompt> draft text".utf8))

        let sel = Selector(("handleKeyCommand:"))
        let ctrlCCommand = UIKeyCommand(input: "c", modifierFlags: .control, action: sel)
        _ = view.perform(sel, with: ctrlCCommand)

        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        XCTAssertEqual(delegate.inputDataReceived, Data([0x03]), "Ctrl+C in an alternate-screen prompt must emit 0x03")
    }

    func testEveryNativeUserInputPathReturnsFromScrollbackToTheLiveScreen() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        let history = (1...80)
            .map { "History line \($0)\r\n" }
            .joined()
        view.feed(data: Data(history.utf8))
        XCTAssertGreaterThan(view.scrollbackLength, 0)

        func parkInHistory() {
            view.scrollViewportUp(lines: 5)
            XCTAssertGreaterThan(view.viewportOffset, 0)
            view.feed(data: Data("background output\r\n".utf8))
            XCTAssertLessThan(delegate.scrollPositions.last ?? 1, 1)
        }

        parkInHistory()
        view.insertText("a")
        XCTAssertEqual(view.viewportOffset, 0)

        parkInHistory()
        view.deleteBackward()
        XCTAssertEqual(view.viewportOffset, 0)

        parkInHistory()
        let selector = Selector(("handleKeyCommand:"))
        let up = UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: selector)
        _ = view.perform(selector, with: up)
        XCTAssertEqual(view.viewportOffset, 0)

        parkInHistory()
        view.pasteStringProvider = { "pasted" }
        view.paste(nil)
        XCTAssertEqual(view.viewportOffset, 0)

        XCTAssertEqual(delegate.scrollPositions.last, 1, "the host must persist the live position")
    }

    func testResizeCallbacks() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        view.layoutSubviews()
        view.flushPendingResizeForTesting()

        XCTAssertNotNil(delegate.lastResizedCols)
        XCTAssertNotNil(delegate.lastResizedRows)
        XCTAssertEqual(view.cols, delegate.lastResizedCols)
        XCTAssertEqual(view.rows, delegate.lastResizedRows)
    }

    func testResizeCallbacksIgnoreTransientRotationGeometry() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        // Rotation briefly reported a four-row portrait-sized surface before
        // the final keyboard-adjusted bounds. Applying that intermediate size
        // pushed the top of a short terminal into scrollback permanently.
        view.frame = CGRect(x: 0, y: 0, width: 760, height: 150)
        view.layoutSubviews()
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        view.layoutSubviews()
        view.flushPendingResizeForTesting()

        XCTAssertEqual(delegate.resizeCount, 1)
        XCTAssertEqual(view.cols, Int(view.bounds.width / view.renderer.metrics.cellWidth))
        XCTAssertEqual(view.rows, Int(view.bounds.height / view.renderer.metrics.cellHeight))
    }

    func testAppliedOneRowRotationGeometryReturnsAdjacentHistoryToVisibleScreen() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 720, height: 120))
        view.layoutSubviews()
        view.flushPendingResizeForTesting()
        view.feed(data: Data("workspace · fixture pty ready\r\nПривет✓λ→\r\n$ ".utf8))

        // Reproduce the destructive geometry observed between landscape and
        // restored portrait. Unlike the debounce-only test above, this size
        // really applies, as it can when an orientation transition pauses.
        view.frame = CGRect(
            x: 0,
            y: 0,
            width: 720,
            height: view.renderer.metrics.cellHeight
        )
        view.layoutSubviews()
        view.flushPendingResizeForTesting()
        XCTAssertFalse(view.accessibilityValue?.contains("fixture pty ready") == true)
        XCTAssertTrue(view.bufferText.contains("fixture pty ready"))

        view.frame = CGRect(x: 0, y: 0, width: 402, height: 275)
        view.layoutSubviews()
        view.flushPendingResizeForTesting()

        XCTAssertTrue(
            view.accessibilityValue?.contains("fixture pty ready") == true,
            "restored portrait left the banner outside the visible Metal viewport"
        )
        XCTAssertTrue(view.accessibilityValue?.contains("Привет✓λ→") == true)
        XCTAssertTrue(view.accessibilityValue?.contains("$") == true)
    }

    func testResetAndScroll() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        var text = ""
        for i in 1...50 {
            text += "Line \(i)\r\n"
        }
        view.feed(data: Data(text.utf8))

        XCTAssertGreaterThan(view.scrollbackLength, 0)

        view.scrollViewportUp(lines: 5)
        XCTAssertEqual(view.viewportOffset, 5)

        view.scrollViewportDown(lines: 2)
        XCTAssertEqual(view.viewportOffset, 3)

        view.scrollViewportToBottom()
        XCTAssertEqual(view.viewportOffset, 0)

        view.scrollToOffset(10)
        XCTAssertEqual(view.viewportOffset, 10)

        view.reset()
        view.scrollViewportToBottom()
        XCTAssertEqual(view.viewportOffset, 0)
    }

    func testSelectionAndCopy() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("Hello Selection Test\r\n".utf8))

        XCTAssertNil(view.selectedText)
        XCTAssertFalse(view.core.hasSelection())

        // Start selection programmatically via core
        view.core.startSelection(row: 0, col: 0, mode: .linear)
        view.core.extendSelection(row: 0, col: 5)

        XCTAssertTrue(view.core.hasSelection())
        XCTAssertNotNil(view.selectedText)

        // Clear selection via tap handler
        let tapSel = Selector(("handleTap:"))
        let tap = UITapGestureRecognizer()
        _ = view.perform(tapSel, with: tap)
        XCTAssertFalse(view.core.hasSelection())
    }

    func testAccessibilityText() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertTrue(view.isAccessibilityElement)
        XCTAssertEqual(view.accessibilityLabel, "Terminal")
        XCTAssertTrue(view.accessibilityTraits.contains(.updatesFrequently))

        view.feed(data: Data("Accessibility Line\r\n".utf8))
        let value = view.accessibilityValue
        XCTAssertNotNil(value)
        XCTAssertTrue(value?.contains("Accessibility Line") ?? false)
    }

    func testCommandLifecycleEventsReachTheSurfaceHost() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        view.feed(data: Data("\u{1b}]133;C\u{7}".utf8))
        view.feed(data: Data("\u{1b}]133;D;17\u{7}".utf8))
        view.feed(data: Data("\u{1b}]133;D\u{7}".utf8))

        XCTAssertEqual(delegate.commandStartCount, 1)
        XCTAssertEqual(delegate.commandExitCodes.count, 2)
        XCTAssertEqual(delegate.commandExitCodes[0], 17)
        XCTAssertNil(delegate.commandExitCodes[1])
    }

    func testSoftWrapAccessibilityAndPlainText() {
        let core = TakoCore(cols: 5, rows: 4)
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), core: core)
        view.feed(data: Data("ABCDEFGH\r\nIJ".utf8))
        let text = view.plainText(startRow: 0, maxRows: 4)
        XCTAssertEqual(text, "ABCDEFGH\nIJ")
        XCTAssertEqual(view.accessibilityValue, "ABCDEFGH\nIJ")
    }

    func testSynchronizedOutputRedrawSuppression() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        // Begin synchronized update: \e[?2026h
        view.feed(data: Data("\u{001B}[?2026h".utf8))
        XCTAssertTrue(view.core.isSynchronizedOutputActive())

        view.feed(data: Data("Buffered content during sync\r\n".utf8))

        // End synchronized update: \e[?2026l
        view.feed(data: Data("\u{001B}[?2026l".utf8))
        XCTAssertFalse(view.core.isSynchronizedOutputActive())
    }

    func testHostRedrawDecisionsForNormalDamageOpenSyncAndCloseFlush() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.redrawNow()
        XCTAssertFalse(view.redrawPending)

        // 1. Normal damage: outcome.hasDamage == true, outcome.synchronizedOutputActive == false
        let normalOutcome = view.core.feedWithOutcome(bytes: Data("Normal Damage\r\n".utf8))
        XCTAssertTrue(normalOutcome.hasDamage)
        XCTAssertFalse(normalOutcome.synchronizedOutputActive)
        view.feed(data: Data("Normal Damage 2\r\n".utf8))
        XCTAssertTrue(view.redrawPending, "Normal damage must schedule a redraw")
        view.redrawNow()
        XCTAssertFalse(view.redrawPending)

        // 2. Open synchronized output: mode 2026 active
        let syncOpenOutcome = view.core.feedWithOutcome(bytes: Data("\u{001B}[?2026h".utf8))
        XCTAssertTrue(syncOpenOutcome.synchronizedOutputActive)

        let syncDamageOutcome = view.core.feedWithOutcome(bytes: Data("Sync output text\r\n".utf8))
        XCTAssertTrue(syncDamageOutcome.synchronizedOutputActive)
        XCTAssertFalse(syncDamageOutcome.hasDamage,
                       "damage notifications stay suppressed until synchronized output closes")

        view.feed(data: Data("Sync output text 2\r\n".utf8))
        XCTAssertFalse(view.redrawPending, "Redraw must be suppressed while synchronized output is active")

        // 3. Close/flush: mode 2026 inactive, retained damage causes redraw
        let syncCloseOutcome = view.core.feedWithOutcome(bytes: Data("\u{001B}[?2026l".utf8))
        XCTAssertFalse(syncCloseOutcome.synchronizedOutputActive)
        XCTAssertTrue(syncCloseOutcome.hasDamage, "Accumulated damage must be present when sync output closes")

        view.feed(data: Data("\u{001B}[?2026l".utf8))
        XCTAssertTrue(view.redrawPending, "Closing synchronized output with pending damage must schedule a redraw")
    }

    func testPasteEncoding() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        let multiLineText = "Line 1\nLine 2"
        view.insertText(multiLineText)

        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        let received = String(data: delegate.inputDataReceived, encoding: .utf8)
        XCTAssertNotNil(received)
        XCTAssertTrue(received?.contains("Line 1") ?? false)
    }

    func testRepeatedCreateDestroyNoRetainedTimers() {
        for i in 1...30 {
            let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            view.feed(data: Data("Iter \(i)\r\n".utf8))
            // Out of scope -> deinit should invalidate timer cleanly
        }
    }

    func testUIEditMenuInteractionReuse() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let controller = UIViewController()
        controller.view.addSubview(view)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        view.feed(data: Data("Edit Menu Test\r\n".utf8))

        guard view.becomeFirstResponder() else {
            throw XCTSkip("the standalone XCTest process has no UIApplication responder chain; the hosted UI walkthrough covers this path")
        }

        let longPressSel = Selector(("handleLongPress:"))
        let longPress = MockLongPressGestureRecognizer()

        for _ in 0..<5 {
            view.core.startSelection(row: 0, col: 0, mode: .linear)
            view.core.extendSelection(row: 0, col: 4)
            longPress.state = .ended
            _ = view.perform(longPressSel, with: longPress)
        }

        XCTAssertTrue(view.isFirstResponder, "Long-press selection must retain first-responder status")

        if #available(iOS 16.0, *) {
            let editMenuInteractions = view.interactions.filter { $0 is UIEditMenuInteraction }
            XCTAssertLessThanOrEqual(editMenuInteractions.count, 1)
        }
    }

    @available(iOS 16.0, *)
    func testEditMenuDelegateOffersCopyOnlyWhenSelectionExists() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("Copy Delegate Test\r\n".utf8))

        let menuDelegate = TakoTerminalViewEditMenuDelegate(terminalView: view)
        let interaction = UIEditMenuInteraction(delegate: menuDelegate)
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero)

        XCTAssertFalse(view.core.hasSelection())
        let emptyMenu = menuDelegate.editMenuInteraction(interaction, menuFor: config, suggestedActions: [])
        XCTAssertEqual(emptyMenu?.children.count, 0, "no selection must not offer a Copy action")

        view.core.startSelection(row: 0, col: 0, mode: .linear)
        view.core.extendSelection(row: 0, col: 5)
        XCTAssertTrue(view.core.hasSelection())

        let menuWithSelection = menuDelegate.editMenuInteraction(interaction, menuFor: config, suggestedActions: [])
        guard let copyAction = menuWithSelection?.children.first as? UIAction else {
            return XCTFail("expected exactly one UIAction offering Copy")
        }
        XCTAssertEqual(menuWithSelection?.children.count, 1)
        XCTAssertEqual(copyAction.title, "Copy")
    }

    @available(iOS 16.0, *)
    func testEditMenuDelegateCopyActionInvokesExistingCopyPath() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("Copy Invocation Test\r\n".utf8))
        view.core.startSelection(row: 0, col: 0, mode: .linear)
        view.core.extendSelection(row: 0, col: 3)
        XCTAssertTrue(view.core.hasSelection())

        let expectedText = view.selectedText
        XCTAssertNotNil(expectedText)
        var copiedText: String?
        view.copyStringConsumer = { copiedText = $0 }

        let menuDelegate = TakoTerminalViewEditMenuDelegate(terminalView: view)
        let interaction = UIEditMenuInteraction(delegate: menuDelegate)
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero)
        guard let copyAction = menuDelegate.editMenuInteraction(
            interaction,
            menuFor: config,
            suggestedActions: []
        )?.children.first as? UIAction else {
            return XCTFail("expected a Copy UIAction while a selection exists")
        }

        copyAction.performWithSender(nil, target: nil)

        XCTAssertEqual(copiedText, expectedText,
                       "the delegate's Copy action must invoke the view's existing copy(_:) implementation")
    }

    func testRectangularSelectionSnapshotAndSelectedText() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("AAAA\r\nBBBB\r\nCCCC\r\n".utf8))

        view.core.startSelection(row: 0, col: 1, mode: .rectangular)
        view.core.extendSelection(row: 2, col: 2)

        XCTAssertTrue(view.core.hasSelection())
        let snapshot = view.core.snapshot()
        XCTAssertNotNil(snapshot.selection)
        XCTAssertEqual(snapshot.selection?.mode, .rectangular)
        XCTAssertEqual(snapshot.selection?.startCol, 1)
        XCTAssertEqual(snapshot.selection?.endCol, 2)

        let selected = view.selectedText
        XCTAssertEqual(selected, "AA\nBB\nCC")
    }

    func testTerminalScreenPasteBracketedPasteMode() {
        let core = TakoCore(cols: 80, rows: 24)
        core.feed(bytes: Data("\u{001B}[?2004h".utf8))

        let pasteText = "echo hello"
        let encoded = core.encodePaste(text: pasteText)
        let pasteString = String(data: encoded, encoding: .utf8) ?? ""

        XCTAssertTrue(pasteString.contains("\u{001B}[200~"))
        XCTAssertTrue(pasteString.contains("echo hello"))
        XCTAssertTrue(pasteString.contains("\u{001B}[201~"))
    }

    func testScrollbackSelectionTextHighlightAndDrags() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        var text = ""
        for i in 1...50 {
            text += "History Line \(i)\r\n"
        }
        view.feed(data: Data(text.utf8))
        XCTAssertGreaterThan(view.scrollbackLength, 0)

        view.scrollViewportUp(lines: 10)
        XCTAssertEqual(view.viewportOffset, 10)

        view.core.startSelection(row: 0, col: 0, mode: .linear)
        view.core.extendSelection(row: 0, col: 13)

        let selected = view.selectedText
        XCTAssertNotNil(selected)
        XCTAssertTrue(selected?.contains("History Line") ?? false)

        let range = view.core.selectionRange()
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.startRow, 0)
        XCTAssertEqual(range?.endRow, 0)

        view.core.startSelection(row: 2, col: 10, mode: .linear)
        view.core.extendSelection(row: 0, col: 0)
        let reverseSelected = view.selectedText
        XCTAssertNotNil(reverseSelected)

        view.core.clearSelection()
        XCTAssertNil(view.selectedText)
        XCTAssertNil(view.core.selectionRange())

        view.scrollViewportToBottom()
        XCTAssertEqual(view.viewportOffset, 0)
    }

    func testReverseRectangularSelectionAndRenderingInputs() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("AAAA\r\nBBBB\r\nCCCC\r\n".utf8))

        // Drag bottom-right (row 2, col 2) to top-left (row 0, col 1)
        view.core.startSelection(row: 2, col: 2, mode: .rectangular)
        view.core.extendSelection(row: 0, col: 1)

        XCTAssertTrue(view.core.hasSelection())
        XCTAssertEqual(view.selectedText, "AA\nBB\nCC")

        let range = view.core.selectionRange()
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.startRow, 0)
        XCTAssertEqual(range?.endRow, 2)
        XCTAssertEqual(range?.startCol, 1)
        XCTAssertEqual(range?.endCol, 2)
    }

    // MARK: - Metal rendering path

    /// Whichever path is live, one redraw pulls exactly one frame out of the
    /// engine -- never a snapshot and a packed buffer fetched separately,
    /// which is what would let the two describe different terminal states.
    func testRedrawPullsExactlyOneAtomicFrame() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("Atomic frame\r\n".utf8))

        let before = view.frameFetchCount
        view.redrawNow()

        if view.metalRenderer != nil {
            XCTAssertEqual(view.frameFetchCount, before + 1, "the Metal path draws one frame per redraw")
            XCTAssertNil(view.metalUnavailableReason)
        } else {
            XCTAssertNotNil(view.metalUnavailableReason, "no renderer means a stated reason")
            let fallbackBefore = view.frameFetchCount
            let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
                view.draw(view.bounds)
            }
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertEqual(view.frameFetchCount, fallbackBefore + 1, "the CPU fallback draws one frame per pass")
        }
    }

    /// The one frame a redraw consumes is internally consistent: its packed
    /// payload is exactly as long as its own snapshot's grid claims.
    func testAtomicFrameCellsMatchItsOwnSnapshot() {
        let core = TakoCore(cols: 40, rows: 12)
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), core: core)
        view.feed(data: Data("One lock, one frame\r\n".utf8))

        let frame = view.core.renderFrame()
        let expected = Int(frame.snapshot.cols) * Int(frame.snapshot.rows) * TerminalCell.byteSize
        XCTAssertEqual(frame.packedCells.count, expected)
        XCTAssertEqual(
            TerminalMetalFramePlanner.validate(
                frame: frame,
                viewport: TerminalMetalViewport(drawableWidth: 800, drawableHeight: 600)
            ),
            .valid
        )
    }

    /// The layer is sized in drawable pixels, floored to whole ones and
    /// never zero: `nextDrawable()` vends nothing for an empty layer.
    func testDrawableSizeIsContentScaledPixels() {
        XCTAssertEqual(
            TakoTerminalView.drawableSize(for: CGSize(width: 100, height: 50), scale: 2),
            CGSize(width: 200, height: 100)
        )
        XCTAssertEqual(
            TakoTerminalView.drawableSize(for: CGSize(width: 100.4, height: 50.4), scale: 3),
            CGSize(width: 301, height: 151)
        )
        // Never zero, and never a scale below one point per pixel.
        XCTAssertEqual(
            TakoTerminalView.drawableSize(for: .zero, scale: 2),
            CGSize(width: 1, height: 1)
        )
        XCTAssertEqual(
            TakoTerminalView.drawableSize(for: CGSize(width: 10, height: 10), scale: 0),
            CGSize(width: 10, height: 10)
        )
    }

    /// Layout follows the bounds in points and the drawable in pixels.
    func testMetalLayerTracksBoundsOnLayout() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        view.layoutSubviews()

        guard let metal = view.metalLayer else {
            XCTAssertNotNil(view.metalUnavailableReason)
            return
        }
        XCTAssertEqual(metal.frame, view.bounds)
        XCTAssertEqual(metal.contentsScale, view.metalContentScale)
        XCTAssertEqual(
            metal.drawableSize,
            TakoTerminalView.drawableSize(for: view.bounds.size, scale: view.metalContentScale)
        )
        XCTAssertEqual(metal.pixelFormat, view.metalRenderer?.colorPixelFormat)
    }

    /// A theme or font change rebuilds every renderer-dependent object and
    /// leaves exactly one layer and one display link behind it.
    func testThemeChangeRebuildsRendererStateWithoutDuplicates() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let firstCellHeight = view.renderer.metrics.cellHeight
        let firstBuildCount = view.rendererBuildCount
        let firstLink = view.displayLink

        var theme = TerminalTheme.takoDefault
        theme.fontSize = 20
        theme.background = srgb(r: 0x10, g: 0x20, b: 0x30)
        view.theme = theme
        view.layoutSubviews()

        XCTAssertNotEqual(view.renderer.metrics.cellHeight, firstCellHeight, "a larger font means new cell metrics")
        XCTAssertEqual(view.rendererBuildCount, firstBuildCount + 1)
        XCTAssertLessThanOrEqual(metalLayerCount(in: view), 1, "a rebuild must not leave the old layer behind")
        XCTAssertTrue(firstLink === view.displayLink, "one display link outlives every rebuild")

        if let renderer = view.metalRenderer {
            XCTAssertEqual(renderer.planner.metrics.cellHeight, view.renderer.metrics.cellHeight)
            XCTAssertEqual(renderer.planner.palette.background, TakoTerminalView.metalPalette(for: theme).background)
        }
    }

    /// The iOS view hands its theme to the engine as base colors, as the
    /// macOS one does: a program resetting its colors lands on the theme,
    /// and a theme change recolors whatever the program left alone.
    func testThemeColorsBecomeTheEnginesBaseColors() throws {
        let core = TakoCore(cols: 20, rows: 2)
        var theme = TerminalTheme.takoDefault
        theme.foreground = srgb(r: 1, g: 2, b: 3)
        theme.palette[1] = srgb(r: 7, g: 8, b: 9)
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200), core: core, theme: theme)

        core.feed(bytes: Data("\u{1b}]10;#ffffff\u{07}\u{1b}]110\u{07}A\u{1b}[31mB".utf8))
        var a = try XCTUnwrap(core.getCell(row: 0, col: 0))
        let b = try XCTUnwrap(core.getCell(row: 0, col: 1))
        XCTAssertEqual([a.fgR, a.fgG, a.fgB], [1, 2, 3])
        XCTAssertEqual([b.fgR, b.fgG, b.fgB], [7, 8, 9])

        theme.foreground = srgb(r: 4, g: 5, b: 6)
        view.theme = theme
        a = try XCTUnwrap(core.getCell(row: 0, col: 0))
        XCTAssertEqual([a.fgR, a.fgG, a.fgB], [4, 5, 6])
    }

    /// Repeated layout, redraws and rebuilds never accumulate a second
    /// timer, a second display link or a second layer.
    func testNoDuplicateTimersDisplayLinksOrLayers() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let blinkTimer = view.blinkTimer
        let link = view.displayLink

        for width in [200.0, 400.0, 640.0] {
            view.frame = CGRect(x: 0, y: 0, width: width, height: 480)
            view.layoutSubviews()
            view.setNeedsDisplay()
            view.redrawNow()
        }

        XCTAssertTrue(blinkTimer === view.blinkTimer, "the blink timer is created once")
        XCTAssertTrue(link === view.displayLink, "layout must not add a second display link")
        XCTAssertLessThanOrEqual(metalLayerCount(in: view), 1)
    }

    /// Redraw requests coalesce: any number between two frames draws one.
    func testRedrawRequestsCoalesceIntoOnePendingFrame() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.redrawNow()
        XCTAssertFalse(view.redrawPending)

        view.setNeedsDisplay()
        view.setNeedsDisplay()
        view.scrollViewportUp(lines: 1)
        XCTAssertTrue(view.redrawPending)

        let before = view.frameFetchCount
        view.redrawNow()
        XCTAssertFalse(view.redrawPending)
        if view.metalRenderer != nil {
            XCTAssertEqual(view.frameFetchCount, before + 1, "three requests, one frame")
        }
        if let link = view.displayLink {
            XCTAssertFalse(link.isPaused, "a pending redraw un-pauses the link")
        }
    }

    /// With no device, no library or no pipeline, the CoreText path keeps
    /// drawing and every input behaviour is unchanged.
    func testCPUFallbackWhenMetalIsUnavailable() {
        TakoTerminalView.isMetalDisabledForTesting = true
        defer { TakoTerminalView.isMetalDisabledForTesting = false }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        XCTAssertNil(view.metalRenderer)
        XCTAssertNil(view.metalLayer)
        XCTAssertNil(view.displayLink, "no renderer means no display link to drive it")
        XCTAssertNotNil(view.metalUnavailableReason)
        XCTAssertEqual(metalLayerCount(in: view), 0)

        view.feed(data: Data("Fallback line\r\n".utf8))
        let before = view.frameFetchCount
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.draw(view.bounds)
        }
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertEqual(view.frameFetchCount, before + 1)

        view.insertText("a")
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "a")
        XCTAssertTrue(view.plainText(startRow: 0, maxRows: 2).contains("Fallback line"))
    }

    /// The theme's `CGColor`s reach the planner as the components the
    /// shaders expect, alpha included.
    func testMetalPaletteMirrorsTheTheme() {
        var theme = TerminalTheme.takoDefault
        theme.backgroundOpacity = 0.5
        let palette = TakoTerminalView.metalPalette(for: theme)

        XCTAssertEqual(palette.background.x, Float(0x14) / 255, accuracy: 1e-3)
        XCTAssertEqual(palette.background.y, Float(0x10) / 255, accuracy: 1e-3)
        XCTAssertEqual(palette.background.z, Float(0x0e) / 255, accuracy: 1e-3)
        XCTAssertEqual(palette.background.w, 0.5, accuracy: 1e-6)
        XCTAssertEqual(palette.foreground.x, Float(0xed) / 255, accuracy: 1e-3)
        XCTAssertEqual(palette.cursor.x, Float(0xf4) / 255, accuracy: 1e-3)
        XCTAssertEqual(palette.cursor.w, 1, accuracy: 1e-6)
    }

    /// The display link holds the view weakly, so nothing keeps it alive
    /// after its host lets go and the GPU objects go with it.
    func testViewDeallocatesReleasingRendererAndDisplayLink() {
        weak var weakView: TakoTerminalView?
        weak var weakRenderer: MetalTerminalRenderer?
        autoreleasepool {
            let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            view.feed(data: Data("Lifecycle\r\n".utf8))
            view.redrawNow()
            weakView = view
            weakRenderer = view.metalRenderer
        }
        XCTAssertNil(weakView, "a retained display link or timer would keep the view alive")
        XCTAssertNil(weakRenderer)
    }

    private func metalLayerCount(in view: TakoTerminalView) -> Int {
        (view.layer.sublayers ?? []).filter { $0 is CAMetalLayer }.count
    }

    func testResponderActivationRequiredForEditMenu() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("Responder Test\r\n".utf8))

        let longPressSel = Selector(("handleLongPress:"))
        let longPress = MockLongPressGestureRecognizer()

        view.core.startSelection(row: 0, col: 0, mode: .linear)
        view.core.extendSelection(row: 0, col: 4)

        // View is not in a UIWindow, so becomeFirstResponder() returns false
        longPress.state = .ended
        _ = view.perform(longPressSel, with: longPress)

        // Unattached view cannot become first responder, so edit menu should not present
        XCTAssertFalse(view.isFirstResponder)
    }

    // MARK: - The view's own parser coordination

    /// Let whatever the parser scheduled onto Main actually run.
    @MainActor
    private func drainMainQueue(for interval: TimeInterval = 0.2) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: interval))
    }

    /// `feed(data:)` keeps its synchronous contract -- the bytes have been
    /// parsed, the delegate has its reply and the redraw is scheduled before
    /// it returns -- without the engine ever running on Main.
    @MainActor
    func testFeedStaysSynchronousWhileParsingOffMain() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        view.redrawNow()

        view.feed(data: Data("Off main\r\n\u{001B}]0;Synchronous\u{0007}\u{001B}[5n".utf8))

        XCTAssertTrue(view.plainText(startRow: 0, maxRows: 2).contains("Off main"))
        XCTAssertEqual(delegate.lastTitle, "Synchronous")
        XCTAssertFalse(delegate.deviceReplyDataReceived.isEmpty, "the reply is out before any input can depend on it")
        XCTAssertTrue(view.redrawPending)
        XCTAssertGreaterThanOrEqual(view.parserCoordinator.batchCount, 1)
        XCTAssertEqual(view.parserCoordinator.mainThreadBatchCount, 0, "the engine must never be driven from Main")
    }

    /// The asynchronous path applies its batches on Main, in feed order,
    /// with one application outstanding however long the burst.
    @MainActor
    func testEnqueueAppliesBurstsOnMainInOrder() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        for i in 0..<64 {
            view.enqueue(data: Data("\u{001B}]0;title-\(i)\u{0007}".utf8))
        }
        view.parserCoordinator.waitForParserQuiescence()
        drainMainQueue()

        XCTAssertEqual(delegate.lastTitle, "title-63", "the last title applied is the last one fed")
        XCTAssertEqual(view.parserCoordinator.peakOutstandingMainApplications, 1)
        XCTAssertEqual(view.parserCoordinator.mainThreadBatchCount, 0)
        XCTAssertEqual(view.parserCoordinator.appliedOutcomeCount, view.parserCoordinator.batchCount)
    }

    /// A view released with parser work still queued tears down cleanly and
    /// nothing is applied onto what is left of it.
    @MainActor
    func testViewReleasedWithParserWorkInFlight() {
        weak var weakView: TakoTerminalView?
        autoreleasepool {
            let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            for i in 0..<128 {
                view.enqueue(data: Data("in flight \(i)\r\n".utf8))
            }
            weakView = view
        }
        drainMainQueue()
        XCTAssertNil(weakView, "queued parser work must not keep the view alive")
    }
#endif
}

#if canImport(UIKit)
// MARK: - The surface a detachable host needs
//
// A phone view is torn down and rebuilt whenever the OS decides, and the
// session outlives it. So the host copies the buffer out as text, stores
// where the user was, and puts them back. None of that survives being
// expressed in viewport coordinates: the viewport is the part you can see,
// and the part you can see is neither what you are copying nor where you
// were.

extension TakoTerminalViewTests {

    func testBufferTextCarriesScrollbackNotJustTheVisibleRows() {
        let view = TakoTerminalView(core: TakoCore(cols: 40, rows: 6))
        for i in 0..<50 {
            view.feed(data: Data("line\(i)\r\n".utf8))
        }

        let text = view.bufferText
        XCTAssertTrue(text.contains("line0"), "copy lost the history")
        XCTAssertTrue(text.contains("line49"), "copy lost the newest line")
    }

    func testScrollPositionRoundTripsThroughTheHost() {
        let view = TakoTerminalView(core: TakoCore(cols: 40, rows: 6))
        for i in 0..<60 {
            view.feed(data: Data("line\(i)\r\n".utf8))
        }
        view.scrollViewportUp(lines: 20)

        let saved = view.scrollPosition
        XCTAssertGreaterThan(saved, 0)
        XCTAssertLessThan(saved, 1)

        view.scrollViewportToBottom()
        XCTAssertEqual(view.scrollPosition, 1, accuracy: 0.0001)

        view.scrollPosition = saved
        XCTAssertEqual(view.viewportOffset, 20, "restoring landed on a different line")
    }

    func testAFreshViewIsAtTheTail() {
        let view = TakoTerminalView(core: TakoCore(cols: 40, rows: 6))
        XCTAssertEqual(view.scrollPosition, 1, accuracy: 0.0001)
    }

    func testOsc52ReachesTheHostRatherThanThePasteboard() {
        // Whether a program on the far end of a socket may replace what the
        // user last copied is the host's call, so the view only reports it.
        let view = TakoTerminalView(core: TakoCore(cols: 40, rows: 6))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        let payload = Data("hello".utf8).base64EncodedString()
        view.feed(data: Data("\u{1b}]52;c;\(payload)\u{07}".utf8))

        XCTAssertEqual(delegate.clipboardCopies, ["hello"])
    }

    func testWorkingDirectoryReachesTheHost() {
        let view = TakoTerminalView(core: TakoCore(cols: 40, rows: 6))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        view.feed(data: Data("\u{1b}]7;file:///Users/alex\u{07}".utf8))

        XCTAssertEqual(delegate.lastWorkingDirectory, "file:///Users/alex")
    }

    func testContentChangesAreAnnouncedOncePerBatchNotPerCell() {
        let view = TakoTerminalView(core: TakoCore(cols: 40, rows: 6))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        view.feed(data: Data("hello world".utf8))

        XCTAssertEqual(delegate.contentChangeCount, 1)
    }

    func testAnUnchangedViewportIsNotReportedAsScrolling() {
        // Output while pinned to the tail leaves the position at 1, and a
        // host storing it should not be woken for every batch.
        let view = TakoTerminalView(core: TakoCore(cols: 40, rows: 6))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        for i in 0..<20 {
            view.feed(data: Data("line\(i)\r\n".utf8))
        }

        XCTAssertTrue(delegate.scrollPositions.isEmpty,
                      "reported \(delegate.scrollPositions.count) scrolls without moving")
    }

    func testScrollingBackIsReportedToTheHost() {
        let view = TakoTerminalView(core: TakoCore(cols: 40, rows: 6))
        for i in 0..<50 {
            view.feed(data: Data("line\(i)\r\n".utf8))
        }
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        view.scrollViewportUp(lines: 10)
        view.feed(data: Data("more\r\n".utf8))

        XCTAssertFalse(delegate.scrollPositions.isEmpty, "the host never heard about the scroll")
        XCTAssertLessThan(delegate.scrollPositions.last ?? 1, 1)
    }

    func testSplitOrAsynchronouslyQueuedEscapeStreamCannotMakeSwiftRoutingDisagreeWithCoreState() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()
        let cellH = view.renderer.metrics.cellHeight

        // 1. Feed split escape sequence across feeds: "\e[?10" followed by "49h"
        view.feed(data: Data("\u{1b}[?10".utf8))
        XCTAssertFalse(view.isAlternateScreen)
        XCTAssertEqual(view.isAlternateScreen, view.core.modes().alternateScreen)

        view.feed(data: Data("49h".utf8))
        XCTAssertTrue(view.isAlternateScreen)
        XCTAssertEqual(view.isAlternateScreen, view.core.modes().alternateScreen)

        // Gesture immediately routes to alternate screen (arrow keys)
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[A")

        // 2. Split exit escape sequence across feeds: "\e[?10" followed by "49l"
        view.feed(data: Data("\u{1b}[?10".utf8))
        XCTAssertTrue(view.isAlternateScreen)
        XCTAssertEqual(view.isAlternateScreen, view.core.modes().alternateScreen)

        view.feed(data: Data("49l".utf8))
        XCTAssertFalse(view.isAlternateScreen)
        XCTAssertEqual(view.isAlternateScreen, view.core.modes().alternateScreen)

        // Gesture immediately routes to primary screen (local scrollback, no delegate input)
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(delegate.inputDataReceived.isEmpty)

        // 3. Asynchronously queued stream with enqueue(data:)
        let exp = expectation(description: "enqueued modes applied via title sentinel")
        delegate.onTitleChange = { title in
            if title == "sentinel" {
                exp.fulfill()
            }
        }
        view.enqueue(data: Data("\u{1b}[?1049h\u{1b}[?1007l\u{1b}]0;sentinel\u{07}".utf8))

        wait(for: [exp], timeout: 2.0)

        XCTAssertTrue(view.isAlternateScreen)
        XCTAssertFalse(view.isAlternateScroll)
        XCTAssertEqual(view.isAlternateScreen, view.core.modes().alternateScreen)
        XCTAssertEqual(view.isAlternateScroll, view.core.modes().alternateScroll)

        // Because mode 1007 is disabled, pan gesture produces no arrow keys
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(delegate.inputDataReceived.isEmpty)
    }

    func testTakoTerminalViewPanGestureInAlternateScreenSendsInputToDelegate() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        // 1. Primary screen pan: delegates receive no sendInputData, viewport moves
        let history = (1...50).map { "Primary line \($0)\r\n" }.joined()
        view.feed(data: Data(history.utf8))
        XCTAssertFalse(view.isAlternateScreen)

        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()

        // Panning down (translation.y > 0) -> scroll up into history
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        let cellH = view.renderer.metrics.cellHeight
        pan.setTranslation(CGPoint(x: 0, y: cellH * 3), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(delegate.inputDataReceived.isEmpty, "Primary screen pan must not send input data to PTY")
        XCTAssertGreaterThan(view.viewportOffset, 0, "Primary screen pan must move local viewport")

        // 2. Enter alternate screen (e.g. Claude Code / TUI agent)
        view.feed(data: Data("\u{1b}[?1049h".utf8))
        XCTAssertTrue(view.isAlternateScreen)
        XCTAssertTrue(view.isAlternateScroll)
        delegate.inputDataReceived = Data()

        // Alternate screen pan down (translation.y > 0) -> should send Up Arrow keys
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH * 2), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertFalse(delegate.inputDataReceived.isEmpty, "Alternate screen pan must produce input data for the agent/app")
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[A\u{1b}[A")

        // Alternate screen pan up (translation.y < 0) -> should send Down Arrow keys
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: -cellH), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[B")

        // 3. Application cursor key mode (DECCKM \e[?1h)
        view.feed(data: Data("\u{1b}[?1h".utf8))
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}OA")

        // 4. Mouse tracking enabled (\e[?1000h\e[?1006h)
        view.feed(data: Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        let mouseString = String(data: delegate.inputDataReceived, encoding: .utf8) ?? ""
        XCTAssertTrue(mouseString.hasPrefix("\u{1b}[<64;"), "Mouse tracking should produce SGR wheel up: \(mouseString)")

        // 5. Exit alternate screen -> returns to normal primary screen scrolling
        view.feed(data: Data("\u{1b}[?1049l\u{1b}[?1000l\u{1b}[?1006l".utf8))
        XCTAssertFalse(view.isAlternateScreen)
        delegate.inputDataReceived = Data()

        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(delegate.inputDataReceived.isEmpty, "Returning to primary screen without mouse tracking must not send input data")
    }

    func testTakoTerminalViewPanGestureInPrimaryScreenWithClaudeModeSequenceSendsMouseWheel() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()
        let cellH = view.renderer.metrics.cellHeight

        // Feed background history on primary screen
        let history = (1...30).map { "History line \($0)\r\n" }.joined()
        view.feed(data: Data(history.utf8))
        XCTAssertFalse(view.isAlternateScreen)
        XCTAssertEqual(view.viewportOffset, 0)

        // Claude Code mode sequence on primary screen:
        // Hide cursor (?25l), Normal tracking (?1000h), ButtonEvent tracking (?1002h), SGR format (?1006h), Bracketed paste (?2004h)
        view.feed(data: Data("\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?2004h".utf8))
        XCTAssertFalse(view.isAlternateScreen, "Claude Code operates on primary screen")
        XCTAssertEqual(view.core.modes().mouseTracking, .buttonEvent)
        XCTAssertTrue(view.core.modes().mouseSgr)

        // 1. Swiping down (panning down, translation.y > 0) -> direction .up -> sends SGR wheel up (\e[<64;...M)
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH * 2), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        let inputUpString = String(data: delegate.inputDataReceived, encoding: .utf8) ?? ""
        XCTAssertTrue(inputUpString.contains("\u{1b}[<64;"), "Primary screen with Claude mouse tracking must send SGR WheelUp: \(inputUpString)")
        XCTAssertEqual(view.viewportOffset, 0, "Local viewport must not move when mouse tracking is active")

        // 2. Swiping up (panning up, translation.y < 0) -> direction .down -> sends SGR wheel down (\e[<65;...M)
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: -cellH), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        let inputDownString = String(data: delegate.inputDataReceived, encoding: .utf8) ?? ""
        XCTAssertTrue(inputDownString.contains("\u{1b}[<65;"), "Primary screen with Claude mouse tracking must send SGR WheelDown: \(inputDownString)")
        XCTAssertEqual(view.viewportOffset, 0)

        // 3. Claude exits and restores normal terminal state
        view.feed(data: Data("\u{1b}[?1002l\u{1b}[?1000l\u{1b}[?1006l\u{1b}[?2004l\u{1b}[?25h".utf8))
        XCTAssertEqual(view.core.modes().mouseTracking, .off)

        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH * 3), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(delegate.inputDataReceived.isEmpty, "After Claude exits, pan must not send input to PTY")
        XCTAssertGreaterThan(view.viewportOffset, 0, "After Claude exits, pan must scroll local scrollback")
    }

    func testTakoTerminalViewPanGestureIgnoredDuringActiveSelection() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let longPressSel = Selector(("handleLongPress:"))
        let pan = MockPanGestureRecognizer()
        let cellH = view.renderer.metrics.cellHeight
        let cellW = view.renderer.metrics.cellWidth

        // Feed some text
        view.feed(data: Data("First row of text for selection test\r\nSecond row\r\n".utf8))

        // Start long-press selection
        let longPress = MockLongPressGestureRecognizer()
        // Begin selection at (row 0, col 0)
        longPress.state = .began
        _ = view.perform(longPressSel, with: longPress)

        XCTAssertTrue(view.core.hasSelection(), "Long press begins selection")

        // While selection is active, pan gesture should be ignored
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: view.renderer.metrics.cellHeight * 3), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertEqual(view.viewportOffset, 0, "Pan during selection must not scroll viewport")
        XCTAssertTrue(delegate.inputDataReceived.isEmpty, "Pan during selection must not send input data")
    }

    func testTakoTerminalViewPanGestureReciprocalLifecycleInClaudeMouseTrackingMode() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()
        let cellH = view.renderer.metrics.cellHeight
        let cellW = view.renderer.metrics.cellWidth

        // Claude Code mode sequence on primary screen:
        // Hide cursor (?25l), Normal (?1000h), ButtonEvent (?1002h), SGR (?1006h), Bracketed paste (?2004h)
        view.feed(data: Data("\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?2004h".utf8))
        XCTAssertFalse(view.isAlternateScreen)
        XCTAssertEqual(view.core.modes().mouseTracking, .buttonEvent)
        XCTAssertTrue(view.core.modes().mouseSgr)

        // Set touch point at col 14, row 7 (SGR: 1-based col 15, row 8)
        pan.setMockLocation(CGPoint(x: cellW * 14.5, y: cellH * 7.5))

        // Phase 1: Forward Gesture (Native swipe down -> translation.y > 0 -> WheelUp into history)
        // 4 steps of 0.75 * cellH each (total distance = 3.0 * cellH)
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)

        // Step 1: translation +0.75 * cellH -> accum = 0.75, lines = 0 -> 0 events
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH * 0.75), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertTrue(delegate.inputDataReceived.isEmpty, "Step 1 (0.75 lines) must not emit before full line threshold")

        // Step 2: translation +0.75 * cellH -> accum = 1.5, lines = 1 -> 1 WheelUp emitted, residual = 0.5
        pan.setTranslation(CGPoint(x: 0, y: cellH * 0.75), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[<64;15;8M")

        // Step 3: translation +0.75 * cellH -> accum = 1.25, lines = 1 -> 2nd WheelUp emitted, residual = 0.25
        pan.setTranslation(CGPoint(x: 0, y: cellH * 0.75), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[<64;15;8M\u{1b}[<64;15;8M")

        // Step 4: translation +0.75 * cellH -> accum = 1.0, lines = 1 -> 3rd WheelUp emitted, residual = 0.0
        pan.setTranslation(CGPoint(x: 0, y: cellH * 0.75), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[<64;15;8M\u{1b}[<64;15;8M\u{1b}[<64;15;8M")

        // End forward gesture
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        let forwardEvents = delegate.inputDataReceived

        // Phase 2: Reciprocal Gesture (Native swipe up -> translation.y < 0 -> WheelDown toward tail)
        // 4 steps of -0.75 * cellH each (total distance = -3.0 * cellH)
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)

        // Step 1: translation -0.75 * cellH -> accum = -0.75, lines = 0 -> 0 events
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: -cellH * 0.75), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertTrue(delegate.inputDataReceived.isEmpty, "Reciprocal Step 1 (-0.75 lines) must not emit before full line threshold")

        // Step 2: translation -0.75 * cellH -> accum = -1.5, lines = 1 -> 1 WheelDown emitted, residual = -0.5
        pan.setTranslation(CGPoint(x: 0, y: -cellH * 0.75), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[<65;15;8M")

        // Step 3: translation -0.75 * cellH -> accum = -1.25, lines = 1 -> 2nd WheelDown emitted, residual = -0.25
        pan.setTranslation(CGPoint(x: 0, y: -cellH * 0.75), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[<65;15;8M\u{1b}[<65;15;8M")

        // Step 4: translation -0.75 * cellH -> accum = -1.0, lines = 1 -> 3rd WheelDown emitted, residual = 0.0
        pan.setTranslation(CGPoint(x: 0, y: -cellH * 0.75), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[<65;15;8M\u{1b}[<65;15;8M\u{1b}[<65;15;8M")

        // End reciprocal gesture
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        let reciprocalEvents = delegate.inputDataReceived

        // Strict Reciprocal Verification:
        // 1. Equal event count and payload size
        XCTAssertEqual(forwardEvents.count, reciprocalEvents.count, "Reciprocal gesture sequences must have identical total byte length")
        XCTAssertEqual(forwardEvents.count, 3 * "\u{1b}[<64;15;8M".utf8.count)

        // 2. Exact coordinates and button mapping
        let forwardStr = String(data: forwardEvents, encoding: .utf8) ?? ""
        let reciprocalStr = String(data: reciprocalEvents, encoding: .utf8) ?? ""
        XCTAssertEqual(forwardStr, "\u{1b}[<64;15;8M\u{1b}[<64;15;8M\u{1b}[<64;15;8M")
        XCTAssertEqual(reciprocalStr, "\u{1b}[<65;15;8M\u{1b}[<65;15;8M\u{1b}[<65;15;8M")
        XCTAssertEqual(view.viewportOffset, 0, "Local viewport offset must remain 0 during mouse-tracking pan routing")
    }

    func testTakoTerminalViewPanGestureReciprocalLifecycleWithSubLineResidualAtEnd() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()
        let cellH = view.renderer.metrics.cellHeight
        let cellW = view.renderer.metrics.cellWidth

        // Enable Claude mouse tracking mode
        view.feed(data: Data("\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?2004h".utf8))
        pan.setMockLocation(CGPoint(x: cellW * 5.0, y: cellH * 3.0)) // col 5 -> 6, row 3 -> 4

        // Forward gesture: 4 steps of +0.7 * cellH (total +2.8 * cellH, leaving +0.8 residual at end)
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed

        pan.setTranslation(CGPoint(x: 0, y: cellH * 0.7), in: view)
        _ = view.perform(panSel, with: pan) // accum = 0.7 -> 0 lines
        pan.setTranslation(CGPoint(x: 0, y: cellH * 0.7), in: view)
        _ = view.perform(panSel, with: pan) // accum = 1.4 -> 1 line, residual 0.4
        pan.setTranslation(CGPoint(x: 0, y: cellH * 0.7), in: view)
        _ = view.perform(panSel, with: pan) // accum = 1.1 -> 1 line, residual 0.1
        pan.setTranslation(CGPoint(x: 0, y: cellH * 0.7), in: view)
        _ = view.perform(panSel, with: pan) // accum = 0.8 -> 0 lines, residual 0.8

        pan.state = .ended
        _ = view.perform(panSel, with: pan) // resets accum to 0

        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[<64;6;4M\u{1b}[<64;6;4M")

        // Reciprocal gesture: 4 steps of -0.7 * cellH (total -2.8 * cellH, leaving -0.8 residual at end)
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed

        pan.setTranslation(CGPoint(x: 0, y: -cellH * 0.7), in: view)
        _ = view.perform(panSel, with: pan) // accum = -0.7 -> 0 lines
        pan.setTranslation(CGPoint(x: 0, y: -cellH * 0.7), in: view)
        _ = view.perform(panSel, with: pan) // accum = -1.4 -> 1 line, residual -0.4
        pan.setTranslation(CGPoint(x: 0, y: -cellH * 0.7), in: view)
        _ = view.perform(panSel, with: pan) // accum = -1.1 -> 1 line, residual -0.1
        pan.setTranslation(CGPoint(x: 0, y: -cellH * 0.7), in: view)
        _ = view.perform(panSel, with: pan) // accum = -0.8 -> 0 lines, residual -0.8

        pan.state = .ended
        _ = view.perform(panSel, with: pan) // resets accum to 0

        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[<65;6;4M\u{1b}[<65;6;4M")

        // Verify clean isolation: next gesture starts fresh without residual leakage
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH * 0.5), in: view)
        _ = view.perform(panSel, with: pan) // accum = 0.5 -> 0 lines (would be 1.3 if residual 0.8 leaked)
        XCTAssertTrue(delegate.inputDataReceived.isEmpty, "Subsequent gesture must not inherit residual from ended gesture")
        pan.state = .ended
        _ = view.perform(panSel, with: pan)
    }

    func testTakoTerminalViewPanGestureReciprocalLifecycleInDEC1007AlternateScrollMode() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()
        let cellH = view.renderer.metrics.cellHeight

        // Enter alternate screen with DEC1007 alternate scroll enabled
        view.feed(data: Data("\u{1b}[?1049h\u{1b}[?1007h".utf8))
        XCTAssertTrue(view.isAlternateScreen)
        XCTAssertTrue(view.isAlternateScroll)

        // Forward gesture: 3 steps of +1.0 * cellH
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        for _ in 0..<3 {
            pan.setTranslation(CGPoint(x: 0, y: cellH), in: view)
            _ = view.perform(panSel, with: pan)
        }
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[A\u{1b}[A\u{1b}[A")

        // Reciprocal gesture: 3 steps of -1.0 * cellH
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        for _ in 0..<3 {
            pan.setTranslation(CGPoint(x: 0, y: -cellH), in: view)
            _ = view.perform(panSel, with: pan)
        }
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[B\u{1b}[B\u{1b}[B")
    }

    func testTakoTerminalViewPanGestureReciprocalLifecycleInPrimaryScreenLocalScrollback() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()
        let cellH = view.renderer.metrics.cellHeight

        // Feed scrollback lines
        let history = (1...60).map { "Scrollback row \($0)\r\n" }.joined()
        view.feed(data: Data(history.utf8))
        XCTAssertFalse(view.isAlternateScreen)
        XCTAssertEqual(view.viewportOffset, 0)

        // Forward gesture (swipe down -> scroll up into history): 5 steps of 1.0 * cellH
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        for _ in 0..<5 {
            pan.setTranslation(CGPoint(x: 0, y: cellH), in: view)
            _ = view.perform(panSel, with: pan)
        }
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertEqual(view.viewportOffset, 5, "Forward gesture must move viewport 5 lines into scrollback")
        XCTAssertTrue(delegate.inputDataReceived.isEmpty, "Local scrollback must not emit PTY bytes")

        // Reciprocal gesture (swipe up -> scroll down back to tail): 5 steps of -1.0 * cellH
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        for _ in 0..<5 {
            pan.setTranslation(CGPoint(x: 0, y: -cellH), in: view)
            _ = view.perform(panSel, with: pan)
        }
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertEqual(view.viewportOffset, 0, "Reciprocal gesture must restore viewport back to live tail (offset 0)")
        XCTAssertTrue(delegate.inputDataReceived.isEmpty)
    }

    func testTakoTerminalViewPanGestureMidGestureDirectionReversal() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()
        let cellH = view.renderer.metrics.cellHeight
        let cellW = view.renderer.metrics.cellWidth

        view.feed(data: Data("\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?2004h".utf8))
        pan.setMockLocation(CGPoint(x: cellW * 10.0, y: cellH * 5.0)) // col 10 -> 11, row 5 -> 6

        // Single gesture that reverses direction mid-drag
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed

        // 1. Move down +2.5 lines -> emits 2 WheelUp, residual +0.5
        pan.setTranslation(CGPoint(x: 0, y: cellH * 2.5), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[<64;11;6M\u{1b}[<64;11;6M")

        // 2. Reverse up -3.0 lines -> accum = 0.5 - 3.0 = -2.5 -> emits 2 WheelDown, residual -0.5
        pan.setTranslation(CGPoint(x: 0, y: -cellH * 3.0), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[<64;11;6M\u{1b}[<64;11;6M\u{1b}[<65;11;6M\u{1b}[<65;11;6M")

        // 3. Move down +1.5 lines -> accum = -0.5 + 1.5 = +1.0 -> emits 1 WheelUp, residual 0.0
        pan.setTranslation(CGPoint(x: 0, y: cellH * 1.5), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[<64;11;6M\u{1b}[<64;11;6M\u{1b}[<65;11;6M\u{1b}[<65;11;6M\u{1b}[<64;11;6M")

        pan.state = .ended
        _ = view.perform(panSel, with: pan)
    }

    func testTakoTerminalViewPanGestureFloodCapClampingSymmetry() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()
        let cellH = view.renderer.metrics.cellHeight
        let cellW = view.renderer.metrics.cellWidth

        view.feed(data: Data("\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?2004h".utf8))
        pan.setMockLocation(CGPoint(x: cellW * 2.0, y: cellH * 2.0)) // col 2 -> 3, row 2 -> 3

        let maxCap = TerminalTouchScrollDecision.maxLinesPerGestureCallback
        XCTAssertEqual(maxCap, 10)

        // Single frame huge jump +30 lines
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH * 30), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        let expectedUpData = String(repeating: "\u{1b}[<64;3;3M", count: maxCap)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), expectedUpData)

        // Single frame huge jump -30 lines
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: -cellH * 30), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        let expectedDownData = String(repeating: "\u{1b}[<65;3;3M", count: maxCap)
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), expectedDownData)
    }

    func testDefaultInputViewCompatibilityAndUIKeyInputState() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertNil(view.customInputView, "Default customInputView must be nil")
        XCTAssertNil(view.inputView, "Default inputView override must return nil to preserve system keyboard")
        XCTAssertTrue(view.canBecomeFirstResponder)
        XCTAssertTrue(view.hasText)

        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        view.insertText("k")
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "k")
    }

    func testExactHostInputViewIdentityAndDynamicReplacement() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let hostView1 = UIView(frame: CGRect(x: 0, y: 0, width: 375, height: 260))
        let hostView2 = UIView(frame: CGRect(x: 0, y: 0, width: 375, height: 300))

        view.customInputView = hostView1
        XCTAssertTrue(view.inputView === hostView1, "inputView override must vend exact host-owned UIView instance")
        XCTAssertTrue(view.customInputView === hostView1)

        // Dynamic replacement with second host view
        view.customInputView = hostView2
        XCTAssertTrue(view.inputView === hostView2, "inputView must update dynamically to new host view")

        // Input view setter alias
        let hostView3 = UIView(frame: CGRect(x: 0, y: 0, width: 375, height: 200))
        view.inputView = hostView3
        XCTAssertTrue(view.customInputView === hostView3)
        XCTAssertTrue(view.inputView === hostView3)

        // Reset to nil preserves standard keyboard
        view.customInputView = nil
        XCTAssertNil(view.inputView, "Setting customInputView to nil must restore nil inputView")

        // Remains the same UIKeyInput responder throughout
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        view.customInputView = hostView1
        view.insertText("hello")
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "hello")
        view.deleteBackward()
        XCTAssertEqual(delegate.inputDataReceived.last, 0x7f)
    }

    func testExactCellGeometry53x53LayoutOn369x764View() {
        let exactWidth: CGFloat = 369.0 / 53.0
        let exactHeight: CGFloat = 764.0 / 53.0
        let theme = TerminalTheme(
            cellWidth: exactWidth,
            cellHeight: exactHeight
        )
        let view = TakoTerminalView(
            frame: CGRect(x: 0, y: 0, width: 369, height: 764),
            theme: theme
        )
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        view.layoutSubviews()
        view.flushPendingResizeForTesting()

        XCTAssertEqual(view.cols, 53, "Exact cellWidth override must produce exactly 53 columns on 369pt width")
        XCTAssertEqual(view.rows, 53, "Exact cellHeight override must produce exactly 53 rows on 764pt height")
        XCTAssertEqual(Int(view.core.cols()), 53)
        XCTAssertEqual(Int(view.core.rows()), 53)
        XCTAssertEqual(delegate.lastResizedCols, 53)
        XCTAssertEqual(delegate.lastResizedRows, 53)
    }

    func testThemeChangeSynchronizesTextAndMetalMetrics() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 369, height: 764))
        let initialTextWidth = view.renderer.metrics.cellWidth
        let initialTextHeight = view.renderer.metrics.cellHeight

        if let metalPlanner = view.metalRenderer?.planner {
            XCTAssertEqual(metalPlanner.metrics.cellWidth, initialTextWidth)
            XCTAssertEqual(metalPlanner.metrics.cellHeight, initialTextHeight)
        }

        // Apply theme with exact cell overrides
        let exactWidth: CGFloat = 369.0 / 53.0
        let exactHeight: CGFloat = 764.0 / 53.0
        view.theme = TerminalTheme(
            fontSize: 12,
            cellWidth: exactWidth,
            cellHeight: exactHeight
        )

        XCTAssertEqual(view.renderer.metrics.cellWidth, exactWidth)
        XCTAssertEqual(view.renderer.metrics.cellHeight, exactHeight)

        if let metalPlanner = view.metalRenderer?.planner {
            XCTAssertEqual(metalPlanner.metrics.cellWidth, exactWidth, "Metal planner metrics must synchronize with text metrics")
            XCTAssertEqual(metalPlanner.metrics.cellHeight, exactHeight, "Metal planner metrics must synchronize with text metrics")
            XCTAssertEqual(metalPlanner.metrics.pixelCellWidth, Float(exactWidth * view.metalContentScale))
            XCTAssertEqual(metalPlanner.metrics.pixelCellHeight, Float(exactHeight * view.metalContentScale))
        }

        view.layoutSubviews()
        view.flushPendingResizeForTesting()
        XCTAssertEqual(view.cols, 53)
        XCTAssertEqual(view.rows, 53)

        // Switch back to derived theme
        view.theme = TerminalTheme(fontSize: 14)
        let derivedMetrics = TerminalRenderer.Metrics(fontSize: 14)
        XCTAssertEqual(view.renderer.metrics.cellWidth, derivedMetrics.cellWidth)
        XCTAssertEqual(view.renderer.metrics.cellHeight, derivedMetrics.cellHeight)

        if let metalPlanner = view.metalRenderer?.planner {
            XCTAssertEqual(metalPlanner.metrics.cellWidth, derivedMetrics.cellWidth)
            XCTAssertEqual(metalPlanner.metrics.cellHeight, derivedMetrics.cellHeight)
        }
    }

    func testClaudeAlternateScreenHistorySwipesAndReverseRestorationLifecycle() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()
        let cellH = view.renderer.metrics.cellHeight
        let cellW = view.renderer.metrics.cellWidth

        // 1. Enter alternate screen with mouse tracking
        view.feed(data: Data("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h".utf8))
        XCTAssertTrue(view.isAlternateScreen)

        // 2. Initial transcript with numbered rows 1 through 30
        var initialTranscript = "\u{1b}[H\u{1b}[2J"
        for i in 1...30 {
            let word: String
            switch i {
            case 27: word = "twenty-seven"
            case 28: word = "twenty-eight"
            case 29: word = "twenty-nine"
            case 30: word = "thirty"
            default: word = "line-\(i)"
            }
            initialTranscript += "\(i) \(word)\r\n"
        }
        view.feed(data: Data(initialTranscript.utf8))
        view.redrawNow()

        // 3. Four native history swipes (swipe down -> scroll up)
        pan.setMockLocation(CGPoint(x: cellW * 5.0, y: cellH * 5.0))
        for _ in 0..<4 {
            pan.state = .began
            _ = view.perform(panSel, with: pan)
            pan.state = .changed
            pan.setTranslation(CGPoint(x: 0, y: cellH * 2.0), in: view)
            _ = view.perform(panSel, with: pan)
            pan.state = .ended
            _ = view.perform(panSel, with: pan)
        }
        XCTAssertFalse(delegate.inputDataReceived.isEmpty, "Alternate screen touch scroll under mouse tracking must emit wheel events")

        // 4. History screen updates from application
        var historyTranscript = "\u{1b}[H\u{1b}[2J"
        for i in 1...30 {
            let word: String
            switch i {
            case 27: word = "twenty-seven"
            case 28: word = "twenty-eight"
            case 29: word = "twenty-nine"
            case 30: word = "thirty"
            default: word = "hist-\(i)"
            }
            historyTranscript += "  \(word)\r\n"
        }
        view.feed(data: Data(historyTranscript.utf8))
        view.redrawNow()

        // 5. Up to eight reverse swipes back to tail (swipe up -> scroll down)
        for _ in 0..<8 {
            pan.state = .began
            _ = view.perform(panSel, with: pan)
            pan.state = .changed
            pan.setTranslation(CGPoint(x: 0, y: -cellH * 2.0), in: view)
            _ = view.perform(panSel, with: pan)
            pan.state = .ended
            _ = view.perform(panSel, with: pan)
        }

        // 6. Restored tail transcript
        var restoredTailTranscript = "\u{1b}[H\u{1b}[2J"
        for i in 1...26 {
            restoredTailTranscript += "\(i) line-\(i)\r\n"
        }
        restoredTailTranscript += "27\r\n28\r\n29\r\n30\r\n"
        view.feed(data: Data(restoredTailTranscript.utf8))
        view.redrawNow()

        // 7. Verify authoritative text and renderer consistency
        let plainText = view.plainText(startRow: 0, maxRows: 53)
        XCTAssertTrue(plainText.contains("27\n28\n29\n30"))
        XCTAssertFalse(plainText.contains("27twenty-seven"))
        XCTAssertFalse(plainText.contains("28twenty-eight"))

        if let planner = view.metalRenderer?.planner {
            let frame = view.core.renderFrame()
            let stats = planner.plan(frame: frame, viewport: TerminalMetalViewport(drawableWidth: Float(view.bounds.width), drawableHeight: Float(view.bounds.height)))
            let freshPlanner = TerminalMetalFramePlanner(
                metrics: planner.metrics,
                palette: planner.palette
            )
            let freshStats = freshPlanner.plan(frame: frame, viewport: TerminalMetalViewport(drawableWidth: Float(view.bounds.width), drawableHeight: Float(view.bounds.height)))
            XCTAssertEqual(stats.glyphInstances, freshStats.glyphInstances, "Renderer glyph count must match fresh planner without stale glyph retention")
            XCTAssertEqual(planner.glyphInstances, freshPlanner.glyphInstances)
        }
    }

    // MARK: - Kinetic Momentum Scrolling Tests

    func testPreFixRegressionReleasedSwipeProducedZeroPostEndedMotionVsKineticMomentum() {
        TakoTerminalView.allowOffscreenKineticStepForTesting = true
        defer { TakoTerminalView.allowOffscreenKineticStepForTesting = false }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()
        let cellH = view.renderer.metrics.cellHeight

        let history = (1...60).map { "History line \($0)\r\n" }.joined()
        view.feed(data: Data(history.utf8))
        XCTAssertEqual(view.viewportOffset, 0)

        // 1. Drag forward 1 line
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH), in: view)
        _ = view.perform(panSel, with: pan)
        XCTAssertEqual(view.viewportOffset, 1)

        // 2. Pre-fix behavior on release with non-zero velocity:
        // In pre-fix code, pan.state = .ended simply reset accum to 0 with zero velocity inspection,
        // producing 0 post-ended motion.
        // With kinetic scrolling enabled, ending with velocity engages kinetic deceleration.
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: 1800.0))
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(view.isKineticScrolling, "Released swipe with velocity must activate kinetic momentum")
        XCTAssertEqual(view.kineticVelocity, 1800.0)

        // Step 10 frames of 1/60s: viewport advances beyond the 1-line gesture drag
        var stepsWithProgress = 0
        for _ in 0..<10 {
            if view.stepKineticScroll(deltaTime: 1.0 / 60.0) {
                stepsWithProgress += 1
            }
        }
        XCTAssertGreaterThan(stepsWithProgress, 0, "Kinetic momentum must advance viewport across post-release frames")
        XCTAssertGreaterThan(view.viewportOffset, 1, "Viewport offset must be greater than initial drag distance (1)")
    }

    func testTakoTerminalViewKineticScrollPrimaryScreenMonotonicDecelerationToRest() {
        TakoTerminalView.allowOffscreenKineticStepForTesting = true
        defer { TakoTerminalView.allowOffscreenKineticStepForTesting = false }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()

        let history = (1...120).map { "Row \($0)\r\n" }.joined()
        view.feed(data: Data(history.utf8))
        XCTAssertEqual(view.viewportOffset, 0)

        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: 2200.0))
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(view.isKineticScrolling)

        var lastOffset = view.viewportOffset
        var stepCount = 0
        while view.isKineticScrolling {
            _ = view.stepKineticScroll(deltaTime: 1.0 / 60.0)
            XCTAssertGreaterThanOrEqual(view.viewportOffset, lastOffset, "Offset must monotonically increase during upward scroll")
            lastOffset = view.viewportOffset
            stepCount += 1
            XCTAssertLessThan(stepCount, 500, "Momentum must reach rest in bounded steps")
        }

        XCTAssertFalse(view.isKineticScrolling)
        XCTAssertEqual(view.kineticVelocity, 0)
        XCTAssertGreaterThan(view.viewportOffset, 20, "Swipe with 2200 pt/s must advance substantial scrollback rows")
    }

    func testTakoTerminalViewKineticScrollClampAtTailAndScrollbackTop() {
        TakoTerminalView.allowOffscreenKineticStepForTesting = true
        defer { TakoTerminalView.allowOffscreenKineticStepForTesting = false }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()

        // 1. Tail clamp: starting at offset 5, swipe down toward live tail
        let history = (1...60).map { "Row \($0)\r\n" }.joined()
        view.feed(data: Data(history.utf8))
        view.scrollViewportUp(lines: 5)
        XCTAssertEqual(view.viewportOffset, 5)

        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: -4000.0)) // Swiping up -> scrolling down toward tail
        _ = view.perform(panSel, with: pan)

        while view.isKineticScrolling {
            _ = view.stepKineticScroll(deltaTime: 1.0 / 60.0)
        }
        XCTAssertEqual(view.viewportOffset, 0, "Momentum must clamp exactly at tail (offset 0)")
        XCTAssertFalse(view.isKineticScrolling, "Momentum must halt upon reaching tail")

        // 2. Scrollback top clamp: starting at top of history, swipe up into history
        view.scrollViewportUp(lines: 60)
        let topOffset = view.viewportOffset
        XCTAssertEqual(topOffset, view.scrollbackLength)

        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: 4000.0)) // Swiping down -> scrolling up
        _ = view.perform(panSel, with: pan)

        // Stepping should immediately halt since viewport is already at maximum scrollback
        _ = view.stepKineticScroll(deltaTime: 1.0 / 60.0)
        XCTAssertFalse(view.isKineticScrolling, "Momentum must halt upon reaching maximum scrollback limit")
        XCTAssertEqual(view.viewportOffset, topOffset)
    }

    func testTakoTerminalViewKineticScrollNewGestureCancellation() {
        TakoTerminalView.allowOffscreenKineticStepForTesting = true
        defer { TakoTerminalView.allowOffscreenKineticStepForTesting = false }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()

        let history = (1...60).map { "Row \($0)\r\n" }.joined()
        view.feed(data: Data(history.utf8))

        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: 2000.0))
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(view.isKineticScrolling)
        _ = view.stepKineticScroll(deltaTime: 1.0 / 60.0)
        XCTAssertTrue(view.isKineticScrolling)

        // New gesture begins: cancels active kinetic momentum immediately
        pan.state = .began
        _ = view.perform(panSel, with: pan)

        XCTAssertFalse(view.isKineticScrolling, "New gesture began must cancel active kinetic scroll")
        XCTAssertEqual(view.kineticVelocity, 0)
    }

    func testTakoTerminalViewKineticScrollSelectionCancellation() {
        TakoTerminalView.allowOffscreenKineticStepForTesting = true
        defer { TakoTerminalView.allowOffscreenKineticStepForTesting = false }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let panSel = Selector(("handlePan:"))
        let longPressSel = Selector(("handleLongPress:"))
        let pan = MockPanGestureRecognizer()
        let longPress = MockLongPressGestureRecognizer()

        let history = (1...60).map { "Row \($0)\r\n" }.joined()
        view.feed(data: Data(history.utf8))

        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: 2000.0))
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(view.isKineticScrolling)

        // User starts text selection via long press
        longPress.state = .began
        _ = view.perform(longPressSel, with: longPress)

        XCTAssertFalse(view.isKineticScrolling, "Starting selection must cancel active kinetic scroll")
    }

    func testTakoTerminalViewKineticScrollModeChangeCancellation() {
        TakoTerminalView.allowOffscreenKineticStepForTesting = true
        defer { TakoTerminalView.allowOffscreenKineticStepForTesting = false }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()

        // Enter alternate screen with mouse tracking
        view.feed(data: Data("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h".utf8))
        XCTAssertTrue(view.isAlternateScreen)

        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: 1500.0))
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(view.isKineticScrolling)
        _ = view.stepKineticScroll(deltaTime: 1.0 / 60.0)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)

        // Application leaves alternate screen and disables mouse tracking
        view.feed(data: Data("\u{1b}[?1000l\u{1b}[?1049l".utf8))

        XCTAssertFalse(view.isKineticScrolling, "Terminal mode change must cancel active kinetic momentum")
        XCTAssertFalse(view.stepKineticScroll(deltaTime: 1.0 / 60.0), "Further steps must produce nothing")
    }

    func testTakoTerminalViewKineticScrollWindowDetachmentCancellation() {
        TakoTerminalView.allowOffscreenKineticStepForTesting = true
        defer { TakoTerminalView.allowOffscreenKineticStepForTesting = false }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()

        view.feed(data: Data((1...60).map { "Row \($0)\r\n" }.joined().utf8))

        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: 1500.0))
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(view.isKineticScrolling)

        // Detach from window
        view.willMove(toWindow: nil)
        XCTAssertFalse(view.isKineticScrolling, "Moving out of window must cancel kinetic momentum")
    }

    func testTakoTerminalViewKineticScrollAlternateScreenBoundedEmissionsAndOrdering() {
        TakoTerminalView.allowOffscreenKineticStepForTesting = true
        defer { TakoTerminalView.allowOffscreenKineticStepForTesting = false }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()
        let cellW = view.renderer.metrics.cellWidth
        let cellH = view.renderer.metrics.cellHeight

        // Claude mode sequence: SGR mouse tracking (?1000h, ?1002h, ?1006h)
        view.feed(data: Data("\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?2004h".utf8))
        pan.setMockLocation(CGPoint(x: cellW * 10.0, y: cellH * 5.0)) // col 10 -> 11, row 5 -> 6

        // Upward scrollback swipe (finger down, velocity > 0)
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: 2000.0))
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(view.isKineticScrolling)
        delegate.inputDataReceived = Data()

        var totalWheelEvents = 0
        let expectedSinglePacket = "\u{1b}[<64;11;6M"

        while view.isKineticScrolling {
            let previousCount = delegate.inputDataReceived.count
            _ = view.stepKineticScroll(deltaTime: 1.0 / 60.0)
            let newBytes = delegate.inputDataReceived.dropFirst(previousCount)
            if !newBytes.isEmpty {
                let packetStr = String(data: newBytes, encoding: .utf8) ?? ""
                let packetCount = packetStr.components(separatedBy: expectedSinglePacket).count - 1
                XCTAssertLessThanOrEqual(packetCount, TerminalTouchScrollDecision.maxLinesPerGestureCallback, "Per-tick emissions must be bounded")
                totalWheelEvents += packetCount
            }
        }

        XCTAssertFalse(view.isKineticScrolling)
        XCTAssertGreaterThan(totalWheelEvents, 0, "Alternate screen kinetic momentum must emit wheel events")
    }

    func testTakoTerminalViewKineticScrollDirectionReversalReciprocity() {
        TakoTerminalView.allowOffscreenKineticStepForTesting = true
        defer { TakoTerminalView.allowOffscreenKineticStepForTesting = false }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()

        // DEC 1007 alternate scroll mode (arrow keys)
        view.feed(data: Data("\u{1b}[?1049h\u{1b}[?1007h".utf8))
        XCTAssertTrue(view.isAlternateScreen)
        XCTAssertTrue(view.isAlternateScroll)

        // 1. Forward momentum (velocity +1500.0)
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: 1500.0))
        _ = view.perform(panSel, with: pan)

        delegate.inputDataReceived = Data()
        while view.isKineticScrolling {
            _ = view.stepKineticScroll(deltaTime: 1.0 / 60.0)
        }
        let forwardStr = String(data: delegate.inputDataReceived, encoding: .utf8) ?? ""
        let upArrowCount = forwardStr.components(separatedBy: "\u{1b}[A").count - 1

        // 2. Reverse momentum (velocity -1500.0)
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: -1500.0))
        _ = view.perform(panSel, with: pan)

        delegate.inputDataReceived = Data()
        while view.isKineticScrolling {
            _ = view.stepKineticScroll(deltaTime: 1.0 / 60.0)
        }
        let reverseStr = String(data: delegate.inputDataReceived, encoding: .utf8) ?? ""
        let downArrowCount = reverseStr.components(separatedBy: "\u{1b}[B").count - 1

        XCTAssertEqual(upArrowCount, downArrowCount, "Equal opposite swipe velocities must emit identical key counts")
        XCTAssertGreaterThan(upArrowCount, 0)
    }

    func testTakoTerminalViewKineticScrollBackgroundNotificationCancellation() {
        TakoTerminalView.allowOffscreenKineticStepForTesting = true
        defer { TakoTerminalView.allowOffscreenKineticStepForTesting = false }

        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()

        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        pan.setMockVelocity(CGPoint(x: 0, y: 1500.0))
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(view.isKineticScrolling)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertFalse(view.isKineticScrolling, "App backgrounding must cancel kinetic momentum")
    }
}
#endif
