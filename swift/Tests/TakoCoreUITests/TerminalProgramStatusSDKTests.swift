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

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

final class TerminalProgramStatusSDKTests: XCTestCase {
    private static let expectedCapabilityReply =
        "\u{1b}]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\u{1b}\\"

    private func b64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    func testHeadlessSessionCapabilityAndDA1PreserveFIFOAndSinglePathExclusivity() {
        let session = TerminalHeadlessSession(cols: 80, rows: 24, deliveryDispatch: { $0() })
        defer { session.shutDown() }
        var classifiedBatches: [TerminalClassifiedReplyBatch] = []
        var legacyBytes = Data()
        session.onClassifiedReplies = { classifiedBatches.append($0) }
        session.onDeviceReplyData = { legacyBytes.append($0) }
        let stream = Data("\u{1b}]7501;?\u{1b}\\\u{1b}[c".utf8)
        session.feedSynchronously(stream)
        XCTAssertEqual(classifiedBatches.count, 1)
        XCTAssertTrue(legacyBytes.isEmpty, "onDeviceReplyData must never fire when onClassifiedReplies is installed")
        let batch = classifiedBatches[0]
        XCTAssertFalse(batch.hasOverflowLoss)
        XCTAssertEqual(batch.replies.map(\.replyClass), [.programStatusCapability, .standardDevice])
        XCTAssertLessThan(batch.replies[0].seq, batch.replies[1].seq)
        XCTAssertEqual(String(decoding: batch.replies[0].bytes, as: UTF8.self), Self.expectedCapabilityReply)
        XCTAssertTrue(String(decoding: batch.replies[1].bytes, as: UTF8.self).hasPrefix("\u{1b}[?"))

        // Clearing onClassifiedReplies falls back cleanly to onDeviceReplyData.
        session.onClassifiedReplies = nil
        session.feedSynchronously(Data("\u{1b}]7501;?\u{07}".utf8))
        XCTAssertEqual(String(decoding: legacyBytes, as: UTF8.self), Self.expectedCapabilityReply)
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    @MainActor
    func testNSViewSinglePathReplyExclusivityWhenBothHandlersSet() {
        TakoTerminalNSView.isMetalDisabledForTesting = true
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        var classifiedBatches: [TerminalClassifiedReplyBatch] = []
        view.onClassifiedReplies = { classifiedBatches.append($0) }
        view.feed(data: Data("\u{1b}]7501;?\u{1b}\\\u{1b}[c".utf8))
        XCTAssertEqual(classifiedBatches.count, 1)
        XCTAssertEqual(classifiedBatches[0].replies.count, 2)
        XCTAssertTrue(
            delegate.deviceReplyDataReceived.isEmpty,
            "sendDeviceReplyData must not receive duplicate replies while view.onClassifiedReplies is installed"
        )

        // Removing view.onClassifiedReplies restores delegate fallback and overflow reporting.
        view.onClassifiedReplies = nil
        let spy = MockTerminalNSViewDelegate()
        view.delegate = spy
        let flood = String(repeating: "\u{1b}[c", count: 300)
        view.feed(data: Data(flood.utf8))
        XCTAssertEqual(spy.replyOverflowCounts, [44])
        XCTAssertFalse(spy.deviceReplyDataReceived.isEmpty)
    }
    #endif

    func testPassiveClientProbeSuppressionPreservesDA1StatusAndCheckpointImport() throws {
        let passive = TerminalHeadlessSession(
            cols: 80,
            rows: 24,
            probeReplyEnabled: false,
            deliveryDispatch: { $0() }
        )
        defer { passive.shutDown() }

        var batches: [TerminalClassifiedReplyBatch] = []
        passive.onClassifiedReplies = { batches.append($0) }

        let msg = b64("Indexing workspace")
        passive.feedSynchronously(
            Data("\u{1b}]7501;?\u{1b}\\\u{1b}[c\u{1b}]7501;state=working:app=Codex:msg=\(msg)\u{1b}\\".utf8)
        )

        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].replies.map(\.replyClass), [.standardDevice])
        let snap = passive.programStatusSnapshot()
        XCTAssertTrue(snap.osc7501Active)
        XCTAssertEqual(snap.effective?.state, .working)
        XCTAssertEqual(snap.effective?.resolvedApp, "Codex")
        XCTAssertEqual(snap.effective?.msg, "Indexing workspace")

