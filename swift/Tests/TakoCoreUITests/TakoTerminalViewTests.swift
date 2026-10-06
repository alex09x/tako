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


}
