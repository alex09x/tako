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
        // 1. Direct record via ControlCommands.recordActivity
        let reqSend = try ControlRequest.parse(Data(#"{"cmd":"send","client":"test-agent"}"#.utf8))
        ControlCommands.recordActivity(for: reqSend, on: paneId, action: "send")

        let reqSplit = try ControlRequest.parse(Data(#"{"cmd":"split","client":"test-agent"}"#.utf8))
        ControlCommands.recordActivity(for: reqSplit, on: paneId, action: "split")

        let reqNotify = try ControlRequest.parse(Data(#"{"cmd":"notify","client":"test-agent"}"#.utf8))
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

    @Test func socketStatusRoutingAcrossMultiplePanes() async throws {
        let dir = try privateDir()
        let path = dir + "/c.sock"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let winA = makeWindow(title: "socket-pane-a")
        let winB = makeWindow(title: "socket-pane-b")
        defer {
            Tako.CustomTabGroup.leave(winA)
            Tako.CustomTabGroup.leave(winB)
        }
        let surfA = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let surfB = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        winA.contentView?.addSubview(surfA)
        winB.contentView?.addSubview(surfB)
        defer {
            surfA.removeFromSuperview()
            surfB.removeFromSuperview()
        }
        Tako.CustomTabGroup.join(winB, to: winA, select: false)

        let oldMode = ControlCommands.mode
        ControlCommands.mode = .on
        defer { ControlCommands.mode = oldMode }

        let paneA = ControlCommands.Pane(surface: surfA, windowID: "w1", tabID: "t1")
        let paneB = ControlCommands.Pane(surface: surfB, windowID: "w2", tabID: "t2")

        let server = ControlServer(path: path) { request, reply in
            ControlCommands.handle(request, all: [paneA, paneB], reply: reply)
        }
        #expect(try server.start() == .listening)
        defer { server.stop() }

        let idA = surfA.id.uuidString.lowercased()
        let idB = surfB.id.uuidString.lowercased()


        // 1. Initially both panes are idle
        let initA = try await ask(path, #"{"cmd":"status","args":{"target":"\#(idA)","action":"get"}}"#)
        let initB = try await ask(path, #"{"cmd":"status","args":{"target":"\#(idB)","action":"get"}}"#)
        #expect((initA["result"] as? [String: Any])?["status"] as? String == "idle")
        #expect((initB["result"] as? [String: Any])?["status"] as? String == "idle")

        // 2. Client sends status set 'working' targeting Pane A over UNIX socket
        let setWorking = try await ask(path, #"{"cmd":"status","args":{"target":"\#(idA)","action":"set","status":"working","text":"Thinking..."}}"#)
        #expect(setWorking["ok"] as? Bool == true)

        // Verify Pane A reflects working over socket
        let getAWorking = try await ask(path, #"{"cmd":"status","args":{"target":"\#(idA)","action":"get"}}"#)
        let resA = getAWorking["result"] as? [String: Any]
        #expect(resA?["status"] as? String == "working")
        #expect(resA?["text"] as? String == "Thinking...")
        let tabA = resA?["tab"] as? [String: Any]
        #expect(tabA?["dot"] as? String == "ember")
        #expect(tabA?["color"] as? String == "orange")

        // Nonrecipient Pane B MUST remain completely untouched (idle/dim/gray)
        let getBStillIdle = try await ask(path, #"{"cmd":"status","args":{"target":"\#(idB)","action":"get"}}"#)
        let resB = getBStillIdle["result"] as? [String: Any]
        #expect(resB?["status"] as? String == "idle")
        #expect(resB?["text"] == nil)
        let tabB = resB?["tab"] as? [String: Any]
        #expect(tabB?["dot"] as? String == "dim")
        #expect(tabB?["color"] as? String == "gray")

        // 3. Client sets Pane A to 'done' over socket
        surfA.crab.isFocused = false
        let setDone = try await ask(path, #"{"cmd":"status","args":{"target":"\#(idA)","action":"set","status":"done","text":"Turn complete"}}"#)
        #expect(setDone["ok"] as? Bool == true)

        let getADone = try await ask(path, #"{"cmd":"status","args":{"target":"\#(idA)","action":"get"}}"#)
        let tabADone = (getADone["result"] as? [String: Any])?["tab"] as? [String: Any]
        #expect(tabADone?["dot"] as? String == "ok")
        #expect(tabADone?["color"] as? String == "green")

        // Nonrecipient Pane B is STILL untouched
        let getBStillIdle2 = try await ask(path, #"{"cmd":"status","args":{"target":"\#(idB)","action":"get"}}"#)
        #expect((getBStillIdle2["result"] as? [String: Any])?["status"] as? String == "idle")

        // 4. Focus acknowledgement: focusing Pane A resets done to idle
        surfA.crab.focused()
        let getAFocused = try await ask(path, #"{"cmd":"status","args":{"target":"\#(idA)","action":"get"}}"#)
        let tabAFocused = (getAFocused["result"] as? [String: Any])?["tab"] as? [String: Any]
        #expect(tabAFocused?["dot"] as? String == "dim")
        #expect(tabAFocused?["color"] as? String == "gray")
    }
}
