/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Darwin
import Foundation
import Testing
@testable import Tako

@MainActor
struct ControlInputTests {
    @Test func keyChordsParse() throws {
        let c = try ControlInput.keyEvent("ctrl+c")
        #expect(c.key == .character && c.ctrl && c.text == "c" && c.physicalText == "c")
        let t = try ControlInput.keyEvent("ctrl+shift+t")
        #expect(t.ctrl && t.shift && t.text == "T" && t.unshiftedText == "t")
        #expect(try ControlInput.keyEvent("enter").key == .enter)
        #expect(try ControlInput.keyEvent("ESC").key == .escape)
        let left = try ControlInput.keyEvent("alt+left")
        #expect(left.key == .left && left.alt)
        for bad in ["", "ctrl+", "hyper+c", "ctrl+cc", "f13", "ctrl+ "] {
            #expect(throws: ControlError.self) { try ControlInput.keyEvent(bad) }
        }
    }

    @Test func textArgumentsMustBeText() throws {
        #expect(throws: ControlError.self) { try ControlInput.text([:]) }
        #expect(throws: ControlError.self) { try ControlInput.text(["text": .number(1)]) }
        #expect(throws: ControlError.self) { try ControlInput.text(["text": .string("a\u{0}b")]) }
        #expect(try ControlInput.text(["text": .string("ls -la")]) == "ls -la")
    }
}

@Suite
@MainActor
struct ControlActionTests {
    @Test func linesMustBeAWholeNumberInRange() throws {
        #expect(try ControlInput.lines([:]) == ControlInput.maxLines)
        #expect(try ControlInput.lines(["lines": .number(3)]) == 3)
        for bad: JSON in [.number(1e300), .number(Double(UInt64.max)), .number(-1), .number(2.5),
                          .number(.infinity), .number(.nan), .string("3")] {
            #expect(throws: ControlError.self) { try ControlInput.lines(["lines": bad]) }
        }
        // As it arrives on the wire.
        let request = try ControlRequest.parse(Data(#"{"cmd":"text","args":{"lines":1e300}}"#.utf8))
        #expect(throws: ControlError.self) { try ControlInput.lines(request.args) }
    }

    @Test func inputToAProgramThatDoesNotReadNeverBlocksAndIsCappedWhole() throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        noSigpipe(pair[0]); noSigpipe(pair[1])
        let writer = try #require(ControlWriter.onDescriptor(pair[0]))
        let item = [UInt8](repeating: 0x61, count: 300 << 10)
        let started = Date()
        var accepted = 0, refused = 0
        for _ in 0..<6 {
            do { try writer.enqueue(item); accepted += 1 } catch { refused += 1 }
        }
        #expect(Date().timeIntervalSince(started) < 0.5)
        #expect(accepted == 3 && refused == 3)          // 3 x 300 KiB fit under 1 MiB
        #expect(writer.pendingBytes <= ControlWriter.maxPending)
    }

    @Test func queuedInputArrivesWholeAndInOrder() async throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        noSigpipe(pair[0]); noSigpipe(pair[1])
        let writer = try #require(ControlWriter.onDescriptor(pair[0]))
        let first = [UInt8]("\u{1b}[200~paste\u{1b}[201~\r".utf8)
        let second = [UInt8]("\u{3}".utf8)
        try writer.enqueue(first)
        try writer.enqueue(second)
        let reader = pair[1]
        let got: [UInt8] = await Task.detached {
            var out: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 256)
            while out.count < first.count + second.count {
                let n = read(reader, &buffer, buffer.count)
                if n <= 0 { break }
                out += buffer[0..<n]
            }
            return out
        }.value
        #expect(got == first + second)
    }

    @Test func workForAClientThatLeftIsNotStartedLate() async throws {
        let dir = try privateDir()
        let path = dir + "/c.sock"
        let ran = Flag()
        let server = ControlServer(path: path) { _, reply in
            ran.set()
            reply(.ok([:]))
        }
        #expect(try server.start() == .listening)
        defer { server.stop() }
        let fd = connectTo(path)
        let line = Array(#"{"cmd":"tab-new"}"#.utf8) + [0x0A]
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        // Hold the main thread while the request is queued for it, and let
        // the client give up in the meantime.
        Thread.sleep(forTimeInterval: 0.3)
        close(fd)
        Thread.sleep(forTimeInterval: 0.2)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!ran.value)
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}

