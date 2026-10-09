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
        #expect(!FileManager.default.fileExists(atPath: path + ".token"), "No token file should ever be written to disk")
        let answer = try await ask(path, #"{"cmd":"hello","from":"\#(a.uuidString)"}"#)
        #expect(answer["ok"] as? Bool == true)
        let result = answer["result"] as? [String: Any]
        #expect(result?["cmd"] as? String == "hello")
        #expect(result?["from"] as? String == a.uuidString)
        let bad = try await ask(path, "not json")
        #expect((bad["error"] as? [String: Any])?["code"] as? String == "invalid")
    }

    @Test func grantRequestBootstrapFlow() async throws {
        let dir = try privateDir()
        let path = dir + "/c.sock"
        ControlCommands.apply(mode: .on)
        defer {
            ControlCommands.apply(mode: .off)
            ControlCommands.userGrantPrompt = nil
        }

        let server = ControlServer(path: path) { request, reply in
            ControlCommands.handle(request, all: [], reply: reply)
        }
        #expect(try server.start() == .listening)
        defer { server.stop() }

        // 1. User denies grant request
        var capturedOrigin = ""
        ControlCommands.userGrantPrompt = { client, scopes, desc, origin, reply in
            #expect(client == "agent-denied")
            capturedOrigin = origin
            reply(false)
        }
        let deniedAns = try await ask(path, #"{"cmd":"grant","args":{"subcommand":"request","client":"agent-denied"}}"#)
        #expect(deniedAns["ok"] as? Bool == false)
        let deniedErr = deniedAns["error"] as? [String: Any]
        #expect(deniedErr?["code"] as? String == "disabled")
        #expect(!capturedOrigin.isEmpty, "Origin must be resolved by server")

        // 2. Reject spoofed client with newlines or spaces
        let badClientAns = try await ask(path, #"{"cmd":"grant","args":{"subcommand":"request","client":"fake client\nspoof"}}"#)
        #expect(badClientAns["ok"] as? Bool == false)
        #expect((badClientAns["error"] as? [String: Any])?["code"] as? String == "invalid")

        // 3. Reject spoofed multiline description
        let badDescAns = try await ask(path, #"{"cmd":"grant","args":{"subcommand":"request","client":"cli-client","description":"line1\nfake prompt buttons"}}"#)
        #expect(badDescAns["ok"] as? Bool == false)
        #expect((badDescAns["error"] as? [String: Any])?["code"] as? String == "invalid")

        // 4. Requesting only approval scope is rejected without prompt
        var promptCalled = false
        ControlCommands.userGrantPrompt = { client, scopes, desc, origin, reply in
            promptCalled = true
            reply(true)
        }
        let rogueAns = try await ask(path, #"{"cmd":"grant","args":{"subcommand":"request","client":"rogue","scopes":"approval"}}"#)
        #expect(rogueAns["ok"] as? Bool == false)
        #expect(!promptCalled, "Should not prompt user when only approval scope is requested")

        // 5. User approves grant request for read,layout (stripping any requested approval)
        var promptedScopes: Set<ControlScope> = []
        ControlCommands.userGrantPrompt = { client, scopes, desc, origin, reply in
            #expect(client == "cli-client")
            #expect(!scopes.contains(.approval), "Approval scope must be stripped from grant request")
            #expect(desc == "Test CLI")
            #expect(origin.contains("External process") || origin.contains("PID"))
            promptedScopes = scopes
            reply(true)
        }
        let approvedAns = try await ask(path, #"{"cmd":"grant","args":{"subcommand":"request","client":"cli-client","scopes":"read,layout,approval","description":"Test CLI"}}"#)
        #expect(approvedAns["ok"] as? Bool == true)
        let res = try #require(approvedAns["result"] as? [String: Any])
        let token = try #require(res["token"] as? String)
        #expect(res["client"] as? String == "cli-client")
        let issuedScopes = (res["scopes"] as? [String]) ?? []
        #expect(issuedScopes == ["layout", "read"])
        #expect(promptedScopes == [.layout, .read])

        // 6. Token can be used for granted scopes
        let authedReq = try ControlRequest.parse(Data(#"{"cmd":"text","token":"\#(token)"}"#.utf8))
        let authed = ControlCommands.authorize(authedReq)
        #expect(authed.client == "cli-client")
        #expect(authed.scopes == [.read, .layout])
        #expect(throws: Never.self) { try ControlCommands.checkScope(for: authed) }

        // 7. Token cannot be used for ungranted scopes (e.g. signal)
        let ungrantedReq = try ControlRequest.parse(Data(#"{"cmd":"status","token":"\#(token)"}"#.utf8))
        let ungrantedAuth = ControlCommands.authorize(ungrantedReq)
        do {
            try ControlCommands.checkScope(for: ungrantedAuth)
            #expect(Bool(false), "Should have failed with missingScope")
        } catch let err as ControlError {
            #expect(err.code == .missingScope)
            #expect(err.scope == "signal")
        }

        // 8. Token cannot be used to manage grants (approval scope required)
        let grantCreateReq = try ControlRequest.parse(Data(#"{"cmd":"grant","token":"\#(token)","args":{"subcommand":"create","client":"sub"}}"#.utf8))
        let grantCreateAuth = ControlCommands.authorize(grantCreateReq)
        do {
            try ControlCommands.checkScope(for: grantCreateAuth)
            #expect(Bool(false), "Should have failed with missingScope approval")
        } catch let err as ControlError {
            #expect(err.code == .missingScope)
            #expect(err.scope == "approval")
        }

        // 9. Grant request with caller-asserted `from` pane does NOT replace verified process origin
        var promptOrigin = ""
        ControlCommands.userGrantPrompt = { client, scopes, desc, origin, reply in
            promptOrigin = origin
            reply(true)
        }
        let fakePaneId = UUID().uuidString.lowercased()
        let fromAns = try await ask(path, #"{"cmd":"grant","from":"\#(fakePaneId)","args":{"subcommand":"request","client":"caller-with-from","scopes":"read"}}"#)
        #expect(fromAns["ok"] as? Bool == true)
        #expect(promptOrigin.contains("PID") || promptOrigin.contains("Process"))
        #expect(promptOrigin.contains("Claimed Pane Context (unverified"))
        #expect(promptOrigin.contains(fakePaneId))
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

    @Test func activityLogRecordsActionsAndSupportsExport() throws {
        let paneId = UUID()
        let grant = ControlGrantStore.shared.issueGrant(client: "test-agent", scopes: [.read, .input, .layout, .signal])

        // 1. Direct record via ControlCommands.recordActivity
        let reqSend = try ControlRequest.parse(Data(#"{"cmd":"send","token":"\#(grant.token)","client":"test-agent"}"#.utf8))
        ControlCommands.recordActivity(for: reqSend, on: paneId, action: "send")

        let reqSplit = try ControlRequest.parse(Data(#"{"cmd":"split","token":"\#(grant.token)","client":"test-agent"}"#.utf8))
        ControlCommands.recordActivity(for: reqSplit, on: paneId, action: "split")

        let reqNotify = try ControlRequest.parse(Data(#"{"cmd":"notify","token":"\#(grant.token)","client":"test-agent"}"#.utf8))
        ControlCommands.recordActivity(for: reqNotify, on: paneId, action: "notify")

        // 2. Query activity log via InputOwnershipStore
        let log = InputOwnershipStore.shared.activityLog(for: paneId)
        #expect(log.count == 3)
        #expect(log[0].action == "send")
        #expect(log[0].client == "test-agent")
        #expect(log[1].action == "split")
        #expect(log[2].action == "notify")

        // 3. Export to JSON string and file
        let exported = InputOwnershipStore.shared.exportLog(for: paneId)
        #expect(exported.contains("test-agent"))
        #expect(exported.contains("send"))
        #expect(exported.contains("split"))
        #expect(exported.contains("notify"))

        let tmpFile = NSTemporaryDirectory() + "test_activity_\(UUID().uuidString).json"
        try exported.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: tmpFile))
        try? FileManager.default.removeItem(atPath: tmpFile)

        // 4. Clear log records auditable clear event outside the erased log
        InputOwnershipStore.shared.clearLog(paneId: paneId, by: "admin-agent")
        #expect(InputOwnershipStore.shared.activityLog(for: paneId).isEmpty)
        let lastCleared = InputOwnershipStore.shared.lastCleared(for: paneId)
        #expect(lastCleared != nil)
        #expect(lastCleared?.client == "admin-agent")
        #expect(lastCleared?.action == "clear")
    }


}
