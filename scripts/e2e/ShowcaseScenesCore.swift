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
import ApplicationServices
import Foundation

// MARK: - Showcase Manifest

let showcaseManifest: [SceneManifestItem] = [
    SceneManifestItem(
        id: "welcome",
        chapter: "core",
        feature: "Launch & 24-bit TrueColor Engine",
        witness: "24-bit ANSI color rendering, interactive shell readiness, banner visibility",
        status: .supported
    ),
    SceneManifestItem(
        id: "splits",
        chapter: "core",
        feature: "Split Panes & Keyboard Navigation",
        witness: "Cmd+D horizontal split, Cmd+] pane cycling, independent TTY delivery, Cmd+W closure",
        status: .supported
    ),
    SceneManifestItem(
        id: "workspaces-frame-sync",
        chapter: "core",
        feature: "Multi-Workspace & Live Window Frame Sync",
        witness: "Pill navigation, new workspace dialog, frame independence when off, live sync when enabled",
        status: .supported
    ),
    SceneManifestItem(
        id: "tabs-pills",
        chapter: "core",
        feature: "Native Tabs & Pill Styling",
        witness: "Cmd+T tab creation, Cmd+1/2 switching, per-tab TTY isolation, Cmd+W clean closure",
        status: .supported
    ),
    SceneManifestItem(
        id: "persistence",
        chapter: "core",
        feature: "Process Continuity & Session Persistence",
        witness: "Active background counter survives app quit/relaunch and continues in reattached PTY",
        status: .supported
    ),
    SceneManifestItem(
        id: "quick-terminal",
        chapter: "optional",
        feature: "Quake-Style Quick Terminal Dropdown",
        witness: "Cmd+Shift+` toggle, Quick Terminal discovery via takoctl tree, clean dismissal",
        status: .supported
    ),
    SceneManifestItem(
        id: "zoom",
        chapter: "optional",
        feature: "Dynamic Font Zooming & Column Reflow",
        witness: "Cmd+= increases font / decreases cols, Cmd+0 resets columns",
        status: .supported
    ),
]

// MARK: - Core Scenes Implementations

