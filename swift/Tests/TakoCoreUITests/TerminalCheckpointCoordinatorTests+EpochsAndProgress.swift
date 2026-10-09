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

extension TerminalCheckpointOrderingTests {
    func testShutDownDuringACheckpointImportDoesNotHang() throws {
        let main = CheckpointMainQueue()
        let recorder = CheckpointRecorder()
        let core = TakoCore(cols: 40, rows: 10)

        let parserParked = DispatchSemaphore(value: 0)
        let releaseParser = DispatchSemaphore(value: 0)
        let parkOnce = NSLock()
        var parked = false
        let coordinator = TerminalParserCoordinator(core: core) { block in
            parkOnce.lock()
            let shouldPark = !parked
            parked = true
            parkOnce.unlock()
            if shouldPark {
                // Runs on the parser queue, from inside the parse pass: the
                // pass cannot dequeue anything else until this returns.
                parserParked.signal()
                releaseParser.wait()
            }
            main.dispatch(block)
        }
        coordinator.setMainApplicationHandler(recorder.record)
        coordinator.setCheckpointRestoreHandler(recorder.recordRestore)

        coordinator.enqueue(Data("park the parser\r\n".utf8))
        XCTAssertEqual(parserParked.wait(timeout: .now() + 30), .success)

        let blob = checkpoint(of: "NEVER-APPLIED")
        let returned = expectation(description: "the import returned")
        let thrownLock = NSLock()
        var thrown: Error?
        DispatchQueue(label: "test.importer").async {
            do {
                _ = try coordinator.importCheckpoint(blob)
            } catch {
                thrownLock.lock()
                thrown = error
                thrownLock.unlock()
            }
            returned.fulfill()
        }

        // The barrier is queued behind a parser that cannot reach it.
        let deadline = Date().addingTimeInterval(30)
        while coordinator.pendingWorkCount == 0, Date() < deadline {
            usleep(1000)
        }
        XCTAssertEqual(coordinator.pendingWorkCount, 1, "the barrier is waiting in the queue")

        coordinator.shutDown()
        waitForExpectations(timeout: 30)
        releaseParser.signal()

        thrownLock.lock()
        let error = thrown
        thrownLock.unlock()
        XCTAssertEqual(
            error as? TerminalCheckpointImportError,
            .shutDown,
            "a barrier abandoned by shutdown fails as shutdown rather than hanging"
        )
        XCTAssertEqual(coordinator.checkpointImportCount, 0, "and never replaced the engine")

        // The engine outlives the coordinator: shutdown stops work reaching
        // the host, not the core.
        coordinator.waitForParserQuiescence()
        core.feed(bytes: Data("still alive".utf8))
        XCTAssertTrue(core.bufferText().contains("still alive"))

        // And an import attempted after shutdown fails immediately.
        XCTAssertThrowsError(try coordinator.importCheckpoint(blob)) { error in
            XCTAssertEqual(error as? TerminalCheckpointImportError, .shutDown)
        }
    }

    /// An outcome parsed before the swap is dropped rather than applied to the
    /// engine that replaced it.
    func testStaleOutcomesAreSuppressedByTheCheckpointEpoch() throws {
        let main = CheckpointMainQueue()
        let recorder = CheckpointRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        // Parsed, and deliberately NOT applied: the application is sitting on
        // the stand-in main queue.
        coordinator.enqueue(Data("\u{001B}]0;stale-title\u{0007}".utf8))
        coordinator.waitForParserQuiescence()
        XCTAssertEqual(recorder.outcomes.count, 0, "nothing applied yet")

        let restore = try coordinator.importCheckpoint(checkpoint(of: "FRESH"))
        drainFully(coordinator, main)

        XCTAssertEqual(coordinator.suppressedOutcomeCount, 1, "the pre-swap outcome was dropped")
        XCTAssertEqual(recorder.titles, [], "and never reached the host")
        XCTAssertEqual(recorder.restoreCount, 1)
        XCTAssertEqual(restore.epoch, core.stateEpoch())

        // A post-swap outcome under the current epoch is applied normally.
        coordinator.enqueue(Data("\u{001B}]0;live-title\u{0007}".utf8))
        drainFully(coordinator, main)
        XCTAssertEqual(recorder.titles, ["live-title"])
    }

