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

private let a = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!
private let a2 = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000002")!
private let b = UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000001")!

/// A private directory like the per-user temporary one: 0700, ours.
private func privateDir() throws -> String {
    var template = Array((NSTemporaryDirectory() + "tkc.XXXXXX").utf8CString)
    guard mkdtemp(&template) != nil else { throw POSIXError(.EIO) }
    let dir = String(cString: template)
    chmod(dir, 0o700)
    return dir
}

/// The test's own client sockets: a write to one the server closed must
/// not kill the test process. Set per socket -- the process-wide
/// disposition stays as it is, so the server's own protection is what is
/// being tested.
private func noSigpipe(_ fd: Int32) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
}

private func connectTo(_ path: String) -> Int32 {
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

/// One request over the socket, as takoctl sends it.
private func ask(_ path: String, _ line: String) async throws -> [String: Any] {
    try await Task.detached {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        noSigpipe(fd)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8)
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        let out = Array((line + "\n").utf8)
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }.value
}

@Suite
struct ControlProtocolTests {
    @Test func requestsParse() throws {
        let r = try ControlRequest.parse(Data(#"{"cmd":"tree","args":{"target":"ab"},"from":"\#(a.uuidString)"}"#.utf8))
        #expect(r.cmd == "tree")
        #expect(r.args["target"] == .string("ab"))
        #expect(r.from == a)
        #expect(try ControlRequest.parse(Data(#"{"cmd":"version"}"#.utf8)).from == nil)
    }

    @Test func badRequestsAreRefusedNotGuessed() {
        for bad in [#"nope"#, #"[1]"#, #"{"args":{}}"#, #"{"cmd":"tree","args":[]}"#,
                    #"{"cmd":"tree","from":"not-a-uuid"}"#, #"{"cmd":"tree","from":5}"#] {
            #expect(throws: ControlError.self) { try ControlRequest.parse(Data(bad.utf8)) }
        }
        let huge = Data(repeating: 0x20, count: ControlProtocol.maxRequestBytes + 1)
        #expect(throws: ControlError.self) { try ControlRequest.parse(huge) }
    }

    @Test func responsesAreOneJSONLine() throws {
        let ok = ControlResponse.ok(["id": .string("x")]).encoded()
        #expect(ok.last == 0x0A)
        let failure = ControlResponse.failure(ControlError(.ambiguous, "two", candidates: ["p", "q"])).encoded()
        let object = try JSONSerialization.jsonObject(with: failure) as! [String: Any]
        #expect(object["ok"] as? Bool == false)
        let error = object["error"] as! [String: Any]
        #expect(error["code"] as? String == "ambiguous")
        #expect(error["candidates"] as? [String] == ["p", "q"])
    }

    @Test func targetsResolveToOnePaneOrFail() throws {
        let panes = [a, a2, b]
        func resolve(_ target: String?, from: UUID? = nil, active: UUID? = b) throws -> UUID {
            let args: [String: JSON] = target.map { ["target": .string($0)] } ?? [:]
            return try ControlTarget.from(args, requestFrom: from).resolve(panes: panes, requestFrom: from, active: active)
        }
        #expect(try resolve(a.uuidString) == a)
        #expect(try resolve("bbbb") == b)
        #expect(try resolve(nil, from: a2) == a2)          // default: the client's own pane
        #expect(try resolve(nil) == b)                     // outside a pane: the active one
        #expect(try resolve("active", from: a) == b)
        #expect(try resolve("self", from: a) == a)
        #expect(throws: ControlError(.ambiguous, "2 panes match aaaa",
                                     candidates: [a.uuidString.lowercased(), a2.uuidString.lowercased()])) {
            try resolve("aaaa")
        }
        #expect(throws: ControlError.self) { try resolve("cccc") }
        // The pane a request came from is gone: notFound, never the active one.
        let gone = UUID()
        #expect(throws: ControlError(.notFound, "the pane this request came from is gone")) {
            try resolve(nil, from: gone)
        }
        #expect(throws: ControlError.self) { try resolve("self") }
    }

    @Test func theSettingGatesWhereRequestsComeFrom() {
        #expect(RemoteControlMode.local.allows(from: a, panes: [a]))
        #expect(!RemoteControlMode.local.allows(from: nil, panes: [a]))
        #expect(!RemoteControlMode.local.allows(from: b, panes: [a]))
        #expect(RemoteControlMode.on.allows(from: nil, panes: []))
        #expect(!RemoteControlMode.off.allows(from: a, panes: [a]))
    }

    @Test func requestParsesClientAndScopes() throws {
        // 1. Array of scopes and token
        let req1 = try ControlRequest.parse(Data(#"{"cmd":"notify","client":"bot-1","token":"my-token","scopes":["signal","read"]}"#.utf8))
        #expect(req1.client == "bot-1")
        #expect(req1.token == "my-token")
        #expect(req1.requestedScopes == [.signal, .read])
        #expect(req1.scopes == nil)

        // 2. Comma-separated string of scopes
        let req2 = try ControlRequest.parse(Data(#"{"cmd":"notify","scopes":"signal, input"}"#.utf8))
        #expect(req2.requestedScopes == [.signal, .input])

        // 3. Scopes inside args
        let req3 = try ControlRequest.parse(Data(#"{"cmd":"status","args":{"scopes":"layout"}}"#.utf8))
        #expect(req3.requestedScopes == [.layout])

        // 4. Client inside args
        let req4 = try ControlRequest.parse(Data(#"{"cmd":"status","args":{"client":"sub-agent"}}"#.utf8))
        #expect(req4.client == "sub-agent")

        // 5. Unknown scope throws invalid error
        #expect(throws: ControlError.self) {
            try ControlRequest.parse(Data(#"{"cmd":"status","scopes":["unknownScope"]}"#.utf8))
        }

        // 6. Non-string scope item throws invalid error
        #expect(throws: ControlError.self) {
            try ControlRequest.parse(Data(#"{"cmd":"status","scopes":[123]}"#.utf8))
        }
    }

    @Test func responseIncludesScopeOnMissingScopeError() throws {
        let err = ControlError(.missingScope, "requires signal scope", scope: "signal")
        let failure = ControlResponse.failure(err).encoded()
        let object = try JSONSerialization.jsonObject(with: failure) as! [String: Any]
        #expect(object["ok"] as? Bool == false)
        let error = object["error"] as! [String: Any]
        #expect(error["code"] as? String == "missingScope")
        #expect(error["scope"] as? String == "signal")
    }

    @Test func controlScopeRequiredMapping() {
        #expect(ControlScope.required(for: "version").isEmpty)

        // read
        for cmd in ["tree", "text", "last", "find", "events", "screenshot", "history"] {
            #expect(ControlScope.required(for: cmd) == [.read])
        }
        #expect(ControlScope.required(for: "input", args: ["subcommand": .string("status")]) == [.read])
        #expect(ControlScope.required(for: "input", args: ["subcommand": .string("log")]) == [.read])
        #expect(ControlScope.required(for: "review") == [.read])

        // input
        for cmd in ["send", "type", "key", "broadcast"] {
            #expect(ControlScope.required(for: cmd) == [.input])
        }
        #expect(ControlScope.required(for: "input", args: ["subcommand": .string("lock")]) == [.input])
        #expect(ControlScope.required(for: "review", args: ["subcommand": .string("send")]) == [.input])

        // approval (Track G1 P1 findings: cannot self-approve automation or issue grants with ordinary input)
        #expect(ControlScope.required(for: "input", args: ["subcommand": .string("allow-automation")]) == [.approval])
        #expect(ControlScope.required(for: "input", args: ["subcommand": .string("disallow-automation")]) == [.approval])
        #expect(ControlScope.required(for: "input", args: ["subcommand": .string("confirm-automation")]) == [.approval])
        #expect(ControlScope.required(for: "grant") == [.approval])

        // run requires both layout and input (execution authority)
        #expect(ControlScope.required(for: "run") == [.layout, .input])
        #expect(ControlScope.required(for: "tab-new", args: ["argv": .array([.string("echo")])]) == [.layout, .input])
        #expect(ControlScope.required(for: "split", args: ["argv": .array([.string("ls")])]) == [.layout, .input])

        // layout
        for cmd in ["tab-new", "split", "close", "focus", "collapse", "expand", "workspace", "layout", "action", "task", "session", "wait", "resume"] {
            #expect(ControlScope.required(for: cmd) == [.layout])
        }

        // signal
        for cmd in ["notify", "status", "progress", "ask", "title", "triggers"] {
            #expect(ControlScope.required(for: cmd) == [.signal])
        }

        // overlay
        for cmd in ["dialog", "overlay"] {
            #expect(ControlScope.required(for: cmd) == [.overlay])
        }
    }

    @Test func serverSideGrantAndAuthorizationGate() throws {
        // 1. Unauthenticated client without token fails closed on any scoped command
        let unauth = try ControlRequest.parse(Data(#"{"cmd":"text"}"#.utf8))
        let authUnauth = ControlCommands.authorize(unauth)
        #expect(authUnauth.scopes == [])
        #expect(throws: ControlError.self) { try ControlCommands.checkScope(for: authUnauth) }

        // 2. Client attempting to self-assert scopes in JSON payload without grant fails closed
        let selfAssert = try ControlRequest.parse(Data(#"{"cmd":"text","scopes":["read","input"]}"#.utf8))
        let authSelf = ControlCommands.authorize(selfAssert)
        #expect(authSelf.scopes == [])
        #expect(throws: ControlError.self) { try ControlCommands.checkScope(for: authSelf) }

        // 3. Issue a server-side grant with signal scope only
        let grant = ControlGrantStore.shared.issueGrant(client: "signal-bot", scopes: [.signal])
        let reqSig = try ControlRequest.parse(Data(#"{"cmd":"status","token":"\#(grant.token)"}"#.utf8))
        let authSig = ControlCommands.authorize(reqSig)
        #expect(authSig.client == "signal-bot")
        #expect(authSig.scopes == [.signal])
        #expect(throws: Never.self) { try ControlCommands.checkScope(for: authSig) }

        // Signal client fails on read command
        let reqRead = try ControlRequest.parse(Data(#"{"cmd":"text","token":"\#(grant.token)"}"#.utf8))
        let authRead = ControlCommands.authorize(reqRead)
        do {
            try ControlCommands.checkScope(for: authRead)
            #expect(Bool(false), "Should have failed")
        } catch let err as ControlError {
            #expect(err.code == .missingScope)
            #expect(err.scope == "read")
        }

        // Signal client fails on input command
        let reqType = try ControlRequest.parse(Data(#"{"cmd":"type","token":"\#(grant.token)"}"#.utf8))
        let authType = ControlCommands.authorize(reqType)
        do {
            try ControlCommands.checkScope(for: authType)
            #expect(Bool(false), "Should have failed")
        } catch let err as ControlError {
            #expect(err.code == .missingScope)
            #expect(err.scope == "input")
        }

        // 4. Client with only layout scope fails on run because run requires execution authority (input)
        let layoutGrant = ControlGrantStore.shared.issueGrant(client: "layout-bot", scopes: [.layout])
        let reqRun = try ControlRequest.parse(Data(#"{"cmd":"run","token":"\#(layoutGrant.token)"}"#.utf8))
        let authRun = ControlCommands.authorize(reqRun)
        do {
            try ControlCommands.checkScope(for: authRun)
            #expect(Bool(false), "Should have failed")
        } catch let err as ControlError {
            #expect(err.code == .missingScope)
            #expect(err.scope == "input")
        }

        // 5. Client with input scope cannot self-approve pane automation switch
        let inputGrant = ControlGrantStore.shared.issueGrant(client: "input-bot", scopes: [.input])
        let reqApprove = try ControlRequest.parse(Data(#"{"cmd":"input","token":"\#(inputGrant.token)","args":{"subcommand":"confirm-automation"}}"#.utf8))
        let authApprove = ControlCommands.authorize(reqApprove)
        do {
            try ControlCommands.checkScope(for: authApprove)
            #expect(Bool(false), "Should have failed")
        } catch let err as ControlError {
            #expect(err.code == .missingScope)
            #expect(err.scope == "approval")
        }

        // 6. Client with approval scope can approve automation and issue grants
        let adminGrant = ControlGrantStore.shared.issueGrant(client: "admin-bot", scopes: [.approval])
        let reqAdmin = try ControlRequest.parse(Data(#"{"cmd":"input","token":"\#(adminGrant.token)","args":{"subcommand":"confirm-automation"}}"#.utf8))
        let authAdmin = ControlCommands.authorize(reqAdmin)
        #expect(throws: Never.self) { try ControlCommands.checkScope(for: authAdmin) }
    }
}

@Suite(.serialized)
@MainActor
struct ControlServerTests {
    @Test func aRequestIsAnsweredOverTheSocket() async throws {
        let dir = try privateDir()
        let path = dir + "/c.sock"
        let server = ControlServer(path: path) { request, reply in
            reply(.ok(["cmd": .string(request.cmd), "from": .string(request.from?.uuidString ?? "")]))
        }
        #expect(try server.start() == .listening)
        defer { server.stop() }
        var st = stat()
        #expect(lstat(path, &st) == 0 && st.st_mode & 0o777 == 0o600)
        #expect(FileManager.default.fileExists(atPath: path + ".token"))
        let answer = try await ask(path, #"{"cmd":"hello","from":"\#(a.uuidString)"}"#)
        #expect(answer["ok"] as? Bool == true)
        let result = answer["result"] as? [String: Any]
        #expect(result?["cmd"] as? String == "hello")
        #expect(result?["from"] as? String == a.uuidString)
        let bad = try await ask(path, "not json")
        #expect((bad["error"] as? [String: Any])?["code"] as? String == "invalid")
    }

    @Test func aSecondCopyLeavesTheSocketToTheFirst() async throws {
        let dir = try privateDir()
        let path = dir + "/c.sock"
        let first = ControlServer(path: path) { _, reply in reply(.ok(["who": .string("first")])) }
        #expect(try first.start() == .listening)
        let second = ControlServer(path: path) { _, reply in reply(.ok(["who": .string("second")])) }
        #expect(try second.start() == .taken)
        second.stop()   // must not remove the first one's socket
        let answer = try await ask(path, #"{"cmd":"x"}"#)
        #expect((answer["result"] as? [String: Any])?["who"] as? String == "first")
        first.stop()
        #expect(access(path, F_OK) != 0)
        // Now free: the next copy takes over.
        #expect(try second.start() == .listening)
        second.stop()
    }

    @Test func aSocketLeftByAGoneServerIsReplaced() async throws {
        let dir = try privateDir()
        let path = dir + "/c.sock"
        // A socket file with nobody holding its lock.
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8); raw.copyBytes(from: bytes); raw[bytes.count] = 0
        }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(stale)
        let server = ControlServer(path: path) { _, reply in reply(.ok([:])) }
        #expect(try server.start() == .listening)
        defer { server.stop() }
        #expect(try await ask(path, #"{"cmd":"x"}"#)["ok"] as? Bool == true)
    }

    @Test func aFileThatIsNotOurSocketIsNeverRemoved() throws {
        let dir = try privateDir()
        let path = dir + "/c.sock"
        FileManager.default.createFile(atPath: path, contents: Data("keep".utf8))
        let server = ControlServer(path: path) { _, reply in reply(.ok([:])) }
        #expect(throws: ControlError.self) { try server.start() }
        #expect(FileManager.default.contents(atPath: path) == Data("keep".utf8))
    }

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
        let answer: String = try await Task.detached {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd) }
            noSigpipe(fd)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                let bytes = Array(path.utf8); raw.copyBytes(from: bytes); raw[bytes.count] = 0
            }
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            // A byte every second: each read succeeds, the whole never ends.
            for _ in 0..<10 {
                var byte: UInt8 = 0x20
                if write(fd, &byte, 1) != 1 { break }
                sleep(1)
            }
            var buffer = [UInt8](repeating: 0, count: 512)
            let n = read(fd, &buffer, buffer.count)
            return n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self) : ""
        }.value
        #expect(answer.contains("\"timeout\""))
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


@Suite
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

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}

