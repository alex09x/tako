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
extension ControlServerTests {
    @Test func aDirectoryOthersCanReachIsRefused() throws {
        let dir = try privateDir()
        chmod(dir, 0o755)
        let server = ControlServer(path: dir + "/c.sock") { _, reply in reply(.ok([:])) }
        #expect(throws: ControlError.self) { try server.start() }
    }

    @Test func aPathTooLongForASocketIsRefusedBeforeBinding() throws {
        let long = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
        #expect(throws: ControlError.self) { try ControlServer.checkLength(long) }
        let real = try ControlServer.socketPath(bundleID: "com.tako-core.terminal.e2e-persist-1790000000-99999")
        #expect(real.utf8.count < 104)
    }

    @Test func aClientTricklingItsRequestIsCutOffAtTheDeadline() async throws {
        let dir = try privateDir()
        let path = dir + "/c.sock"
        let server = ControlServer(path: path) { _, reply in reply(.ok([:])) }
        #expect(try server.start() == .listening)
        defer { server.stop() }
        let started = Date()
        let deadline = DispatchTime.now() + .seconds(9)
        let (answer, bytesSent) = try await Task.detached {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            try #require(fd >= 0)
            defer { close(fd) }
            noSigpipe(fd)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                let bytes = Array(path.utf8); raw.copyBytes(from: bytes); raw[bytes.count] = 0
            }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            try #require(connected == 0)
            // Keep trickling without completing the request, but observe the
            // answer as soon as it arrives, independently of a later write failing.
            var nextByte = DispatchTime.now()
            var bytesSent = 0
            var answer = Data()
            var buffer = [UInt8](repeating: 0, count: 512)
            while DispatchTime.now() < deadline {
                let now = DispatchTime.now()
                let wake = min(nextByte, deadline)
                let milliseconds = wake > now ? (wake.uptimeNanoseconds - now.uptimeNanoseconds + 999_999) / 1_000_000 : 0
                var pending = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pending, 1, Int32(milliseconds))
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if ready > 0 {
                    let n = read(fd, &buffer, buffer.count)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { break }
                    answer.append(contentsOf: buffer[0..<n])
                    if answer.contains(0x0A) { break }
                } else if DispatchTime.now() < deadline {
                    var byte: UInt8 = 0x20
                    if write(fd, &byte, 1) == 1 {
                        bytesSent += 1
                        nextByte = bytesSent < 10 ? .now() + .seconds(1) : deadline
                    } else {
                        // A closed write side does not mean there is no answer to read.
                        nextByte = deadline
                    }
                }
            }
            return (answer, bytesSent)
        }.value
        #expect(bytesSent > 1)
        let expected = ControlResponse.failure(ControlError(.timeout,
            "no complete request within \(Int(ControlServer.readTimeout)) s")).encoded()
        #expect(answer == expected)
        #expect(Date().timeIntervalSince(started) < 9)
    }

    @Test func refusingAnExtraClientThatAlreadyLeftDoesNotHurtTheServer() async throws {
        let dir = try privateDir()
        let path = dir + "/c.sock"
        let server = ControlServer(path: path) { _, reply in reply(.ok(["alive": .bool(true)])) }
        #expect(try server.start() == .listening)
        defer { server.stop() }
        func open() -> Int32 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            noSigpipe(fd)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                let bytes = Array(path.utf8); raw.copyBytes(from: bytes); raw[bytes.count] = 0
            }
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            return fd
        }
        // Fill every slot with a client that says nothing...
        let idle = (0..<ControlServer.maxConnections).map { _ in open() }
        try await Task.sleep(for: .milliseconds(300))
        // ...then a few that leave at once: each is refused into a closed socket.
        for _ in 0..<5 { close(open()) }
        try await Task.sleep(for: .milliseconds(300))
        idle.forEach { close($0) }
        // The idle ones time out; the server goes on answering.
        var answered = false
        for _ in 0..<40 where !answered {
            try await Task.sleep(for: .milliseconds(250))
            answered = (try? await ask(path, #"{"cmd":"x"}"#))?["ok"] as? Bool == true
        }
        #expect(answered)
    }

    @Test func theSettingTakesEffectWithoutARestart() async throws {
        let bundle = "test.control.\(UUID().uuidString)"
        defer { ControlCommands.stop() }
        ControlCommands.apply(mode: .on, bundleID: bundle)
        let path = ControlCommands.socketPath
        #expect(!path.isEmpty && access(path, F_OK) == 0)
        #expect(try await ask(path, #"{"cmd":"version"}"#)["ok"] as? Bool == true)
        // on -> local: same socket, the gate changes -- a request from outside a pane is refused.
        ControlCommands.apply(mode: .local)
        let refused = try await ask(path, #"{"cmd":"version"}"#)
        #expect((refused["error"] as? [String: Any])?["code"] as? String == "disabled")
        // -> off: no socket, and new shells are told so.
        ControlCommands.apply(mode: .off)
        #expect(ControlCommands.socketPath.isEmpty)
        #expect(access(path, F_OK) != 0)
        ControlCommands.apply(mode: .on)
        #expect(ControlCommands.socketPath == path)
    }

    @Test func aSecondCopyDoesNotHandOutTheFirstCopysSocket() throws {
        let bundle = "test.control.\(UUID().uuidString)"
        let path = try ControlServer.socketPath(bundleID: bundle)
        let first = ControlServer(path: path) { _, reply in reply(.ok([:])) }
        #expect(try first.start() == .listening)
        defer { first.stop(); ControlCommands.stop() }
        ControlCommands.apply(mode: .on, bundleID: bundle)
        #expect(ControlCommands.socketPath.isEmpty)
        #expect(ControlCommands.server == nil)
    }

    @Test func aStoppedServerNeverAnswersWhatItTookEvenAfterARestart() async throws {
        let bundle = "test.control.\(UUID().uuidString)"
        defer { ControlCommands.stop() }
        ControlCommands.apply(mode: .on, bundleID: bundle)
        let path = ControlCommands.socketPath
        let fd = connectTo(path)
        defer { close(fd) }
        let half = Array(#"{"cmd":"vers"#.utf8)
        _ = half.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        try await Task.sleep(for: .milliseconds(200))
        ControlCommands.apply(mode: .off)
        ControlCommands.apply(mode: .on)
        let rest = Array(#"ion"}"#.utf8) + [0x0A]
        _ = rest.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let answer: String = await Task.detached {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &buffer, buffer.count)
            return n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self) : ""
        }.value
        #expect(!answer.contains("\"ok\":true"), "\(answer)")
        // The new server itself works.
        #expect(try await ask(path, #"{"cmd":"version"}"#)["ok"] as? Bool == true)
    }

    @Test func anExpiredDeadlineEndsReadingEvenWithDataWaiting() throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        ControlServer.prepare(pair[0])
        let line = Array(#"{"cmd":"x"}"#.utf8) + [0x0A]
        _ = line.withUnsafeBytes { write(pair[1], $0.baseAddress, $0.count) }
        #expect(throws: ControlError.self) {
            _ = try ControlServer.readRequest(pair[0], deadline: .now() - .milliseconds(1))
        }
    }

    @Test func aClientThatDoesNotReadIsDroppedAtTheWriteDeadline() {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        ControlServer.prepare(pair[0])
        // Far more than a socket buffer holds; nobody reads the other end.
        let big = ControlResponse.ok(["pad": .string(String(repeating: "x", count: 8 << 20))])
        let started = Date()
        ControlServer.send(big, to: pair[0], deadline: .now() + .milliseconds(300))
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func theSettingIsReadFromARealConfigFile() throws {
        let dir = try privateDir()
        func mode(_ text: String?) throws -> RemoteControlMode {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(UUID().uuidString)
            try (text ?? "").write(to: url, atomically: true, encoding: .utf8)
            return Tako.App(configPath: url.path).config.remoteControl
        }
        #expect(try mode("remote-control = on\n") == .on)
        #expect(try mode("remote-control = off\n") == .off)
        #expect(try mode(nil) == .local)
    }
}
