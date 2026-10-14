/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Darwin
import Foundation
import Testing
@testable import Tako

@Suite(.serialized)
@MainActor
struct TwoAgentPTYRoutingTests {
    private static func findTakoctl() -> String? {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TakoTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // swift
            .deletingLastPathComponent() // root
        let candidates = [
            repoRoot.appendingPathComponent("takoctl/target/debug/takoctl").path,
            repoRoot.appendingPathComponent("takoctl/target/release/takoctl").path,
            "/opt/homebrew/bin/takoctl",
            "/usr/local/bin/takoctl",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func runInPTY(
        program: String,
        env: [String: String],
        timeout: TimeInterval = 5.0
    ) async -> (ok: Bool, output: String) {
        guard let pty = PTY(
            cols: 80,
            rows: 24,
            workingDirectory: NSTemporaryDirectory(),
            program: ["/bin/sh", "-c", program],
            environment: env
        ) else { return (false, "failed to spawn PTY") }
        defer { pty.terminate() }
        let lock = NSLock()
        var collected = Data()
        pty.readLoop(targetQueue: .global(), onData: { chunk in
            lock.lock()
            collected.append(chunk)
            lock.unlock()
        }, onExit: {})

        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let exitCode = pty.exitStatus {
                lock.lock()
                let text = String(decoding: collected, as: UTF8.self)
                lock.unlock()
                return (exitCode == 0, text)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        lock.lock()
        let text = String(decoding: collected, as: UTF8.self)
        lock.unlock()
        return (false, "timed out. output so far: \(text)")
    }

    @Test func twoAgentPTYRoutingAndUIFocusLifecycle() async throws {
        let takoctl = try #require(Self.findTakoctl(), "takoctl binary must be present for PTY routing test")
        let takoctlDir = (takoctl as NSString).deletingLastPathComponent

        let dir = try privateDir()
        let socketPath = dir + "/two-agent.sock"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let winA = makeWindow(title: "agent-pane-a")
        let winB = makeWindow(title: "agent-pane-b")
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

        let paneA = ControlCommands.Pane(surface: surfA, windowID: "wA", tabID: "tA")
        let paneB = ControlCommands.Pane(surface: surfB, windowID: "wB", tabID: "tB")

        let server = ControlServer(path: socketPath) { request, reply in
            ControlCommands.handle(request, all: [paneA, paneB], reply: reply)
        }
        #expect(try server.start() == .listening)
        defer { server.stop() }

        let idA = surfA.id.uuidString.lowercased()
        let idB = surfB.id.uuidString.lowercased()

        let grant = ControlGrantStore.shared.issueGrant(client: "test-agent-suite", scopes: [.signal, .read])
        let token = grant.token

        var baseEnv = ProcessInfo.processInfo.environment
        baseEnv["TAKO_SOCKET"] = socketPath
        baseEnv["TAKO_CONTROL_TOKEN"] = token
        let existingPath = baseEnv["PATH"] ?? "/usr/bin:/bin"
        baseEnv["PATH"] = "\(takoctlDir):\(existingPath)"

        var envA = baseEnv
        envA["TAKO_SURFACE_ID"] = idA

        var envB = baseEnv
        envB["TAKO_SURFACE_ID"] = idB

        // Initial check: both panes idle
        #expect(surfA.crab.paneStatus == .idle)
        #expect(surfB.crab.paneStatus == .idle)
        let tabA0 = Tako.tabVisualStatus(for: winA, targetSurface: surfA)
        let tabB0 = Tako.tabVisualStatus(for: winB, targetSurface: surfB)
        #expect(tabA0.dot == "dim" && tabA0.color == "gray" && tabA0.state == "idle")
        #expect(tabB0.dot == "dim" && tabB0.color == "gray" && tabB0.state == "idle")

        // 1. Pane A PTY executes working hook (no --target passed, relies on TAKO_SURFACE_ID)
        let ranWorkA = await Self.runInPTY(
            program: "\(takoctl) status set working --text 'Thinking...' && \(takoctl) progress indeterminate",
            env: envA
        )
        #expect(ranWorkA.ok, "WorkA output: \(ranWorkA.output)")

        #expect(surfA.crab.paneStatus == .working)
        #expect(surfA.crab.statusText == "Thinking...")
        let tabAWork = Tako.tabVisualStatus(for: winA, targetSurface: surfA)
        #expect(tabAWork.dot == "ember" && tabAWork.color == "orange" && tabAWork.state == "working")
        #expect(tabAWork.progressState == "indeterminate")

        // Nonrecipient Pane B must remain completely untouched (idle / dim / gray)
        #expect(surfB.crab.paneStatus == .idle)
        #expect(surfB.crab.statusText == nil)
        let tabBStayIdle = Tako.tabVisualStatus(for: winB, targetSurface: surfB)
        #expect(tabBStayIdle.dot == "dim" && tabBStayIdle.color == "gray" && tabBStayIdle.state == "idle")
        #expect(tabBStayIdle.progressState == nil)

        // 2. Pane A PTY executes approval request hook (needs_approval + pause)
        let ranPermA = await Self.runInPTY(
            program: "\(takoctl) status set needs_approval --text 'Approval requested' && \(takoctl) progress pause",
            env: envA
        )
        #expect(ranPermA.ok, "PermA output: \(ranPermA.output)")

        #expect(surfA.crab.paneStatus == .needsApproval)
        #expect(surfA.crab.statusText == "Approval requested")
        let tabAPerm = Tako.tabVisualStatus(for: winA, targetSurface: surfA)
        #expect(tabAPerm.dot == "claw" && tabAPerm.color == "amber" && tabAPerm.state == "needs_approval")
        #expect(tabAPerm.progressState == "paused")

        // Pane B still strictly idle
        #expect(surfB.crab.paneStatus == .idle)

        // 3. Pane A PTY executes waiting_for_input hook
        let ranInputA = await Self.runInPTY(
            program: "\(takoctl) status set waiting_for_input --text 'Clarification needed'",
            env: envA
        )
        #expect(ranInputA.ok, "InputA output: \(ranInputA.output)")

        #expect(surfA.crab.paneStatus == .waitingForInput)
        let tabAInput = Tako.tabVisualStatus(for: winA, targetSurface: surfA)
        #expect(tabAInput.dot == "claw" && tabAInput.color == "amber" && tabAInput.state == "waiting_for_input")
        #expect(surfB.crab.paneStatus == .idle)

        // 4. Pane A PTY executes Stop/done hook
        surfA.crab.isFocused = false
        let ranDoneA = await Self.runInPTY(
            program: "\(takoctl) status set done && \(takoctl) progress clear",
            env: envA
        )
        #expect(ranDoneA.ok, "DoneA output: \(ranDoneA.output)")

        #expect(surfA.crab.paneStatus == .done)
        #expect(surfA.crab.unread == true)
        let tabADone = Tako.tabVisualStatus(for: winA, targetSurface: surfA)
        #expect(tabADone.dot == "ok" && tabADone.color == "green" && tabADone.state == "done")
        #expect(tabADone.progressState == nil)

        // Nonrecipient Pane B is STILL idle
        #expect(surfB.crab.paneStatus == .idle)

        // 5. Unassisted UI focus acknowledgement: focusing Pane A clears done to idle
        surfA.crab.focused()
        #expect(surfA.crab.paneStatus == .idle)
        #expect(surfA.crab.unread == false)
        let tabAFocused = Tako.tabVisualStatus(for: winA, targetSurface: surfA)
        #expect(tabAFocused.dot == "dim" && tabAFocused.color == "gray" && tabAFocused.state == "idle")

        // 6. Reverse isolation: Pane B PTY executes working, Pane A remains idle
        let ranWorkB = await Self.runInPTY(
            program: "\(takoctl) status set working --text 'Agent B active'",
            env: envB
        )
        #expect(ranWorkB.ok, "WorkB output: \(ranWorkB.output)")

        #expect(surfB.crab.paneStatus == .working)
        let tabBWork = Tako.tabVisualStatus(for: winB, targetSurface: surfB)
        #expect(tabBWork.dot == "ember" && tabBWork.color == "orange" && tabBWork.state == "working")

        // Pane A strictly remains idle
        #expect(surfA.crab.paneStatus == .idle)
        let tabAStayIdle = Tako.tabVisualStatus(for: winA, targetSurface: surfA)
        #expect(tabAStayIdle.dot == "dim" && tabAStayIdle.color == "gray" && tabAStayIdle.state == "idle")

        // 7. Pane B completes to done and is acknowledged by focus
        surfB.crab.isFocused = false
        let ranDoneB = await Self.runInPTY(program: "\(takoctl) status set done", env: envB)
        #expect(ranDoneB.ok, "DoneB output: \(ranDoneB.output)")
        #expect(surfB.crab.paneStatus == .done)
        surfB.crab.focused()
        #expect(surfB.crab.paneStatus == .idle)
    }
}
