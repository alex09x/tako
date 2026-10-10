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
struct PillTabBarUITests {
    func draw(_ bar: Tako.TabBarView) {
        let image = NSImage(size: bar.bounds.size)
        image.lockFocus()
        bar.draw(bar.bounds)
        image.unlockFocus()
    }

    func mount(_ bar: Tako.TabBarView, in window: NSWindow) {
        bar.frame = NSRect(x: 0, y: 0, width: 400, height: 38)
        window.contentView?.addSubview(bar)
    }

    func click(_ bar: Tako.TabBarView, at point: NSPoint, in window: NSWindow, clickCount: Int = 1) {
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

    @Test func defaultTabStyleIsPill() {
        #expect(Tako.Config.TabStyle.default == .pill)
        let bar = Tako.TabBarView(frame: .zero)
        #expect(bar.effectiveTabStyle == .pill)
    }

    @Test func pillTabRectGeometryMatchesWorkspacePill() {
        let a = makeWindow(title: "tab1")
        let b = makeWindow(title: "tab2")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: a)
        draw(bar)

        #expect(bar.tabs.count == 2)
        for tab in bar.tabs {
            let pill = bar.pillRect(for: tab)
            #expect(pill.height == Tako.TabBarView.Metrics.buttonSize)
            #expect(pill.minY == Tako.TabBarView.Metrics.buttonY)
            #expect(pill.minX == tab.frame.minX + 2)
            #expect(pill.width == tab.frame.width - 4)
        }
    }

    @Test func pillIndicatorColorReflectsStates() {
        let a = makeWindow(title: "active-tab")
        let b = makeWindow(title: "inactive-tab")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: a)
        draw(bar)

        guard bar.tabs.count == 2 else {
            Issue.record("Expected 2 tabs laid out")
            return
        }

        let activeTab = bar.tabs[0]
        let inactiveTab = bar.tabs[1]

        // Idle active tab indicator should be ok (green ready dot)
        let activeColor = bar.pillIndicatorColor(for: activeTab)
        #expect(activeColor == Tako.Brand.ok)

        // Idle inactive tab indicator should be dim
        let inactiveColor = bar.pillIndicatorColor(for: inactiveTab)
        #expect(inactiveColor == Tako.TabBarView.Palette.dim)
    }

    @Test func pillCloseRectHitsInsidePillAndClosesTab() {
        let a = makeWindow(title: "first")
        let b = makeWindow(title: "second")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: a)
        draw(bar)

        guard bar.tabs.count == 2 else {
            Issue.record("Expected 2 tabs laid out")
            return
        }

        let firstTab = bar.tabs[0]
        let pill = bar.pillRect(for: firstTab)
        let closeRect = bar.closeRect(of: firstTab)

        #expect(closeRect != .null)
        #expect(closeRect.midX < pill.maxX)
        #expect(closeRect.midX > pill.minX)
        #expect(abs(closeRect.midY - pill.midY) < 1.0)

        a.orderFront(nil)
        #expect(a.isVisible)

        click(bar, at: NSPoint(x: closeRect.midX, y: closeRect.midY), in: a)
        #expect(!a.isVisible)
    }

    @Test func pillAndClassicStylesProduceVisuallyDistinctSnapshots() {
        let a = makeWindow(title: "main")
        let b = makeWindow(title: "worker")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: a)

        bar.styleOverride = .pill
        bar.needsDisplay = true
        let pillSnapshot = snapshot(bar)

        bar.styleOverride = .classic
        bar.needsDisplay = true
        let classicSnapshot = snapshot(bar)

        #expect(!bitmapsEqual(pillSnapshot, classicSnapshot))
    }

    @Test func activeAndInactivePillTabsAreVisuallyDistinct() {
        let a = makeWindow(title: "primary")
        let b = makeWindow(title: "secondary")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)
        let group = Tako.CustomTabGroup.group(for: a)

        let bar = Tako.TabBarView(frame: .zero)
        bar.styleOverride = .pill
        mount(bar, in: a)

        let withAActive = snapshot(bar)

        group.select(b)
        bar.needsDisplay = true
        let withBActive = snapshot(bar)

        #expect(!bitmapsEqual(withAActive, withBActive))
    }

    @Test func pillTabHoverChangesRenderedBitmap() {
        let a = makeWindow(title: "first")
        let b = makeWindow(title: "second")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)

        let bar = Tako.TabBarView(frame: .zero)
        bar.styleOverride = .pill
        mount(bar, in: a)
        draw(bar)

        let unhovered = snapshot(bar)

        bar.hovered = 1
        bar.needsDisplay = true
        let hovered = snapshot(bar)

        #expect(!bitmapsEqual(unhovered, hovered))
    }

    @Test func badgeModeInPillStyleAltersRenderedBitmap() {
        let a = makeWindow(title: "tab-a")
        let b = makeWindow(title: "tab-b")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)

        let bar = Tako.TabBarView(frame: .zero)
        bar.styleOverride = .pill
        mount(bar, in: a)
        draw(bar)

        let normalSnapshot = snapshot(bar)

        bar.showingBadges = true
        bar.needsDisplay = true
        let badgeSnapshot = snapshot(bar)

        #expect(!bitmapsEqual(normalSnapshot, badgeSnapshot))
    }
}
