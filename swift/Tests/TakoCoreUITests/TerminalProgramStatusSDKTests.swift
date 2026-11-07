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
}
