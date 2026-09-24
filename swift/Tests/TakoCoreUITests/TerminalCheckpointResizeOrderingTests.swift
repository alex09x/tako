import Foundation
import XCTest
@testable import TakoCoreUI

/// A stand-in for the main queue: an application lands here instead of being
/// dispatched, so a test decides exactly when it runs.
private final class ResizeMainQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [() -> Void] = []

    func dispatch(_ block: @escaping () -> Void) {
        lock.lock()
        blocks.append(block)
        lock.unlock()
    }

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
}

/// Records everything that reached Main, in the order Main saw it.
private final class ResizeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var stream: [String] = []
    private(set) var resizes: [(cols: Int, rows: Int)] = []

    func record(_ outcomes: [FfiFeedOutcome]) {
        let titles = outcomes.flatMap { $0.events }.compactMap { event -> String? in
            if case .titleChanged(let title) = event { return title }
            return nil
        }
        lock.lock()
        for title in titles { stream.append("title(\(title))") }
        lock.unlock()
    }

    func recordResize(cols: Int, rows: Int) {
        lock.lock()
        resizes.append((cols, rows))
        stream.append("resize(\(cols)x\(rows))")
        lock.unlock()
    }

    func recordRestore(_ restore: TerminalCheckpointRestore) {
        lock.lock()
        stream.append("restore(\(restore.cols)x\(restore.rows))")
        lock.unlock()
    }

    var events: [String] { lock.withLock { stream } }
    var appliedGeometries: [(cols: Int, rows: Int)] { lock.withLock { resizes } }
}

/// A Main queue that parks whoever hops to it until the test lets them
/// through. The coordinator's hop happens *on the parser queue*, so holding
/// it here holds the parser -- which is how a test can keep input outstanding
/// without depending on how fast anything runs.
private final class GatedMainQueue: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var arrivals = 0
    private var ran: [() -> Void] = []

    func dispatch(_ block: @escaping () -> Void) {
        lock.lock(); arrivals += 1; lock.unlock()
        gate.wait()
        block()
    }

    /// Release exactly one parked hop.
    func letOneThrough() { gate.signal() }

    /// Release everything, so a parked parser thread is not leaked into the
    /// next test.
    func release(_ count: Int) { for _ in 0..<count { gate.signal() } }

    var arrivalCount: Int { lock.withLock { arrivals } }
}

/// A resize is a reflow, so it is a barrier: where it sits relative to the
/// byte stream decides what the screen says. These gate that it travels
/// through the parser's own FIFO rather than racing it from Main.
///
/// Every suite name here carries "Checkpoint" so `swift-test.sh --filter
/// Checkpoint` actually gates it.
final class TerminalCheckpointResizeOrderingTests: XCTestCase {
    private func makeCoordinator(
        core: TakoCore,
        main: ResizeMainQueue,
        recorder: ResizeRecorder
    ) -> TerminalParserCoordinator {
        let coordinator = TerminalParserCoordinator(core: core, mainDispatch: main.dispatch)
        coordinator.setMainApplicationHandler(recorder.record)
        coordinator.setCheckpointRestoreHandler(recorder.recordRestore)
        coordinator.setResizeHandler(recorder.recordResize)
        return coordinator
    }

    /// An OSC title is a cheap, exactly-ordered marker: one event per write,
    /// carrying the text that says where in the stream it came from.
    private func title(_ text: String) -> Data { Data("\u{1B}]0;\(text)\u{07}".utf8) }

    private func drainFully(_ coordinator: TerminalParserCoordinator, _ main: ResizeMainQueue) {
        for _ in 0..<16 {
            coordinator.waitForParserQuiescence()
            if main.drain() == 0 { break }
        }
    }

    /// The barrier keeps its place: bytes accepted before the resize are
    /// applied to Main before the resize is reported, and bytes accepted
    /// after it come after.
    ///
    /// Calling `core.resize` directly from Main -- the behaviour this
    /// replaces -- puts the resize wherever the two threads happen to land,
    /// which on a busy stream is at the front.
    func testResizeIsOrderedAgainstTheParserQueue() {
        let main = ResizeMainQueue()
        let recorder = ResizeRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        coordinator.enqueue(title("before"))
        coordinator.resize(cols: 20, rows: 5)
        coordinator.enqueue(title("after"))
        drainFully(coordinator, main)

        XCTAssertEqual(recorder.events, ["title(before)", "resize(20x5)", "title(after)"])
    }

