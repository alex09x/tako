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

/// One request over the socket, as takoctl sends it.
private func ask(_ path: String, _ line: String) async throws -> [String: Any] {
    try await Task.detached {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
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
}

@Suite
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
        // The test's own client writes into sockets the server closes.
        signal(SIGPIPE, SIG_IGN)
        let dir = try privateDir()
        let path = dir + "/c.sock"
        let server = ControlServer(path: path) { _, reply in reply(.ok([:])) }
        #expect(try server.start() == .listening)
        defer { server.stop() }
        let started = Date()
        let answer: String = try await Task.detached {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd) }
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
        // The test's own client writes into sockets the server closes.
        signal(SIGPIPE, SIG_IGN)
        let dir = try privateDir()
        let path = dir + "/c.sock"
        let server = ControlServer(path: path) { _, reply in reply(.ok(["alive": .bool(true)])) }
        #expect(try server.start() == .listening)
        defer { server.stop() }
        func open() -> Int32 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
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
}

