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

/// A host may shut a headless session down from inside one of its callbacks.
/// The rest of that delivery is then dropped: nothing reaches the host after
/// `shutDown()` returned, not even what was already parsed.
final class TerminalHeadlessShutdownTests: XCTestCase {
    private func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    func testShuttingDownInTheReplyCallbackDropsTheStatusOfTheSameFeed() {
        let session = TerminalHeadlessSession(cols: 80, rows: 24, deliveryDispatch: { $0() })
        defer { session.shutDown() }
        var replies = 0
        var statuses: [TerminalProgramStatusEvent] = []
        session.onProgramStatusEvent = { statuses.append($0) }
        session.onClassifiedReplies = { _ in
            replies += 1
            session.shutDown()
        }
        session.feedSynchronously(Data("\u{1b}[c\u{1b}]7501;state=working:app=Codex\u{1b}\\".utf8))
        XCTAssertEqual(replies, 1, "the test needs a reply in the same feed as the status")
        XCTAssertTrue(statuses.isEmpty, "a status reached the host after it shut the session down: \(statuses)")
    }

    func testShuttingDownInTheOverflowCallbackDropsTheRepliesItCameWith() {
        let session = TerminalHeadlessSession(cols: 80, rows: 24, deliveryDispatch: { $0() })
        defer { session.shutDown() }
        var overflows = 0
        var legacy = Data()
        session.onReplyOverflow = { _ in
            overflows += 1
            session.shutDown()
        }
        session.onDeviceReplyData = { legacy.append($0) }
        session.feedSynchronously(Data(String(repeating: "\u{1b}[c", count: 300).utf8))
        XCTAssertEqual(overflows, 1, "the test needs a reply overflow")
        XCTAssertTrue(legacy.isEmpty, "replies reached the host after it shut the session down")
    }

    func testShuttingDownInTheFirstStatusCallbackDropsTheStatusesAfterIt() {
        let session = TerminalHeadlessSession(cols: 80, rows: 24, deliveryDispatch: { $0() })
        defer { session.shutDown() }
        var statuses: [TerminalProgramStatusEvent] = []
        session.onProgramStatusEvent = { event in
            statuses.append(event)
            session.shutDown()
        }
        var payload = ""
        for state in ["working", "blocked:kind=question", "done"] {
            payload += "\u{1b}]7501;state=\(state):id=main:msg=\(b64(state))\u{1b}\\"
        }
        session.feedSynchronously(Data(payload.utf8))
        XCTAssertEqual(statuses.count, 1, "statuses after the one that shut the session down: \(statuses)")
    }

    func testShuttingDownInTheRestoreCallbackDropsTheRestoredStatus() throws {
        let producer = TerminalHeadlessSession(cols: 80, rows: 24, deliveryDispatch: { $0() })
        defer { producer.shutDown() }
        producer.feedSynchronously(Data("\u{1b}]7501;state=error:id=build:app=Codex\u{1b}\\".utf8))
        let checkpoint = try producer.exportCheckpoint()

        let consumer = TerminalHeadlessSession(cols: 80, rows: 24, deliveryDispatch: { $0() })
        defer { consumer.shutDown() }
        var restores = 0
        var statuses: [TerminalProgramStatusEvent] = []
        consumer.onProgramStatusEvent = { statuses.append($0) }
        consumer.onCheckpointRestored = { _ in
            restores += 1
            consumer.shutDown()
        }
        _ = try consumer.importCheckpoint(checkpoint)
        XCTAssertEqual(restores, 1, "the test needs the restore callback")
        XCTAssertTrue(statuses.isEmpty, "the restored status reached the host after it shut the session down")
    }

    /// Without a shutdown every callback of the delivery still runs.
    func testWithoutAShutdownEveryCallbackOfTheDeliveryRuns() {
        let session = TerminalHeadlessSession(cols: 80, rows: 24, deliveryDispatch: { $0() })
        defer { session.shutDown() }
        var replies = 0
        var statuses: [TerminalProgramStatusEvent] = []
        session.onClassifiedReplies = { _ in replies += 1 }
        session.onProgramStatusEvent = { statuses.append($0) }
        session.feedSynchronously(Data(
            "\u{1b}[c\u{1b}]7501;state=working:id=main\u{1b}\\\u{1b}]7501;state=done:id=main\u{1b}\\".utf8
        ))
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(statuses.count, 2)
    }
}