    /// Every byte queued ahead of the barrier is parsed at the old geometry,
    /// and every byte behind it at the new one -- not merely reported in that
    /// order, but actually reflowed on the side of the resize it belongs to.
    func testBytesAreParsedOnTheSideOfTheResizeTheyWereQueuedOn() {
        let main = ResizeMainQueue()
        let recorder = ResizeRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        // 30 columns of text: one row at 40 wide, two rows at 20 wide.
        let thirty = String(repeating: "x", count: 30)
        coordinator.enqueue(Data(thirty.utf8))
        coordinator.resize(cols: 20, rows: 5)
        coordinator.enqueue(Data("\r\n\(thirty)".utf8))
        drainFully(coordinator, main)

        XCTAssertEqual(Int(core.cols()), 20)
        XCTAssertEqual(Int(core.rows()), 5)

        // The pre-resize run was reflowed by the resize; the post-resize run
        // was printed into a 20-wide grid and wrapped by the parser. Either
        // way no row may exceed the grid, and every printed cell survives.
        var printed = 0
        for row in 0..<core.rows() {
            let line = core.getLine(row: row)
            XCTAssertLessThanOrEqual(line.count, 20, "row \(row) wider than the grid: \(line)")
            printed += line.filter { $0 == "x" }.count
        }
        XCTAssertEqual(printed, 60, "both runs must survive the resize")
    }

    /// The handler fires once per resize, after the engine holds that
    /// geometry, and the numbers it carries agree with the engine's own.
    ///
    /// It does not prove the report was *read back* rather than echoed: the
    /// engine adopts every positive request (`Terminal::resize` refuses only a
    /// zero dimension, which `resize(cols:rows:)` rejects before queueing), so
    /// the two are indistinguishable from outside. What is pinned here is that
    /// the host and the engine agree, and that the report arrives exactly once
    /// and only after the barrier has run.
    func testResizeReportsTheEngineHoldsTheNewGeometryWhenTheHostIsTold() {
        let main = ResizeMainQueue()
        let recorder = ResizeRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        coordinator.resize(cols: 132, rows: 43)
        drainFully(coordinator, main)

        XCTAssertEqual(recorder.appliedGeometries.count, 1)
        XCTAssertEqual(recorder.appliedGeometries.first?.cols, Int(core.cols()))
        XCTAssertEqual(recorder.appliedGeometries.first?.rows, Int(core.rows()))
        XCTAssertEqual(Int(core.cols()), 132)
        XCTAssertEqual(Int(core.rows()), 43)
        XCTAssertEqual(coordinator.appliedResizeCount, 1)
    }

    /// A resize reshapes the engine; it does not replace it. So unlike an
    /// import it must not move the epoch, and the outcomes queued ahead of it
    /// must still be applied rather than dropped as stale.
    func testResizeDoesNotSuppressOutcomesQueuedBeforeIt() {
        let main = ResizeMainQueue()
        let recorder = ResizeRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        for index in 0..<8 { coordinator.enqueue(title("t\(index)")) }
        coordinator.resize(cols: 24, rows: 6)
        drainFully(coordinator, main)

        XCTAssertEqual(coordinator.suppressedOutcomeCount, 0)
        XCTAssertEqual(
            recorder.events.filter { $0.hasPrefix("title(") },
            (0..<8).map { "title(t\($0))" }
        )
    }

    /// Both barriers share one queue, so they are ordered against each other
    /// as well as against the bytes.
    func testResizeAndCheckpointImportShareTheOneOrder() throws {
        let main = ResizeMainQueue()
        let recorder = ResizeRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        let source = TakoCore(cols: 30, rows: 8)
        source.feed(bytes: Data("RESTORED".utf8))
        let blob = source.checkpoint()

        coordinator.enqueue(title("first"))
        coordinator.resize(cols: 20, rows: 5)
        let restore = try coordinator.importCheckpoint(blob)
        coordinator.resize(cols: 50, rows: 12)
        drainFully(coordinator, main)

        XCTAssertEqual(restore.cols, 30)
        XCTAssertEqual(restore.rows, 8)
        XCTAssertEqual(
            recorder.events,
            ["title(first)", "resize(20x5)", "restore(30x8)", "resize(50x12)"]
        )
        XCTAssertEqual(Int(core.cols()), 50)
        XCTAssertEqual(Int(core.rows()), 12)
    }

