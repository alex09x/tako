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
@testable import TakoCoreUI

/// A stand-in for the main queue: an application lands here instead of being
/// dispatched, so a test decides exactly when it runs.
final class ResizeMainQueue: @unchecked Sendable {
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
final class ResizeRecorder: @unchecked Sendable {
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
final class GatedMainQueue: @unchecked Sendable {
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

}
