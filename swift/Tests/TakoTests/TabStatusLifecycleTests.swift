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
}
