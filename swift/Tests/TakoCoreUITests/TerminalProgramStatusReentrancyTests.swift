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
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

final class TerminalProgramStatusReentrancyTests: XCTestCase {
    private func b64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    func testReentrantFeedSynchronouslyDefersDeliveryBehindAlreadyParsedBatch() {
        // 1. Single-chunk R1 + R2 where R1 callback synchronously feeds R3.
        let session = TerminalHeadlessSession()
        var singleChunkRevisions: [UInt64] = []
        var singleChunkSnapshotRevisions: [UInt64] = []

        let r1 = "\u{1b}]7501;state=working:id=main:msg=\(b64("Step 1"))\u{1b}\\"
        let r2 = "\u{1b}]7501;state=working:id=main:progress=50:msg=\(b64("Step 2"))\u{1b}\\"
        let r3 = Data("\u{1b}]7501;state=done:id=main:msg=\(b64("Step 3"))\u{1b}\\".utf8)

        session.onProgramStatusEvent = { [weak session] event in
            guard case .updated(let update, let snapshot) = event else { return }
            singleChunkRevisions.append(update.revision)
            singleChunkSnapshotRevisions.append(snapshot.revision)
            if update.revision == 1 {
                session?.feedSynchronously(r3)
            }
        }
        session.feedSynchronously(Data((r1 + r2).utf8))

        XCTAssertEqual(singleChunkRevisions, [1, 2, 3], "Reentrant R3 must not overtake already-parsed R2 in the same outcome")
        XCTAssertEqual(singleChunkSnapshotRevisions, [1, 2, 3])

        // 2. Two separately queued chunks [O(R1), O(R2)] in the same extracted run.
        var queuedDeliveries: [() -> Void] = []
        let multiChunkSession = TerminalHeadlessSession(deliveryDispatch: { work in
            queuedDeliveries.append(work)
        })
        var multiChunkRevisions: [UInt64] = []

        multiChunkSession.onProgramStatusEvent = { [weak multiChunkSession] event in
            guard case .updated(let update, let snapshot) = event else { return }
            XCTAssertEqual(update.revision, snapshot.revision)
            multiChunkRevisions.append(update.revision)
            if update.revision == 1 {
                multiChunkSession?.feedSynchronously(r3)
            }
        }

        multiChunkSession.enqueue(Data(r1.utf8))
        multiChunkSession.parserCoordinator.waitForParserQuiescence()
        multiChunkSession.enqueue(Data(r2.utf8))
        multiChunkSession.parserCoordinator.waitForParserQuiescence()

        while !queuedDeliveries.isEmpty {
            let next = queuedDeliveries.removeFirst()
            next()
        }

        XCTAssertEqual(multiChunkRevisions, [1, 2, 3], "Reentrant R3 must not overtake already-parsed R2 across separate outcomes")
    }