        // Checkpoint import from an active owner session must NOT flip passive probeReplyEnabled back to true.
        let owner = TerminalHeadlessSession(cols: 80, rows: 24, probeReplyEnabled: true, deliveryDispatch: { $0() })
        defer { owner.shutDown() }
        owner.feedSynchronously(Data("\u{1b}]7501;state=done:app=Claude\u{1b}\\".utf8))
        let blob = try owner.exportCheckpoint()

        _ = try passive.importCheckpoint(blob)
        XCTAssertFalse(passive.programStatusProbeReplyEnabled)

        batches.removeAll()
        passive.feedSynchronously(Data("\u{1b}]7501;?\u{1b}\\".utf8))
        XCTAssertTrue(batches.isEmpty)
        XCTAssertEqual(passive.programStatusSnapshot().effective?.state, .done)
    }

    func testStatusUpdateBurstOver64EmitsOverflowCoalescedResync() {
        let session = TerminalHeadlessSession(cols: 80, rows: 24, deliveryDispatch: { $0() })
        defer { session.shutDown() }

        var events: [TerminalProgramStatusEvent] = []
        session.onProgramStatusEvent = { events.append($0) }

        var payload = ""
        for idx in 0..<80 {
            let pct = idx % 101
            payload += "\u{1b}]7501;state=working:id=main:progress=\(pct)\u{1b}\\"
        }
        payload += "\u{1b}]7501;state=done:id=main:title=\(b64("Complete"))\u{1b}\\"

        session.feedSynchronously(Data(payload.utf8))

        let coalesced = events.compactMap { event -> (UInt64, TerminalProgramStatusSnapshot)? in
            if case .overflowCoalesced(let fromRev, let snap) = event {
                return (fromRev, snap)
            }
            return nil
        }
        XCTAssertEqual(coalesced.count, 1)
        XCTAssertGreaterThan(coalesced[0].0, 0)
        XCTAssertEqual(coalesced[0].1.effective?.state, .done)
        XCTAssertEqual(coalesced[0].1.effective?.title, "Complete")
    }

    func testReplyOverflowSurfacesExplicitLossWhilePreservingFIFOPrefix() {
        let session = TerminalHeadlessSession(cols: 80, rows: 24, deliveryDispatch: { $0() })
        defer { session.shutDown() }

        var outcome: TerminalReplyDeliveryOutcome?
        session.onClassifiedReplies = { outcome = $0.deliveryOutcome }

        let queries = String(repeating: "\u{1b}]7501;?\u{1b}\\", count: 300)
        session.feedSynchronously(Data(queries.utf8))

        guard case .overflowLoss(let preserved, let droppedCount) = outcome else {
            XCTFail("Expected explicit .overflowLoss outcome, got \(String(describing: outcome))")
            return
        }
        XCTAssertEqual(preserved.count, 256)
        XCTAssertEqual(droppedCount, 44)
        for idx in 1..<preserved.count {
            XCTAssertLessThan(preserved[idx - 1].seq, preserved[idx].seq)
        }

        // Legacy fallback also surfaces overflow count before delivering preserved bytes.
        session.onClassifiedReplies = nil
        var legacyOverflow: UInt32 = 0
        var legacyData = Data()
        session.onReplyOverflow = { legacyOverflow = $0 }
        session.onDeviceReplyData = { legacyData = $0 }
        session.feedSynchronously(Data(queries.utf8))
        XCTAssertEqual(legacyOverflow, 44)
        XCTAssertEqual(legacyData.count, 256 * Self.expectedCapabilityReply.utf8.count)
    }

    func testCheckpointRestoreDropsStaleRepliesEmitsNonLiveRestoredAndShutDownSuppressesCallbacks() throws {
        let producer = TerminalHeadlessSession(cols: 80, rows: 24, deliveryDispatch: { $0() })
        defer { producer.shutDown() }
        producer.feedSynchronously(
            Data("\u{1b}]7501;state=error:id=build:app=Antigravity:msg=\(b64("Tests failed"))\u{1b}\\".utf8)
        )
        let checkpoint = try producer.exportCheckpoint()

        let consumer = TerminalHeadlessSession(cols: 80, rows: 24, deliveryDispatch: { $0() })
        var events: [TerminalProgramStatusEvent] = []
        var replies: [TerminalClassifiedReplyBatch] = []
        consumer.onProgramStatusEvent = { events.append($0) }
        consumer.onClassifiedReplies = { replies.append($0) }

        _ = try consumer.importCheckpoint(checkpoint)

        XCTAssertTrue(replies.isEmpty)
        XCTAssertEqual(events.count, 1)
        guard case .restored(let restoredSnap) = events[0] else {
            XCTFail("Expected .restored event after checkpoint import")
            return
        }
        XCTAssertFalse(events[0].isLiveTransition)
        XCTAssertEqual(restoredSnap.effective?.state, .error)
        XCTAssertEqual(restoredSnap.effective?.msg, "Tests failed")

        consumer.shutDown()
        events.removeAll()
        consumer.feedSynchronously(Data("\u{1b}]7501;state=working\u{1b}\\".utf8))
        XCTAssertTrue(events.isEmpty)
    }

    func testDeferredDeliveryPreservesPerUpdateSnapshotsAndSerializesLifecycleTransitions() {
        let queueLock = NSLock()
        var pendingClosures: [() -> Void] = []
        func drainClosures() {
            while true {
                queueLock.lock()
                let next = pendingClosures.isEmpty ? nil : pendingClosures.removeFirst()
                queueLock.unlock()
                guard let next else { break }
                next()
            }
        }

        let session = TerminalHeadlessSession(
            cols: 80,
            rows: 24,
            deliveryDispatch: { work in
                queueLock.lock()
                pendingClosures.append(work)
                queueLock.unlock()
            }
        )
        defer { session.shutDown() }

        var events: [TerminalProgramStatusEvent] = []
        session.onProgramStatusEvent = { events.append($0) }

        // 1. Two async reports parsed before delivery closures drain:
        // update revision 1 must still carry snapshot revision 1 ("Step 1"), not live snapshot revision 2 ("Step 2").
        session.enqueue(
            Data("\u{1b}]7501;state=working:id=main:app=Codex:msg=\(b64("Step 1"))\u{1b}\\".utf8)
        )
        session.parserCoordinator.waitForParserQuiescence()
        session.enqueue(
            Data("\u{1b}]7501;state=done:id=main:app=Codex:msg=\(b64("Step 2"))\u{1b}\\".utf8)
        )
        session.parserCoordinator.waitForParserQuiescence()
        XCTAssertTrue(events.isEmpty, "No events may bypass injected deliveryDispatch before closures drain")

        drainClosures()
        XCTAssertEqual(events.count, 2)
        if events.count == 2,
           case .updated(let u1, let s1) = events[0],
           case .updated(let u2, let s2) = events[1] {
            XCTAssertEqual(u1.revision, 1)
            XCTAssertEqual(s1.revision, 1)
            XCTAssertEqual(s1.effective?.state, .working)
            XCTAssertEqual(s1.effective?.msg, "Step 1")
            XCTAssertEqual(u2.revision, 2)
            XCTAssertEqual(s2.revision, 2)
            XCTAssertEqual(s2.effective?.state, .done)
            XCTAssertEqual(s2.effective?.msg, "Step 2")
        } else {
            XCTFail("Expected two ordered .updated events, got \(events)")
        }

        // 2. Async report parsed, then notifyUserInterrupted() called BEFORE delivery closures drain:
        // must not emit revision 4 ahead of revision 3 or bypass deliveryDispatch.
        events.removeAll()
        session.enqueue(
            Data("\u{1b}]7501;state=working:id=main:app=Codex:msg=\(b64("Step 3"))\u{1b}\\".utf8)
        )
        session.parserCoordinator.waitForParserQuiescence()
        session.notifyUserInterrupted()
        XCTAssertTrue(events.isEmpty, "notifyUserInterrupted must deliver through deliveryDispatch in FIFO order")

        drainClosures()
        XCTAssertEqual(events.count, 2)
        if events.count == 2,
           case .updated(let u3, let s3) = events[0],
           case .updated(let u4, let s4) = events[1] {
            XCTAssertEqual(u3.revision, 3)
            XCTAssertEqual(s3.revision, 3)
            XCTAssertEqual(s3.effective?.state, .working)
            XCTAssertEqual(s3.effective?.msg, "Step 3")
            XCTAssertEqual(u4.revision, 4)
            XCTAssertEqual(s4.revision, 4)
            XCTAssertNil(s4.effective)
        } else {
            XCTFail("Expected ordered [working rev 3, interrupted rev 4], got \(events)")
        }

        // 3. Same serialization guarantee for notifyProcessExited().
        events.removeAll()
        session.enqueue(
            Data("\u{1b}]7501;state=blocked:id=main:kind=permission:app=Codex:msg=\(b64("Approve?"))\u{1b}\\".utf8)
        )
        session.parserCoordinator.waitForParserQuiescence()
        session.notifyProcessExited()
        XCTAssertTrue(events.isEmpty, "notifyProcessExited must deliver through deliveryDispatch in FIFO order")

        drainClosures()
        XCTAssertEqual(events.count, 2)
        if events.count == 2,
           case .updated(let u5, let s5) = events[0],
           case .updated(let u6, let s6) = events[1] {
            XCTAssertEqual(u5.revision, 5)
            XCTAssertEqual(s5.revision, 5)
            XCTAssertEqual(s5.effective?.state, .blocked)
            XCTAssertEqual(u6.revision, 6)
            XCTAssertEqual(s6.revision, 6)
            XCTAssertNil(s6.effective)
        } else {
            XCTFail("Expected ordered [blocked rev 5, exited rev 6], got \(events)")
        }
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    @MainActor
    func testNSViewDeferredMainDeliverySerializesSnapshotsAndLifecycle() {
        TakoTerminalNSView.isMetalDisabledForTesting = true
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate

        // Enqueue two reports while holding @MainActor, then trigger notifyProgramStatusInterrupted() before RunLoop drains.
        view.enqueue(data: Data("\u{1b}]7501;state=working:id=main:msg=\(b64("One"))\u{1b}\\".utf8))
        view.parserCoordinator.waitForParserQuiescence()
        view.enqueue(data: Data("\u{1b}]7501;state=working:id=main:msg=\(b64("Two"))\u{1b}\\".utf8))
        view.parserCoordinator.waitForParserQuiescence()
        view.notifyProgramStatusInterrupted()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))

        XCTAssertEqual(delegate.programStatusEvents.count, 3)
        if delegate.programStatusEvents.count == 3,
           case .updated(let u1, let s1) = delegate.programStatusEvents[0],
           case .updated(let u2, let s2) = delegate.programStatusEvents[1],
           case .updated(let u3, let s3) = delegate.programStatusEvents[2] {
            XCTAssertEqual([u1.revision, u2.revision, u3.revision], [1, 2, 3])
            XCTAssertEqual([s1.revision, s2.revision, s3.revision], [1, 2, 3])
            XCTAssertEqual(s1.effective?.msg, "One")
            XCTAssertEqual(s2.effective?.msg, "Two")
            XCTAssertNil(s3.effective)
        } else {
            XCTFail("Expected monotonic [rev 1, rev 2, rev 3] on NSView delegate, got \(delegate.programStatusEvents)")
        }
    }
    #endif

    func testHeadlessSessionConcurrentFeedSynchronouslySerializesWithActiveAsyncDelivery() {
        let session = TerminalHeadlessSession(cols: 80, rows: 24)
        defer { session.shutDown() }
        let enteredFirst = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var activeCallbacks = 0, maxConcurrentCallbacks = 0
        var revisions: [UInt64] = []

        session.onProgramStatusEvent = { event in
            stateLock.lock()
            activeCallbacks += 1
            maxConcurrentCallbacks = max(maxConcurrentCallbacks, activeCallbacks)
            let callbackIndex = revisions.count
            if case .updated(let update, let snapshot) = event {
                XCTAssertEqual(update.revision, snapshot.revision)
                revisions.append(update.revision)
            }
            stateLock.unlock()
            if callbackIndex == 0 {
                enteredFirst.signal()
                _ = releaseFirst.wait(timeout: .now() + 2.0)
            }
            stateLock.lock()
            activeCallbacks -= 1
            stateLock.unlock()
        }

        session.enqueue(Data("\u{1b}]7501;state=working:id=main:msg=\(b64("Async 1"))\u{1b}\\".utf8))
        XCTAssertEqual(enteredFirst.wait(timeout: .now() + 2.0), .success)

        let syncPayload = Data("\u{1b}]7501;state=done:id=main:msg=\(b64("Sync 2"))\u{1b}\\".utf8)
        let syncFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            session.feedSynchronously(syncPayload)
            syncFinished.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)
        stateLock.lock()
        let (concurrentWhileParked, countWhileParked) = (maxConcurrentCallbacks, revisions.count)
        stateLock.unlock()

        releaseFirst.signal()
        XCTAssertEqual(syncFinished.wait(timeout: .now() + 2.0), .success)
        XCTAssertEqual(concurrentWhileParked, 1, "feedSynchronously must not overlap parked async delivery callback")
        XCTAssertEqual(countWhileParked, 1, "Second callback must wait until first callback finishes")
        XCTAssertEqual(maxConcurrentCallbacks, 1)
        XCTAssertEqual(revisions, [1, 2])
    }
}
