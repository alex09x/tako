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
import Foundation
import Testing
@testable import Tako

@Suite(.serialized)
@MainActor
struct TabStatusLifecycleTests {
    private func mount(_ bar: Tako.TabBarView, in window: NSWindow) {
        bar.frame = NSRect(x: 0, y: 0, width: 400, height: 38)
        window.contentView?.addSubview(bar)
    }

    private func attachSurface(to window: NSWindow) -> Tako.SurfaceView {
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(surface)
        return surface
    }

    @Test func unfocusedWorkingToDoneToFocusedIdleLifecycle() {
        let window = makeWindow(title: "lifecycle-test")
        defer { Tako.CustomTabGroup.leave(window) }

        let surface = attachSurface(to: window)
        defer { surface.removeFromSuperview() }

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: window)

        let tracker = surface.crab

        // 1. Initial idle state: dot must be dim (gray), not green, even when window is selected
        tracker.setStatus(.idle, text: nil)
        let initialReport = Tako.tabVisualStatus(for: window)
        #expect(initialReport.state == "idle")
        #expect(initialReport.dot == "dim")
        #expect(initialReport.color == "gray")
        #expect(initialReport.hex == Tako.Brand.hex(for: "dim"))
        if let tab = bar.tabs.first {
            #expect(bar.pillIndicatorColor(for: tab) == Tako.Brand.dim)
        }

        // 2. Unfocused working turn: dot must be ember (orange)
        tracker.isFocused = false
        tracker.setStatus(.working, text: "Thinking...")
        let workingReport = Tako.tabVisualStatus(for: window)
        #expect(workingReport.state == "working")
        #expect(workingReport.dot == "ember")
        #expect(workingReport.color == "orange")
        #expect(workingReport.hex == Tako.Brand.hex(for: "ember"))
        if let tab = bar.tabs.first {
            #expect(bar.pillIndicatorColor(for: tab) == Tako.Brand.ember)
        }

        // 3. Turn finishes in background: dot must be ok (green, "new output ready")
        tracker.setStatus(.done, text: "Turn complete")
        let doneReport = Tako.tabVisualStatus(for: window)
        #expect(doneReport.state == "done")
        #expect(doneReport.dot == "ok")
        #expect(doneReport.color == "green")
        #expect(doneReport.hex == Tako.Brand.hex(for: "ok"))
        if let tab = bar.tabs.first {
            #expect(bar.pillIndicatorColor(for: tab) == Tako.Brand.ok)
        }