let coreShowcaseScenes: [ShowcaseScene] = [
    // Scene 1: Welcome & 24-bit TrueColor
    ShowcaseScene(manifest: showcaseManifest[0], run: { ctx in
        let d = ctx.driver
        d.activate()
        d.setSize(CGSize(width: 860, height: 540))
        d.setPosition(CGPoint(x: 100, y: 100))
        d.focus()
        usleep(600_000)

        if let f = d.windowFrame() {
            try ShowcaseStage.assertContains(window: f, name: "Welcome Window")
        }

        // Banner
        try ctx.typeNaturally("clear\n")
        usleep(300_000)

        try ctx.typeNaturally("echo '=== Welcome to Tako Terminal ==='\n")
        usleep(300_000)

        // 24-bit TrueColor palette demonstration
        try ctx.typeNaturally("sh -c 'printf \"\\033[38;2;255;90;90m[RED]\\033[38;2;90;220;90m[GREEN]\\033[38;2;80;180;255m[BLUE]\\033[0m TrueColor 24-bit Engine\\n\"'\n")
        usleep(400_000)

        // Postcondition assertion
        let witnessPath = d.path("welcome_witness")
        try d.run("echo 'welcome_ok' > \(witnessPath)")
        try d.expect("welcome_witness", "welcome_ok\n", "terminal input in welcome scene")
        guard d.hasText(containing: "TrueColor 24-bit Engine") || d.hasText(containing: "Welcome to Tako") else {
            throw Failure("Welcome banner text not visible on terminal screen")
        }

        ctx.recordTiming(scene: "welcome", duration: 0, status: "PASS", evidence: "24-bit ANSI TrueColor palette rendered; welcome witness verified")
        ctx.viewerPause(1.8)
    }),

    // Scene 2: Split Panes & Multi-Pane Navigation
    ShowcaseScene(manifest: showcaseManifest[1], run: { ctx in
        let d = ctx.driver
        d.activate()

        let initialPanes = try d.paneIds()
        guard initialPanes.count == 1 else {
            throw Failure("Precondition failed: expected exactly 1 initial pane, got \(initialPanes.count)")
        }

        // Initial left pane TTY
        try d.run("tty > \(d.path("tty_left1"))")
        let left1 = try d.file("tty_left1").trimmingCharacters(in: .whitespacesAndNewlines)

        // Split horizontally via Cmd+D
        d.key(Key.d, .maskCommand)
        guard d.wait(for: { (try? d.paneIds().count) == 2 }, timeout: 5) else {
            throw Failure("Failed to split pane horizontally via Cmd+D")
        }
        let splitPanes = try d.paneIds()
        guard splitPanes.count == 2 else {
            throw Failure("Expected 2 panes after split, found \(splitPanes.count)")
        }

        // Right pane distinct TTY witness
        try d.run("tty > \(d.path("tty_right"))")
        let right = try d.file("tty_right").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left1.isEmpty && !right.isEmpty && left1 != right else {
            throw Failure("Right split pane did not receive distinct TTY: left=\(left1), right=\(right)")
        }

        // Cycle focus back to left pane via Cmd+]
        d.key(Key.rightBracket, .maskCommand)
        usleep(300_000)

        // Verify focus returned to left pane
        try d.run("tty > \(d.path("tty_left2"))")
        let left2 = try d.file("tty_left2").trimmingCharacters(in: .whitespacesAndNewlines)
        guard left2 == left1 else {
            throw Failure("Focus cycle Cmd+] did not return input to left pane: expected \(left1), got \(left2)")
        }

        // Close right split pane via Cmd+] and Cmd+W
        d.key(Key.rightBracket, .maskCommand)
        usleep(250_000)
        d.key(Key.w, .maskCommand)
        usleep(250_000)
        if let closeBtn = d.button(titled: "Close") {
            d.press(closeBtn)
            usleep(250_000)
        }
        guard d.wait(for: { (try? d.paneIds().count) == 1 }, timeout: 5) else {
            throw Failure("Failed to close split pane via Cmd+W")
        }

        // Verify survivor pane is the original left pane
        try d.run("tty > \(d.path("tty_survivor"))")
        let survivor = try d.file("tty_survivor").trimmingCharacters(in: .whitespacesAndNewlines)
        guard survivor == left1 else {
            throw Failure("Survivor pane TTY (\(survivor)) does not match initial left pane (\(left1))")
        }

        ctx.recordTiming(scene: "splits", duration: 0, status: "PASS", evidence: "2 panes with distinct TTYs (left: \(left1), right: \(right)); focus cycle verified; clean closure with survivor \(survivor)")
        ctx.viewerPause(1.5)
    }),

    // Scene 3: Workspaces & Live Window Frame Sync
    ShowcaseScene(manifest: showcaseManifest[2], run: { ctx in
        let d = ctx.driver
        d.activate()

        let baselineWorkspaces = try d.workspaceList()
        let baselineIds = Set(baselineWorkspaces.compactMap { $0["id"] as? String })
        guard let wsAId = baselineWorkspaces.first(where: { $0["is_active"] as? Bool == true })?["id"] as? String else {
            throw Failure("Could not resolve initial active workspace ID")
        }

        // Window A1 placed within defined stage
        guard let winA1 = d.activeWindow(),
              let idA1 = d.windowID(for: winA1) else {
            throw Failure("Could not resolve Window A1 or its ID")
        }
        d.setPosition(CGPoint(x: 60, y: 60), for: winA1)
        d.setSize(CGSize(width: 600, height: 420), for: winA1)
        usleep(300_000)
        guard let frameA1 = d.windowFrame(winA1) else {
            throw Failure("Could not obtain Window A1 frame")
        }
        try ShowcaseStage.assertContains(window: frameA1, name: "Window A1")

        // Open second window in Workspace A (Window A2) placed within defined stage
        d.key(Key.n, .maskCommand)
        guard d.wait(for: { d.onScreenWindowNumbers().count == 2 }, timeout: 5) else {
            throw Failure("Cmd+N did not open second window in Workspace A")
        }
        guard let winA2 = d.windows().first(where: { d.windowID(for: $0) != idA1 }),
              let idA2 = d.windowID(for: winA2) else {
            throw Failure("Could not resolve Window A2 or its ID")
        }
        d.setPosition(CGPoint(x: 680, y: 60), for: winA2)
        d.setSize(CGSize(width: 560, height: 420), for: winA2)
        usleep(300_000)
        guard let frameA2 = d.windowFrame(winA2) else {
            throw Failure("Could not obtain Window A2 frame")
        }
        try ShowcaseStage.assertContains(window: frameA2, name: "Window A2")

        let liveWin: (CGWindowID) throws -> AXUIElement = { wid in
            guard let w = d.windows().first(where: { d.windowID(for: $0) == wid }) else {
                throw Failure("Window with ID \(wid) not currently found in window list")
            }
            return w
        }

        // Re-focus Window A1 to establish it as frontmost
        AXUIElementSetAttributeValue(try liveWin(idA1), kAXMainAttribute as CFString, kCFBooleanTrue)
        try d.click(at: CGPoint(x: 160, y: 120))
        usleep(600_000)

        // Create Workspace B via clicking Workspace Pill
        try d.clickWorkspacePill(in: try liveWin(idA1))
        try d.clickOpenMenuItem(titled: "New Workspace")
        guard d.wait(for: { d.button(titled: "Create") != nil }, timeout: 5) else {
            throw Failure("New Workspace dialog did not appear")
        }
        usleep(250_000)
        try d.clickButton(titled: "Create")
        guard d.wait(for: { d.button(titled: "Create") == nil }, timeout: 5) else {
            throw Failure("New Workspace dialog was not dismissed")
        }
        usleep(1_000_000)

        // Resolve new Workspace B by baseline set difference
        let listAfterCreate = try d.workspaceList()
        guard let wsB = listAfterCreate.first(where: { !baselineIds.contains(($0["id"] as? String) ?? "") }),
              let wsBId = wsB["id"] as? String,
              let wsBName = wsB["name"] as? String else {
            throw Failure("Failed to locate newly created Workspace B via baseline set difference")
        }
        guard (listAfterCreate.first(where: { $0["is_active"] as? Bool == true })?["id"] as? String)?.lowercased() == wsBId.lowercased() else {
            throw Failure("Active workspace did not switch to newly created Workspace B")
        }

        // Set distinctive frame in Workspace B within stage
        d.setPosition(CGPoint(x: 120, y: 100))
        d.setSize(CGSize(width: 700, height: 440))
        usleep(400_000)
        guard let frameB = d.windowFrame() else {
            throw Failure("Could not obtain Workspace B window frame")
        }
        try ShowcaseStage.assertContains(window: frameB, name: "Workspace B Window")

        // Verify independent frames when sync is disabled
        guard abs(frameB.origin.x - frameA1.origin.x) > 30 || abs(frameB.size.width - frameA1.size.width) > 30 else {
            throw Failure("Frames are unexpectedly identical before enabling sync")
        }

        // Switch to Workspace A: verify disabled sync preserves A1 and A2
        try d.clickWorkspacePill()
        try d.clickOpenMenuItem(titled: "Default")
        guard d.wait(for: {
            ((try? d.workspaceList())?.first(where: { $0["is_active"] as? Bool == true })?["id"] as? String)?.lowercased() == wsAId.lowercased()
        }, timeout: 8) else {
            throw Failure("Failed to switch back to Workspace A")
        }
        usleep(400_000)
        let curWinA1 = try liveWin(idA1)
        let curWinA2 = try liveWin(idA2)
        guard let curA1 = d.windowFrame(curWinA1), abs(curA1.origin.x - frameA1.origin.x) < 5 && abs(curA1.size.width - frameA1.size.width) < 5 else {
            throw Failure("Workspace A1 frame changed while sync was disabled")
        }
        guard let curA2 = d.windowFrame(curWinA2), abs(curA2.origin.x - frameA2.origin.x) < 5 && abs(curA2.size.width - frameA2.size.width) < 5 else {
            throw Failure("Workspace A2 frame changed while sync was disabled")
        }

        // Switch back to Workspace B
        try d.clickWorkspacePill()
        try d.clickOpenMenuItem(titled: wsBName)
        guard d.wait(for: {
            ((try? d.workspaceList())?.first(where: { $0["is_active"] as? Bool == true })?["id"] as? String)?.lowercased() == wsBId.lowercased()
        }, timeout: 8) else {
            throw Failure("Failed to switch back to Workspace B")
        }
        usleep(400_000)

        // Open Settings UI (Cmd+,) and toggle workspace-sync-window-frame
        d.key(Key.comma, .maskCommand)
        guard d.wait(for: { d.button(titled: "Close") != nil }, timeout: 5) else {
            throw Failure("Settings dialog failed to open")
        }
        usleep(250_000)
        d.key(Key.two, .maskCommand)
        usleep(250_000)

        if let search = d.descendants(of: d.element(withIdentifier: "TerminalSettingsDialog")!, role: kAXTextFieldRole).first {
            d.press(search)
            try d.type("sync")
            usleep(250_000)
        }
        if let f = d.windowFrame() {
            try d.click(at: CGPoint(x: f.origin.x + 200, y: f.origin.y + 160))
            usleep(250_000)
        }
        d.key(Key.space)
        guard d.wait(for: {
            guard let curDialog = d.element(withIdentifier: "TerminalSettingsDialog"),
                  let val: String = d.attribute(curDialog, kAXValueAttribute) else { return false }
            return val == "setting_custom_success: workspace-sync-window-frame" ||
                   val.contains("Custom: workspace-sync-window-frame = true")
        }, timeout: 5) else {
            throw Failure("Failed to toggle workspace-sync-window-frame in Settings")
        }
        d.key(Key.escape)
        guard d.wait(for: { d.button(titled: "Close") == nil }, timeout: 5) else {
            throw Failure("Failed to dismiss Settings dialog")
        }
        usleep(250_000)

        // Resize Workspace B window within stage and switch to Workspace A: frame must sync!
        d.setPosition(CGPoint(x: 160, y: 120))
        d.setSize(CGSize(width: 750, height: 470))
        usleep(400_000)
        guard let departingB = d.windowFrame() else {
            throw Failure("No departing frame in Workspace B")
        }
        try ShowcaseStage.assertContains(window: departingB, name: "Departing Window B")

        try d.clickWorkspacePill()
        try d.clickOpenMenuItem(titled: "Default")
        guard d.wait(for: {
            ((try? d.workspaceList())?.first(where: { $0["is_active"] as? Bool == true })?["id"] as? String)?.lowercased() == wsAId.lowercased()
        }, timeout: 8) else {
            throw Failure("Failed to switch to Workspace A for live frame sync verification")
        }
        usleep(400_000)
        guard let arrivedA = d.windowFrame(try liveWin(idA1)) else {
            throw Failure("No window frame for Window A1 in Workspace A after sync switch")
        }
        guard abs(arrivedA.origin.x - departingB.origin.x) < 5 &&
              abs(arrivedA.origin.y - departingB.origin.y) < 5 &&
              abs(arrivedA.size.width - departingB.size.width) < 5 &&
              abs(arrivedA.size.height - departingB.size.height) < 5 else {
            throw Failure("Live frame sync did not match 4D geometry on workspace switch (departing: \(departingB), arrived: \(arrivedA))")
        }

        // Close second window A2 before moving to next scene
        if d.windows().count > 1, let extraWin = d.windows().first(where: { d.windowID(for: $0) == idA2 }) {
            AXUIElementSetAttributeValue(extraWin, kAXMainAttribute as CFString, kCFBooleanTrue)
            d.key(Key.w, .maskCommand)
            usleep(400_000)
        }

        ctx.recordTiming(scene: "workspaces-frame-sync", duration: 0, status: "PASS", evidence: "A1 \(frameA1), A2 \(frameA2), B \(frameB); independent frames when off; live sync matched 4D geometry: departing \(departingB) == arrived \(arrivedA)")
        ctx.viewerPause(2.0)
    }),
]
