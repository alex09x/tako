/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import UIKit
import XCTest
@testable import TakoCore

@MainActor
final class TakoProgramStatusUIKitTests: XCTestCase {
    private let probe = "\u{1b}]7501;?\u{1b}\\"
    private let capability =
        "\u{1b}]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\u{1b}\\"

    func testChunkedReportsReachUIKitDelegateWithInheritedAppAndDecodedMessage() throws {
        try withTerminal { view, spy in
            view.feed(data: Data("\u{1b}]7501;state=work".utf8))
            XCTAssertTrue(spy.events.isEmpty)
            view.feed(data: Data("ing:app=qwen\u{1b}\\".utf8))
            view.feed(data: report("state=blocked:kind=permission:id=tool:msg=QWxsb3cgY29tbWFuZD8="))

            XCTAssertEqual(spy.events.count, 2)
            let first = try XCTUnwrap(spy.events.first?.snapshot)
            let last = try XCTUnwrap(spy.events.last?.snapshot)
            XCTAssertEqual(first.effective?.state, .working)
            XCTAssertEqual(first.records.count, 1)
            XCTAssertEqual(last.effective?.state, .blocked)
            XCTAssertEqual(last.effective?.kind, .permission)
            XCTAssertEqual(last.effective?.resolvedApp, "qwen")
            XCTAssertEqual(last.effective?.msg, "Allow command?")
            XCTAssertGreaterThan(last.revision, first.revision)
            XCTAssertEqual(view.programStatusSnapshot(), last)
            XCTAssertTrue(spy.events.allSatisfy(\.isLiveTransition))
            XCTAssertTrue(spy.humanInput.isEmpty)

            view.notifyProgramStatusInterrupted()
            XCTAssertTrue(view.programStatusSnapshot().records.isEmpty)
            XCTAssertTrue(try XCTUnwrap(spy.events.last).snapshot.records.isEmpty)
        }
    }

    func testClassifiedRepliesAreExclusiveAndPassiveProbeStillAllowsDA1() throws {
        try withTerminal { view, spy in
            var batches: [TerminalClassifiedReplyBatch] = []
            view.onClassifiedReplies = { batches.append($0) }
            view.feed(data: Data((probe + "\u{1b}[c").utf8))

            let replies = try XCTUnwrap(batches.first).replies
            XCTAssertEqual(replies.map(\.replyClass), [.programStatusCapability, .standardDevice])
            XCTAssertEqual(String(decoding: replies[0].bytes, as: UTF8.self), capability)
            XCTAssertLessThan(replies[0].seq, replies[1].seq)
            XCTAssertTrue(spy.deviceReplies.isEmpty)

            batches.removeAll()
            view.programStatusProbeReplyEnabled = false
            view.feed(data: Data((probe + "\u{1b}[c").utf8))
            XCTAssertEqual(batches.flatMap(\.replies).map(\.replyClass), [.standardDevice])
            XCTAssertTrue(spy.deviceReplies.isEmpty)

            view.onClassifiedReplies = nil
            view.programStatusProbeReplyEnabled = true
            view.feed(data: Data(probe.utf8))
            XCTAssertEqual(String(decoding: spy.deviceReplies, as: UTF8.self), capability)
            XCTAssertTrue(spy.humanInput.isEmpty)
        }
    }

    func testCheckpointRestoresStatusWithoutLiveTransitionOrReplayingProbeReply() throws {
        try withTerminal { view, spy in
            view.feed(data: Data(probe.utf8))
            view.feed(data: report("state=done:app=codex"))
            let saved = view.programStatusSnapshot()
            let checkpoint = try view.exportCheckpoint()

            view.feed(data: report("state=working:app=muse"))
            spy.events.removeAll()
            spy.deviceReplies.removeAll()
            view.programStatusProbeReplyEnabled = false
            try view.importCheckpoint(checkpoint)

            XCTAssertEqual(view.programStatusSnapshot(), saved)
            XCTAssertEqual(spy.events.count, 1)
            let restored = try XCTUnwrap(spy.events.first)
            XCTAssertFalse(restored.isLiveTransition)
            XCTAssertEqual(restored.snapshot, saved)
            XCTAssertTrue(spy.deviceReplies.isEmpty)
            XCTAssertFalse(view.programStatusProbeReplyEnabled)

            view.notifyProgramStatusAcknowledged()
            XCTAssertTrue(view.programStatusSnapshot().records.isEmpty)
            XCTAssertTrue(try XCTUnwrap(spy.events.last).isLiveTransition)
        }
    }

    private func report(_ pairs: String) -> Data {
        Data("\u{1b}]7501;\(pairs)\u{1b}\\".utf8)
    }

    private func withTerminal(_ body: (TakoTerminalView, ProgramStatusUIKitSpy) throws -> Void) throws {
        let previous = TakoTerminalView.isMetalDisabledForTesting
        TakoTerminalView.isMetalDisabledForTesting = true
        defer { TakoTerminalView.isMetalDisabledForTesting = previous }
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let spy = ProgramStatusUIKitSpy()
        view.delegate = spy
        try body(view, spy)
    }
}

@MainActor
private final class ProgramStatusUIKitSpy: TakoTerminalViewDelegate {
    var events: [TerminalProgramStatusEvent] = []
    var deviceReplies = Data()
    var humanInput = Data()

    func terminalView(_ view: TakoTerminalView, sendInputData data: Data) { humanInput.append(data) }
    func terminalView(_ view: TakoTerminalView, sendDeviceReplyData data: Data) { deviceReplies.append(data) }
    func terminalView(_ view: TakoTerminalView, didResizeCols cols: Int, rows: Int) {}
    func terminalView(_ view: TakoTerminalView, didUpdateProgramStatus event: TerminalProgramStatusEvent) {
        events.append(event)
    }
}