        // 4. User views / focuses the tab: focused() clears done to idle, dot transitions to dim (gray)
        tracker.focused()
        #expect(tracker.paneStatus == .idle)
        let focusedReport = Tako.tabVisualStatus(for: window)
        #expect(focusedReport.state == "idle")
        #expect(focusedReport.dot == "dim")
        #expect(focusedReport.color == "gray")
        #expect(focusedReport.hex == Tako.Brand.hex(for: "dim"))
        if let tab = bar.tabs.first {
            #expect(bar.pillIndicatorColor(for: tab) == Tako.Brand.dim)
        }
    }

    @Test func multiPaneStatusAggregationAcrossPanes() {
        let window = makeWindow(title: "multipane-test")
        defer { Tako.CustomTabGroup.leave(window) }

        let surface1 = attachSurface(to: window)
        defer { surface1.removeFromSuperview() }

        let surface2 = Tako.SurfaceView(frame: NSRect(x: 200, y: 0, width: 200, height: 200))
        window.contentView?.addSubview(surface2)
        defer { surface2.removeFromSuperview() }

        let t1 = surface1.crab
        let t2 = surface2.crab

        t1.setStatus(.idle, text: nil)
        t2.setStatus(.idle, text: nil)
        #expect(Tako.tabVisualStatus(for: window).dot == "dim")

        // Pane 2 starts working -> window reflects ember
        t2.setStatus(.working, text: "Compiling...")
        #expect(Tako.tabVisualStatus(for: window).dot == "ember")
        #expect(Tako.tabVisualStatus(for: window).color == "orange")

        // Pane 2 completes in background -> window reflects ok (green)
        t2.isFocused = false
        t2.setStatus(.done, text: "Compiled")
        #expect(Tako.tabVisualStatus(for: window).dot == "ok")
        #expect(Tako.tabVisualStatus(for: window).color == "green")

        // Window focused -> resets done to idle -> window reflects dim (gray)
        t2.focused()
        #expect(Tako.tabVisualStatus(for: window).dot == "dim")

        // Pane 1 requests approval -> higher priority than idle -> reflects claw (amber)
        t1.setStatus(.needsApproval, text: "Grant disk access?")
        #expect(Tako.tabVisualStatus(for: window).dot == "claw")
        #expect(Tako.tabVisualStatus(for: window).color == "amber")
    }

    @Test func activeAndInactiveTabPaletteContract() {
        let winA = makeWindow(title: "tab-a")
        let winB = makeWindow(title: "tab-b")
        defer {
            Tako.CustomTabGroup.leave(winA)
            Tako.CustomTabGroup.leave(winB)
        }
        let surfA = attachSurface(to: winA)
        let surfB = attachSurface(to: winB)
        defer {
            surfA.removeFromSuperview()
            surfB.removeFromSuperview()
        }
        Tako.CustomTabGroup.join(winB, to: winA, select: false)

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: winA)

        surfA.crab.setStatus(.idle, text: nil)
        surfB.crab.setStatus(.idle, text: nil)

        // Both idle: both active and inactive tabs must report dim
        let repA = Tako.tabVisualStatus(for: winA)
        let repB = Tako.tabVisualStatus(for: winB)
        #expect(repA.dot == "dim")
        #expect(repA.color == "gray")
        #expect(repB.dot == "dim")
        #expect(repB.color == "gray")

        // Inactive tab B finishes -> done -> ok (green)
        surfB.crab.isFocused = false
        surfB.crab.setStatus(.done, text: "New response")
        let repBAfterDone = Tako.tabVisualStatus(for: winB)
        #expect(repBAfterDone.dot == "ok")
        #expect(repBAfterDone.color == "green")

        // Active tab A remains idle -> dim (gray)
        let repAStillIdle = Tako.tabVisualStatus(for: winA)
        #expect(repAStillIdle.dot == "dim")
        #expect(repAStillIdle.color == "gray")
    }

    private static func findTakoctl() -> String? {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            repoRoot.appendingPathComponent("takoctl/target/debug/takoctl").path,
            repoRoot.appendingPathComponent("takoctl/target/release/takoctl").path,
            "/Applications/Tako.app/Contents/MacOS/takoctl",
            "/opt/homebrew/bin/takoctl",
            "/usr/local/bin/takoctl",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func runTakoHook(
        agent: String,
        event: String,
        stdinJSON: String? = nil,
        env: [String: String]
    ) async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptPath = repoRoot.appendingPathComponent("scripts/tako-hook.py").path
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [scriptPath, agent, event]
        proc.environment = env
        let inPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        if let stdinJSON, let data = stdinJSON.data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
        inPipe.fileHandleForWriting.closeFile()
        while proc.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(proc.terminationStatus == 0)
    }

    private func render(_ bar: Tako.TabBarView) {
        bar.layoutTabs()
        if let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
            bar.cacheDisplay(in: bar.bounds, to: rep)
        }
    }

    @Test func allFourAgentsHookLifecycleDrivesPaintedTabDotsSidebarBadgesAndFocusAutoReset() async throws {
        let takoctl = try #require(Self.findTakoctl(), "takoctl binary required")
        let takoctlDir = (takoctl as NSString).deletingLastPathComponent

        let dir = try privateDir()
        let socketPath = dir + "/hook-visual.sock"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let winA = makeWindow(title: "fg-tab")
        let winB = makeWindow(title: "bg-agent-tab")
        defer {
            Tako.overrideTabStatusTheme = nil
            Tako.CustomTabGroup.leave(winA)
            Tako.CustomTabGroup.leave(winB)
        }

        let surfA = attachSurface(to: winA)
        let surfB = attachSurface(to: winB)
        defer {
            surfA.removeFromSuperview()
            surfB.removeFromSuperview()
        }
        Tako.CustomTabGroup.join(winB, to: winA, select: false)
        Tako.CustomTabGroup.group(for: winA).select(winA)

        let bar = Tako.TabBarView(frame: NSRect(x: 0, y: 0, width: 520, height: 38))
        winA.contentView?.addSubview(bar)

        let suiteName = "test.tako.hook.sidebar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sidebarStore = SessionSidebarStore(defaults: defaults)

        let oldMode = ControlCommands.mode
        ControlCommands.mode = .on
        defer { ControlCommands.mode = oldMode }

        let paneA = ControlCommands.Pane(surface: surfA, windowID: "wA", tabID: "tA")
        let paneB = ControlCommands.Pane(surface: surfB, windowID: "wB", tabID: "tB")
        let server = ControlServer(path: socketPath) { request, reply in
            ControlCommands.mode = .on
            ControlCommands.handle(request, all: [paneA, paneB], reply: reply)
        }
        #expect(try server.start() == .listening)
        defer { server.stop() }

        let grant = ControlGrantStore.shared.issueGrant(client: "test-4-agents", scopes: [.signal, .read])
        var env = ProcessInfo.processInfo.environment
        env["TAKO_SOCKET"] = socketPath
        env["TAKO_CONTROL_TOKEN"] = grant.token
        env["TAKO_SURFACE_ID"] = surfB.id.uuidString.lowercased()
        let existingPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "\(takoctlDir):\(existingPath)"

        let idleHex = Tako.Brand.hex(for: "dim")
        let workingHex = Tako.Brand.hex(for: "ember")
        let waitingHex = Tako.Brand.hex(for: "claw")
        let doneHex = Tako.Brand.hex(for: "ok")

        for agent in ["claude", "gemini", "codex", "agy"] {
            surfA.crab.setStatus(.idle, text: nil)
            surfB.crab.isFocused = false
            surfB.crab.setStatus(.idle, text: nil)

            // 1. Initial Idle: painted dot on tab B is dim (gray), sidebar is .idle
            render(bar)
            #expect(bar.paintedPillDots.count == 2)
            #expect(bar.paintedPillDots[ObjectIdentifier(winB)] == idleHex, "Agent \(agent) initial idle dot")
            #expect(sidebarStore.items(for: winA)[1].status == .idle)

            // 2. Working hook (user_prompt_submit / pre_invocation): painted dot is ember (orange)
            let startEvent = (agent == "agy") ? "pre_invocation" : "user_prompt_submit"
            try await Self.runTakoHook(agent: agent, event: startEvent, env: env)
            render(bar)
            #expect(bar.paintedPillDots[ObjectIdentifier(winB)] == workingHex, "Agent \(agent) working dot")
            #expect(bar.paintedPillDots[ObjectIdentifier(winA)] == idleHex, "Foreground tab A stays idle gray")
            let workingSidebar = sidebarStore.items(for: winA)[1]
            #expect(workingSidebar.status == .working)
            #expect(surfB.crab.statusText == "Thinking...")

            // 3. Approval hook (permission_request): painted dot is claw (amber)
            try await Self.runTakoHook(agent: agent, event: "permission_request", env: env)
            render(bar)
            #expect(bar.paintedPillDots[ObjectIdentifier(winB)] == waitingHex, "Agent \(agent) approval dot")
            let approvalSidebar = sidebarStore.items(for: winA)[1]
            #expect(approvalSidebar.status == .needsApproval)
            #expect(approvalSidebar.needsAttention == true)

            // 4. Waiting Input hook (AskUserQuestion / ask_question): painted dot is claw (amber)
            try await Self.runTakoHook(
                agent: agent,
                event: "permission_request",
                stdinJSON: #"{"tool_name":"AskUserQuestion"}"#,
                env: env
            )
            render(bar)
            #expect(bar.paintedPillDots[ObjectIdentifier(winB)] == waitingHex, "Agent \(agent) waiting_for_input dot")
            let waitingSidebar = sidebarStore.items(for: winA)[1]
            #expect(waitingSidebar.status == .waitingForInput)
            #expect(waitingSidebar.needsAttention == true)

            // 5. Done hook (stop in background): painted dot is ok (green)
            surfB.crab.isFocused = false
            try await Self.runTakoHook(agent: agent, event: "stop", env: env)
            render(bar)
            #expect(bar.paintedPillDots[ObjectIdentifier(winB)] == doneHex, "Agent \(agent) done dot")
            let doneSidebar = sidebarStore.items(for: winA)[1]
            #expect(doneSidebar.status == .done)
            #expect(surfB.crab.unread == true)

            // 6. Auto-reset on tab focus: focusing tab B resets Done (green) -> Idle (gray)
            surfB.crab.focused()
            render(bar)
            #expect(bar.paintedPillDots[ObjectIdentifier(winB)] == idleHex, "Agent \(agent) focus auto-reset to idle dot")
            #expect(sidebarStore.items(for: winA)[1].status == .idle)
            #expect(surfB.crab.unread == false)
        }
    }
}