    /// A degenerate grid is refused outright rather than handed to the engine.
    func testResizeRejectsNonPositiveGeometry() {
        let main = ResizeMainQueue()
        let recorder = ResizeRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        coordinator.resize(cols: 0, rows: 10)
        coordinator.resize(cols: 40, rows: 0)
        coordinator.resize(cols: -3, rows: -3)
        drainFully(coordinator, main)

        XCTAssertEqual(coordinator.appliedResizeCount, 0)
        XCTAssertTrue(recorder.appliedGeometries.isEmpty)
        XCTAssertEqual(Int(core.cols()), 40)
        XCTAssertEqual(Int(core.rows()), 10)
    }

    /// After shutdown the barrier is dropped, and -- the point of the test --
    /// the caller is not left parked on a queue that will never run it.
    func testResizeAfterShutDownReturnsWithoutApplying() {
        let main = ResizeMainQueue()
        let recorder = ResizeRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        coordinator.shutDown()
        coordinator.resize(cols: 20, rows: 5)
        drainFully(coordinator, main)

        XCTAssertEqual(coordinator.appliedResizeCount, 0)
        XCTAssertEqual(Int(core.cols()), 40)
        XCTAssertEqual(Int(core.rows()), 10)
    }

    /// Spin until `condition` holds. Every condition used below is one the
    /// coordinator reaches on its own; the deadline only keeps a broken build
    /// from hanging the suite.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            usleep(200)
        }
        XCTFail("timed out waiting for \(description)")
    }

    /// A resize completes at its own barrier, not when the stream goes quiet.
    ///
    /// The barrier is the point at which the engine holds the new geometry.
    /// Everything after it in the FIFO belongs to the new grid and is no part
    /// of the caller's question, so a host that resizes must not be parked
    /// until the parser has chased down input that arrived *after* its
    /// resize -- on a sustained stream that is indefinitely.
    ///
    /// Nothing here depends on how fast anything runs: the parser is held at
    /// a gate this test opens by hand, and the assertion is that the resize
    /// returned while the gate is still shut and later bytes are still
    /// unparsed.
    func testResizeCompletesAtItsBarrierWhileLaterInputIsStillOutstanding() {
        let main = GatedMainQueue()
        let recorder = ResizeRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = TerminalParserCoordinator(core: core, mainDispatch: main.dispatch)
        coordinator.setMainApplicationHandler(recorder.record)
        coordinator.setCheckpointRestoreHandler(recorder.recordRestore)
        coordinator.setResizeHandler(recorder.recordResize)

        // One batch, then the parser hops to Main and parks there -- holding
        // the parser queue, which is the point.
        coordinator.enqueue(title("before"))
        waitUntil("the parser to reach the gate") { main.arrivalCount >= 1 }
        XCTAssertEqual(coordinator.pendingWorkCount, 0, "the first batch should be taken")

        let returned = expectation(description: "resize returned")
        DispatchQueue.global().async {
            coordinator.resize(cols: 20, rows: 5)
            returned.fulfill()
        }
        waitUntil("the resize to take its place in the queue") {
            coordinator.pendingWorkCount >= 1
        }

        // Input that arrives after the barrier. It belongs to the new
        // geometry and the resize has no business waiting for it.
        coordinator.enqueue(title("after"))
        waitUntil("the later bytes to be queued behind the barrier") {
            coordinator.pendingWorkCount >= 2
        }

        // Let the parser past the first hop only. It now reaches the resize
        // barrier -- and parks again at the next hop, with the later bytes
        // still sitting in the queue.
        main.letOneThrough()

        wait(for: [returned], timeout: 5)

        XCTAssertEqual(coordinator.appliedResizeCount, 1, "the barrier ran exactly once")
        XCTAssertEqual(recorder.appliedGeometries.count, 1, "and was reported exactly once")
        XCTAssertEqual(recorder.appliedGeometries.first?.cols, 20)
        XCTAssertEqual(recorder.appliedGeometries.first?.rows, 5)
        XCTAssertGreaterThan(
            coordinator.pendingWorkCount, 0,
            "the resize waited for input that arrived after it"
        )
        XCTAssertEqual(Int(core.cols()), 20, "the engine holds the new geometry")
        XCTAssertEqual(Int(core.rows()), 5)

        coordinator.shutDown()
        main.release(8)
    }

    /// A barrier's *publication* must be bounded too, not just its wait.
    ///
    /// Completing at the barrier fixed when the caller stops waiting. It did
    /// not bound what the caller does next: the apply loop takes whatever is
    /// in the queue, and a producer that keeps supplying outcomes while Main
    /// is applying earlier ones keeps that loop fed. The caller's own resize
    /// was published in the first pass and it is still on Main.
    ///
    /// This is the shape that does it, and it is not a timing race: the
    /// producer lives *inside* the application handlers, so every new outcome
    /// is already parsed and queued before the handler that produced it
    /// returns. The loop can never observe an empty queue.
    ///
    /// The bound is the caller's own barrier. Everything the producer supplies
    /// after it still has to be applied -- in order, exactly once -- just not
    /// on the resizing caller's clock.
    func testResizeReturnsWithoutApplyingOutcomesProducedAfterItsBarrier() {
        let main = ResizeMainQueue()
        let recorder = ResizeRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = TerminalParserCoordinator(core: core, mainDispatch: main.dispatch)

        // A producer that injects the next write from inside whatever handler
        // is running, and does not return until the parser has turned it into
        // an outcome waiting on the queue.
        let injections = Injector(coordinator: coordinator, limit: 10)

        coordinator.setMainApplicationHandler { outcomes in
            recorder.record(outcomes)
            injections.recordApplication(count: outcomes.count)
            injections.injectNext()
        }
        coordinator.setResizeHandler { cols, rows in
            recorder.recordResize(cols: cols, rows: rows)
            injections.barrierPublished()
            injections.injectNext()
        }

        coordinator.enqueue(title("before"))
        coordinator.resize(cols: 20, rows: 5)

        // The claim: the resize returned having published its own barrier and
        // nothing the producer supplied afterwards.
        XCTAssertEqual(
            injections.applicationsAfterBarrier, 0,
            "the resize applied \(injections.applicationsAfterBarrier) outcomes produced " +
            "after its own barrier before returning -- its publication is unbounded"
        )
        XCTAssertEqual(coordinator.appliedResizeCount, 1)
        XCTAssertEqual(recorder.appliedGeometries.count, 1, "and published it exactly once")

        // Nothing was dropped to achieve that: the producer's writes are still
        // owed, and draining Main delivers every one of them, in order and
        // exactly once, after the barrier.
        drainFully(coordinator, main)
        XCTAssertEqual(
            recorder.events,
            ["title(before)", "resize(20x5)"] + (1...10).map { "title(after\($0))" }
        )
        XCTAssertEqual(coordinator.suppressedOutcomeCount, 0)

        coordinator.shutDown()
    }

    /// Import publishes through the same loop and needs the same bound. Same
    /// producer, same claim.
    func testImportReturnsWithoutApplyingOutcomesProducedAfterItsBarrier() throws {
        let main = ResizeMainQueue()
        let recorder = ResizeRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = TerminalParserCoordinator(core: core, mainDispatch: main.dispatch)

        let source = TakoCore(cols: 30, rows: 8)
        source.feed(bytes: Data("RESTORED".utf8))
        let blob = source.checkpoint()

        let injections = Injector(coordinator: coordinator, limit: 10)

        coordinator.setMainApplicationHandler { outcomes in
            recorder.record(outcomes)
            injections.recordApplication(count: outcomes.count)
            injections.injectNext()
        }
        coordinator.setCheckpointRestoreHandler { restore in
            recorder.recordRestore(restore)
            injections.barrierPublished()
            injections.injectNext()
        }

        let restore = try coordinator.importCheckpoint(blob)
        XCTAssertEqual(restore.cols, 30)

        XCTAssertEqual(
            injections.applicationsAfterBarrier, 0,
            "the import applied \(injections.applicationsAfterBarrier) outcomes produced " +
            "after its own barrier before returning -- its publication is unbounded"
        )

        drainFully(coordinator, main)
        XCTAssertEqual(
            recorder.events,
            ["restore(30x8)"] + (1...10).map { "title(after\($0))" }
        )

        coordinator.shutDown()
    }

    /// A refused import is a barrier too, and it has to be published.
    ///
    /// The successful path marks the request published the instant its
    /// restore reaches the host, which is what stops the importing caller
    /// from carrying somebody else's work. A refused import has nothing to
    /// hand the host -- the engine is exactly what it was -- and so nothing
    /// marked it, leaving the caller waiting on a barrier that could never
    /// arrive. It then drains whatever the parser keeps producing, on Main,
    /// for as long as the producer keeps producing.
    ///
    /// The bound has to come from the queue, not from the publication: the
    /// rejection takes its place in the same FIFO and is published there,
    /// delivering nothing.
    func testRefusedImportReturnsWithoutApplyingOutcomesProducedAfterItsBarrier() {
        let main = ResizeMainQueue()
        let recorder = ResizeRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = TerminalParserCoordinator(core: core, mainDispatch: main.dispatch)
        coordinator.setCheckpointRestoreHandler(recorder.recordRestore)
        coordinator.setResizeHandler(recorder.recordResize)

        let injections = Injector(coordinator: coordinator, limit: 10)
        coordinator.setMainApplicationHandler { outcomes in
            recorder.record(outcomes)
            injections.recordApplication(count: outcomes.count)
            injections.injectNext()
            // Nothing publishes a rejection to the host, so the barrier is
            // marked here instead: the injection above is queued behind the
            // refused import, so everything applied from now on is work the
            // caller produced after its own barrier.
            injections.barrierPublished()
        }

        // One outcome waiting ahead of the barrier, so the handler runs once
        // and the producer starts. Its application stays queued: this Main
        // runs nothing until the test drains it.
        coordinator.enqueue(title("seed"))
        coordinator.waitForParserQuiescence()

        XCTAssertThrowsError(try coordinator.importCheckpoint(Data([1, 2, 3]))) { error in
            XCTAssertFalse(
                error is TerminalCheckpointImportError,
                "the engine's own refusal should surface, not a coordinator error: \(error)"
            )
        }

        XCTAssertEqual(
            injections.applicationsAfterBarrier, 0,
            "the refused import applied \(injections.applicationsAfterBarrier) outcomes " +
            "produced after its own barrier before returning -- its barrier is never published"
        )

        // Nothing was restored and nothing was resized: a refusal publishes
        // no state change, only its own place in the order.
        XCTAssertEqual(coordinator.checkpointImportCount, 0)
        XCTAssertEqual(coordinator.checkpointImportFailureCount, 1)
        XCTAssertEqual(coordinator.suppressedOutcomeCount, 0)

        drainFully(coordinator, main)
        XCTAssertEqual(
            recorder.events,
            ["title(seed)"] + (1...10).map { "title(after\($0))" },
            "every outcome must still be delivered exactly once, in order"
        )
        XCTAssertEqual(coordinator.peakOutstandingMainApplications, 1)

        coordinator.shutDown()
    }
}

