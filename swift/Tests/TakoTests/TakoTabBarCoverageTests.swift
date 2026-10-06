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

// MARK: - TabBarView

@Suite
@MainActor
struct TabBarViewCoverageTests {
    private func draw(_ bar: Tako.TabBarView) {
        let image = NSImage(size: bar.bounds.size)
        image.lockFocus()
        bar.draw(bar.bounds)
        image.unlockFocus()
    }

    private func mount(_ bar: Tako.TabBarView, in window: NSWindow) {
        bar.frame = NSRect(x: 0, y: 0, width: 400, height: 38)
        window.contentView?.addSubview(bar)
    }

    @Test func loneWindowDrawsCenteredTitleInsteadOfAStrip() {
        let window = makeWindow(title: "Lone Window")
        defer { Tako.CustomTabGroup.leave(window) }
        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: window)
        // showsStrip == false: exercises drawLoneTitle(). Blanking the title
        // afterwards must change the render -- proof the title text itself,
        // not just the bar background, was actually painted.
        let withTitle = snapshot(bar)
        window.title = ""
        bar.needsDisplay = true
        let withoutTitle = snapshot(bar)
        #expect(!bitmapsEqual(withTitle, withoutTitle))
    }

    @Test func loneWindowWithEmptyTitleDrawsNothingExtra() {
        let window = makeWindow(title: "")
        defer { Tako.CustomTabGroup.leave(window) }
        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: window)
        // `drawLoneTitle` returns before drawing anything beyond the plain
        // bar background/hairline that `draw(_:)` already painted, so
        // redrawing must be a pixel-for-pixel no-op.
        let first = snapshot(bar)
        bar.needsDisplay = true
        let second = snapshot(bar)
        #expect(bitmapsEqual(first, second))
    }

    @Test func twoWindowStripLaysOutAndDrawsBothTabs() {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)
        let group = Tako.CustomTabGroup.group(for: a)

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: a)
        // showsStrip == true: exercises layoutTabs() + draw(tab:) for active
        // and inactive tabs. Switching which tab is active must change what
        // gets drawn -- proof the active/inactive distinction is rendered,
        // not just laid out.
        let withAActive = snapshot(bar)
        group.select(b)
        bar.needsDisplay = true
        let withBActive = snapshot(bar)
        #expect(!bitmapsEqual(withAActive, withBActive))
    }

    /// Any number of tabs can be reached. They shrink to their crab (34pt)
    /// and, past that, the row scrolls to keep the selected tab in view --
    /// never narrower than the crab, so tabs don't overlap.
    @Test func manyTabsScrollToTheSelectedOneAndNeverOverlap() {
        var windows: [NSWindow] = []
        defer { for window in windows { Tako.CustomTabGroup.leave(window) } }

        let anchor = makeWindow(title: "this is a long tab title that wants lots of room")
        windows.append(anchor)
        for index in 1..<25 {
            let window = makeWindow(title: "also a fairly long tab title #\(index)")
            Tako.CustomTabGroup.join(window, to: anchor, select: false)
            windows.append(window)
        }
        let group = Tako.CustomTabGroup.group(for: anchor)
        group.select(windows[24])

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: anchor)
        draw(bar)

        // Scrolled to the end: the last tab sits against the buttons (100pt reserved for ⓘ/◫/+).
        click(bar, at: NSPoint(x: bar.bounds.width - 100 - 1, y: 14), in: anchor)
        #expect(group.selectedWindow === windows[24])
        // Neighbouring 34pt slots are different tabs: none is squeezed thinner.
        click(bar, at: NSPoint(x: bar.bounds.width - 100 - 1 - 34, y: 14), in: anchor)
        #expect(group.selectedWindow === windows[23])
    }

    /// Closing from two tabs to one drops the strip entirely: no cached
    /// tabs are left for a click on the title bar to land on.
    @Test func goingDownToOneWindowForgetsTheStrip() {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: a)
        draw(bar)
        #expect(bar.laidOutTabCount == 2)

        Tako.CustomTabGroup.leave(b)
        draw(bar)
        #expect(bar.laidOutTabCount == 0)
    }

    @Test func scrollOffsetKeepsTheSelectedTabInView() {
        let widths = Array(repeating: CGFloat(34), count: 25) // 850 in all
        #expect(Tako.TabBarView.scrollOffset(widths: widths, selected: 0, available: 242) == 0)
        #expect(Tako.TabBarView.scrollOffset(widths: widths, selected: 24, available: 242) == 608)
        #expect(Tako.TabBarView.scrollOffset(widths: widths, selected: 9, available: 242) == 98)
        #expect(Tako.TabBarView.scrollOffset(widths: [100, 100], selected: 1, available: 242) == 0, "fits")
        #expect(Tako.TabBarView.scrollOffset(widths: widths, selected: nil, available: 242) == 0)
    }

    @Test func mouseMovedHoversATabAndTheButtons() {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: a)
        draw(bar) // Populates `tabs` for hit-testing.
        let baseline = snapshot(bar)

        func move(to point: NSPoint) {
            let event = NSEvent.mouseEvent(
                with: .mouseMoved,
                location: point,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: a.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0)!
            bar.mouseMoved(with: event)
        }

        // Tab 1 ("b") is the inactive one -- an active tab's fill does not
        // change on hover, so only an inactive tab's hover is visible.
        move(to: NSPoint(x: 250, y: 14))
        let afterTabHover = snapshot(bar)
        #expect(!bitmapsEqual(baseline, afterTabHover))

        move(to: NSPoint(x: 378, y: 19)) // The "+" new-tab button.
        let afterPlusHover = snapshot(bar)
        #expect(!bitmapsEqual(afterTabHover, afterPlusHover))

        move(to: NSPoint(x: 346, y: 19)) // The split button.
        let afterSplitHover = snapshot(bar)
        #expect(!bitmapsEqual(afterPlusHover, afterSplitHover))

        move(to: NSPoint(x: 314, y: 19)) // The info / about button.
        let afterInfoHover = snapshot(bar)
        #expect(!bitmapsEqual(afterSplitHover, afterInfoHover))

        move(to: NSPoint(x: 5, y: 5)) // Empty bar area: clears all hover state.
        #expect(bitmapsEqual(snapshot(bar), baseline))

        // Re-hover, then prove mouseExited() clears it the same way.
        move(to: NSPoint(x: 250, y: 14))
        #expect(!bitmapsEqual(snapshot(bar), baseline))

        let exitEvent = NSEvent.enterExitEvent(
            with: .mouseExited,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: a.windowNumber,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil)!
        bar.mouseExited(with: exitEvent)
        #expect(bitmapsEqual(snapshot(bar), baseline))
    }

    @Test func updateTrackingAreasReplacesThePreviousArea() {
        let window = makeWindow(title: "tracking")
        defer { Tako.CustomTabGroup.leave(window) }
        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: window)
        bar.updateTrackingAreas()
        bar.updateTrackingAreas() // Second call exercises removing the prior tracking area.
        #expect(bar.trackingAreas.count == 1)
    }

    private func click(_ bar: Tako.TabBarView, at point: NSPoint, in window: NSWindow, clickCount: Int = 1) {
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1)!
        bar.mouseDown(with: event)
    }

    /// `NSApp.sendAction(_:to:nil:from:)` walks the responder chain and, when
    /// nothing there implements the selector, falls back to the app
    /// delegate -- a reliable catch point regardless of whether this test
    /// process ever gets a real key window (which it may not; see the
    /// caveat on `focusedWorkingDirectoryReadsTheKeyWindowsFirstResponderSurface`
    /// in TakoAppAdapterCoverageTests.swift).

}