    /// The epoch is validated where the outcome is *applied*, not only where
    /// it is published: an engine replaced between capture and application --
    /// here by `reset`, which swaps the engine on Main outside the coordinator
    /// entirely -- still invalidates it.
    func testStaleOutcomeIsSuppressedAtApplicationTime() {
        let main = CheckpointMainQueue()
        let recorder = CheckpointRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        coordinator.enqueue(Data("\u{001B}]0;doomed\u{0007}".utf8))
        coordinator.waitForParserQuiescence()

        // The engine is replaced on Main, behind the coordinator's back --
        // exactly the shape a coordinator-level epoch could not see.
        core.reset()

        main.drain()
        XCTAssertEqual(recorder.titles, [], "an outcome from the old engine is not applied")
        XCTAssertEqual(coordinator.suppressedOutcomeCount, 1)
        XCTAssertEqual(coordinator.appliedOutcomeCount, 0)
    }

    /// Interleaved feeds and imports all complete, with bounded work
    /// outstanding throughout: no batch dropped, none applied twice, at most
    /// one main application in flight.
    func testBoundedProgressUnderInterleavedFeedsAndImports() throws {
        let main = CheckpointMainQueue()
        let recorder = CheckpointRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        for round in 0..<12 {
            for chunk in 0..<8 {
                coordinator.enqueue(Data("round \(round) chunk \(chunk)\r\n".utf8))
            }
            _ = try coordinator.importCheckpoint(checkpoint(of: "ROUND-\(round)"))
            coordinator.enqueue(Data("\u{001B}]0;after-\(round)\u{0007}".utf8))
            drainFully(coordinator, main)
        }

        XCTAssertEqual(coordinator.checkpointImportCount, 12)
        XCTAssertEqual(recorder.restoreCount, 12)
        XCTAssertEqual(coordinator.pendingWorkCount, 0)
        XCTAssertEqual(
            coordinator.appliedOutcomeCount + coordinator.suppressedOutcomeCount,
            coordinator.batchCount,
            "every parsed batch was either applied or explicitly suppressed"
        )
        XCTAssertEqual(coordinator.peakOutstandingMainApplications, 1)
        XCTAssertLessThanOrEqual(main.peakDepth, 1)
        XCTAssertEqual(recorder.titles, (0..<12).map { "after-\($0)" })
        XCTAssertTrue(core.getPlainText(startRow: 0, maxRows: 10).contains("ROUND-11"))
    }

    /// A restore is not a reset. `reset()` feeds `ESC c` -- a byte stream the
    /// terminal interprets; an import hands the engine a whole state. The
    /// import parses no bytes at all, and the restored content survives, which
    /// an `ESC c` would have cleared.
    func testCheckpointRestoreIsNotExpressedAsAReset() throws {
        let main = CheckpointMainQueue()
        let recorder = CheckpointRecorder()
        let core = TakoCore(cols: 40, rows: 10)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        coordinator.feedSynchronously(Data("SCRATCH".utf8))
        let batchesBefore = coordinator.batchCount

        let restore = try coordinator.importCheckpoint(checkpoint(of: "KEEP-ME\u{001B}]0;kept\u{0007}"))
        drainFully(coordinator, main)

        XCTAssertEqual(coordinator.batchCount, batchesBefore, "no bytes were fed to express the import")
        XCTAssertTrue(core.getPlainText(startRow: 0, maxRows: 10).contains("KEEP-ME"))
        XCTAssertEqual(core.title(), "kept", "restored state, not a cleared terminal")
        XCTAssertEqual(restore.cols, 40)
    }

    /// The engine adopts the checkpoint's own geometry, and the coordinator
    /// reports it rather than turning it into a resize request.
    func testCheckpointRestoreReportsGeometryWithoutReflowing() throws {
        let main = CheckpointMainQueue()
        let recorder = CheckpointRecorder()
        let core = TakoCore(cols: 80, rows: 24)
        let coordinator = makeCoordinator(core: core, main: main, recorder: recorder)

        let blob = checkpoint(of: "NARROW", cols: 33, rows: 7)
        let restore = try coordinator.importCheckpoint(blob)
        drainFully(coordinator, main)

        XCTAssertEqual(restore.cols, 33)
        XCTAssertEqual(restore.rows, 7)
        XCTAssertEqual(core.cols(), 33, "the canonical grid is not reflowed to the view's size")
        XCTAssertEqual(core.rows(), 7)
        XCTAssertEqual(recorder.restores.map { [$0.cols, $0.rows] }, [[33, 7]])
    }
}