    func testReentrantCheckpointImportSuppressesRemainingRetiredEpochEventsAndOrdersPostImportFeed() throws {
        let donor = TerminalHeadlessSession()
        donor.feedSynchronously(
            Data("\u{1b}]7501;state=blocked:kind=question:id=restored:msg=\(b64("Restored checkpoint"))\u{1b}\\".utf8)
        )
        let checkpointBlob = try donor.exportCheckpoint()

        var queuedDeliveries: [() -> Void] = []
        let session = TerminalHeadlessSession(deliveryDispatch: { work in
            queuedDeliveries.append(work)
        })

        let oldR1 = "\u{1b}]7501;state=working:id=old:msg=\(b64("Old-R1"))\u{1b}\\"
        let oldR2 = "\u{1b}]7501;state=working:id=old:progress=40:msg=\(b64("Old-R2"))\u{1b}\\"
        let oldR3SeparateChunk = "\u{1b}]7501;state=done:id=old:msg=\(b64("Old-R3"))\u{1b}\\"
        // Update `id=restored` in the new epoch so `effective?.msg` becomes `"New-PostImport"` at revision 2.
        let postImportNew = Data("\u{1b}]7501;state=working:id=restored:msg=\(b64("New-PostImport"))\u{1b}\\".utf8)

        var trace: [String] = []
        session.onProgramStatusEvent = { [weak session] event in
            switch event {
            case .updated(let update, let snapshot):
                XCTAssertEqual(update.revision, snapshot.revision)
                let msg = update.effective?.msg ?? "nil"
                trace.append("updated:\(msg):\(update.revision)")
                if msg == "Old-R1", let session {
                    _ = try? session.importCheckpoint(checkpointBlob)
                    session.feedSynchronously(postImportNew)
                }
            case .restored(let snapshot):
                let msg = snapshot.effective?.msg ?? "nil"
                trace.append("restored:\(msg):\(snapshot.revision)")
            case .overflowCoalesced(let fromRev, _):
                trace.append("overflow:\(fromRev)")
            }
        }

        // Queue Old-R1 + Old-R2 in one outcome AND Old-R3 in a second outcome of epoch 0.
        session.enqueue(Data((oldR1 + oldR2).utf8))
        session.parserCoordinator.waitForParserQuiescence()
        session.enqueue(Data(oldR3SeparateChunk.utf8))
        session.parserCoordinator.waitForParserQuiescence()

        while !queuedDeliveries.isEmpty {
            let next = queuedDeliveries.removeFirst()
            next()
        }

        XCTAssertEqual(
            trace,
            [
                "updated:Old-R1:1",
                "restored:Restored checkpoint:1",
                "updated:New-PostImport:2"
            ],
            "Remaining retired-epoch events (Old-R2 in same outcome and Old-R3 in same extracted run) must be suppressed after reentrant importCheckpoint"
        )
        XCTAssertEqual(session.parserCoordinator.suppressedOutcomeCount, 1)
        XCTAssertEqual(
            session.parserCoordinator.appliedOutcomeCount + session.parserCoordinator.suppressedOutcomeCount,
            session.parserCoordinator.batchCount
        )
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    @MainActor
    func testNSViewReentrantFeedAndCheckpointImportPreserveOrderAndSuppressRetiredEpoch() throws {
        let donor = TerminalHeadlessSession()
        donor.feedSynchronously(
            Data("\u{1b}]7501;state=blocked:kind=permission:id=restored:msg=\(b64("NSView-Restored"))\u{1b}\\".utf8)
        )
        let checkpointBlob = try donor.exportCheckpoint()

        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate

        let r1 = "\u{1b}]7501;state=working:id=main:msg=\(b64("NS-1"))\u{1b}\\"
        let r2 = "\u{1b}]7501;state=working:id=main:progress=60:msg=\(b64("NS-2"))\u{1b}\\"
        let r3 = Data("\u{1b}]7501;state=done:id=main:msg=\(b64("NS-3"))\u{1b}\\".utf8)
        let postImport = Data("\u{1b}]7501;state=working:id=restored:msg=\(b64("NS-PostImport"))\u{1b}\\".utf8)

        var orderRevs: [UInt64] = []
        delegate.onProgramStatusEvent = { targetView, event in
            if case .updated(let update, let snapshot) = event {
                XCTAssertEqual(update.revision, snapshot.revision)
                orderRevs.append(update.revision)
                if update.revision == 1 {
                    targetView.feed(data: r3)
                }
            }
        }
        view.feed(data: Data((r1 + r2).utf8))
        XCTAssertEqual(orderRevs, [1, 2, 3])

        let view2 = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let delegate2 = MockTerminalNSViewDelegate()
        view2.delegate = delegate2
        var importTrace: [String] = []
        delegate2.onProgramStatusEvent = { targetView, event in
            switch event {
            case .updated(let update, _):
                let msg = update.effective?.msg ?? "nil"
                importTrace.append("updated:\(msg):\(update.revision)")
                if msg == "NS-1" {
                    _ = try? targetView.importCheckpoint(checkpointBlob)
                    targetView.feed(data: postImport)
                }
            case .restored(let snapshot):
                importTrace.append("restored:\(snapshot.effective?.msg ?? "nil"):\(snapshot.revision)")
            case .overflowCoalesced(let fromRev, _):
                importTrace.append("overflow:\(fromRev)")
            }
        }
        view2.feed(data: Data((r1 + r2).utf8))
        XCTAssertEqual(
            importTrace,
            [
                "updated:NS-1:1",
                "restored:NSView-Restored:1",
                "updated:NS-PostImport:2"
            ]
        )
    }
    #endif
}