/// Supplies the next write from inside whichever handler is running, and
/// blocks until the parser has produced its outcome -- so the apply loop is
/// never looking at an empty queue when it decides whether to keep going.
///
/// Bounded on purpose: an unbounded producer would hang a build with the
/// defect instead of failing it.
private final class Injector: @unchecked Sendable {
    private let coordinator: TerminalParserCoordinator
    private let limit: Int
    private let lock = NSLock()
    private var issued = 0
    private var published = false
    private var appliedAfterBarrier = 0

    init(coordinator: TerminalParserCoordinator, limit: Int) {
        self.coordinator = coordinator
        self.limit = limit
    }

    func barrierPublished() { lock.withLock { published = true } }

    func recordApplication(count: Int) {
        lock.lock()
        if published { appliedAfterBarrier += count }
        lock.unlock()
    }

    func injectNext() {
        lock.lock()
        guard issued < limit else { lock.unlock(); return }
        issued += 1
        let index = issued
        lock.unlock()
        coordinator.enqueue(Data("\u{1B}]0;after\(index)\u{07}".utf8))
        // Parser-only: this never waits on Main, so it cannot deadlock the
        // handler it is called from. When it returns the outcome is queued.
        coordinator.waitForParserQuiescence()
    }

    var applicationsAfterBarrier: Int { lock.withLock { appliedAfterBarrier } }
}
