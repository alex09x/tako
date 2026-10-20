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
            #expect(pill.minX == tab.frame.minX)
            #expect(pill.width == tab.frame.width)
        }
        if bar.tabs.count == 2 {
            let tab0 = bar.tabs[0]
            let tab1 = bar.tabs[1]
            #expect(tab1.frame.minX - tab0.frame.maxX == 6)
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

        // Idle active tab indicator should be dim (acknowledged idle)
        let activeColor = bar.pillIndicatorColor(for: activeTab)
        #expect(activeColor == Tako.Brand.dim)

        // Idle inactive tab indicator should be dim
        let inactiveColor = bar.pillIndicatorColor(for: inactiveTab)
        #expect(inactiveColor == Tako.Brand.dim)

        // Explicit brand dot-to-color and hex mapping tests
        #expect(Tako.Brand.color(for: "dim", active: true) == Tako.Brand.dim)
        #expect(Tako.Brand.hex(for: "dim", active: true) == "#8a7f76")
        #expect(Tako.Brand.color(for: "dim", active: false) == Tako.Brand.dim)
        #expect(Tako.Brand.hex(for: "dim", active: false) == "#8a7f76")

        #expect(Tako.Brand.color(for: "ok", active: true) == Tako.Brand.ok)
        #expect(Tako.Brand.hex(for: "ok", active: true) == "#7bd88f")
        #expect(Tako.Brand.color(for: "ok", active: false) == Tako.Brand.ok)
        #expect(Tako.Brand.hex(for: "ok", active: false) == "#7bd88f")

        #expect(Tako.Brand.color(for: "unknown", active: true) == Tako.Brand.ok)
        #expect(Tako.Brand.hex(for: "unknown", active: true) == "#7bd88f")
        #expect(Tako.Brand.color(for: "unknown", active: false) == Tako.Brand.dim)
        #expect(Tako.Brand.hex(for: "unknown", active: false) == "#8a7f76")

        #expect(Tako.Brand.color(for: "ember", active: true) == Tako.Brand.ember)
        #expect(Tako.Brand.hex(for: "ember", active: true) == "#f4581c")
        #expect(Tako.Brand.color(for: "claw", active: true) == Tako.Brand.claw)
        #expect(Tako.Brand.hex(for: "claw", active: true) == "#ff7a3d")
        #expect(Tako.Brand.color(for: "error", active: true) == Tako.Brand.error)
        #expect(Tako.Brand.hex(for: "error", active: true) == "#d54e53")
    }

    @Test func pillCloseRectHitsInsidePillAndThresholdBoundary() {
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
        #expect(closeRect.contains(NSPoint(x: closeRect.midX, y: closeRect.midY)))

        // Threshold boundary: width 48..<54 has no close glyph and must return .null
        let narrowTab = Tako.TabBarView.Tab(window: a, frame: CGRect(x: 0, y: 0, width: 50, height: 28), isActive: true, index: 0)
        #expect(bar.closeRect(of: narrowTab) == .null)

        let thresholdTab = Tako.TabBarView.Tab(window: a, frame: CGRect(x: 0, y: 0, width: 54, height: 28), isActive: true, index: 0)
        #expect(bar.closeRect(of: thresholdTab) != .null)
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

    @Test func stripRectEnclosesPillTabsVerticallyWithoutClipping() {
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

        #expect(bar.stripRect.height >= bar.bounds.height)
        for tab in bar.tabs {
            let pill = bar.pillRect(for: tab)
            #expect(pill.minY >= bar.stripRect.minY)
            #expect(pill.maxY <= bar.stripRect.maxY)
        }
    }

    @Test func pillTabHasSymmetricalLayoutAndCloseGlyph() {
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

        guard bar.tabs.count == 2 else {
            Issue.record("Expected 2 tabs laid out")
            return
        }
        for tab in bar.tabs {
            let pill = bar.pillRect(for: tab)
            let closeRect = bar.closeRect(of: tab)
            #expect(closeRect != .null)
            #expect(closeRect.maxX <= pill.maxX)
            #expect(closeRect.minX > pill.minX + 20)
            #expect(abs(closeRect.midY - pill.midY) < 1.0)
        }
    }

    @Test func pillTabBitmapRenderIsVerticallySymmetricalAndUnclipped() {
        let a = makeWindow(title: "test-tab")
        let b = makeWindow(title: "second-tab")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: a)
        draw(bar)

        let rep = snapshot(bar)
        guard bar.tabs.count >= 1 else { return }
        let pill = bar.pillRect(for: bar.tabs[0])
        let midX = Int(pill.midX)

        // Active pill in Spec 1b (§4) uses surfaceActive #241C16 (R=0.141) with hairline #2A211B (R=0.165)
        // on bar #14100E (R=0.078). No Ember bar under it: the pill alone says which tab is open.
        var pillYRows: [Int] = []
        var hasEmberBottomBar = false
        for y in 0..<rep.pixelsHigh {
            if let color = rep.colorAt(x: midX, y: y) {
                if color.redComponent > 0.80 {
                    hasEmberBottomBar = true
                } else if color.redComponent > 0.12 && color.redComponent < 0.50 {
                    pillYRows.append(y)
                }
            }
        }
        #expect(!pillYRows.isEmpty)
        #expect(!hasEmberBottomBar)
        // The bar's 1 pt bottom border (#2A211B, Terminal UI `.tbar`) is in
        // the same colour range five points below the pill, and is not it.
        let scale = max(1, rep.pixelsHigh / Int(bar.bounds.height))
        let run = pillYRows.filter { $0 < rep.pixelsHigh - scale }
        if let minY = run.min(), let maxY = run.max() {
            let renderedHeight = maxY - minY + 1
            let expectedPixels = Int(Tako.TabBarView.Metrics.buttonSize) * scale
            #expect(abs(renderedHeight - expectedPixels) <= 1)
        }
        #expect(bar.paintedRingStates[ObjectIdentifier(a)] == .idle)
    }

    @Test func loneWindowInPillStyleLaysOutSinglePillTab() {
        let window = makeWindow(title: "solo-term")
        defer { Tako.CustomTabGroup.leave(window) }

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: window)
        draw(bar)

        #expect(bar.effectiveTabStyle == .pill)
        #expect(bar.showsStrip)
        #expect(bar.tabs.count == 1)
        guard bar.tabs.count == 1 else { return }
        let tab = bar.tabs[0]
        #expect(tab.isActive)
        let pill = bar.pillRect(for: tab)
        #expect(pill.height == Tako.TabBarView.Metrics.buttonSize)
        #expect(pill.minY == Tako.TabBarView.Metrics.buttonY)
        #expect(pill.minX == bar.effectiveFirstTabX)
        #expect(bar.closeRect(of: tab) != .null)
        #expect(bar.pillIndicatorColor(for: tab) == Tako.Brand.dim)
    }

    @Test func loneWindowInPillStyleShowsDistinctSnapshotWhenTitleChanges() {
        let window = makeWindow(title: "term-one")
        defer { Tako.CustomTabGroup.leave(window) }
        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: window)
        draw(bar)
        let initial = snapshot(bar)
        window.title = "term-two-with-longer-name"
        bar.needsDisplay = true
        let updated = snapshot(bar)
        #expect(!bitmapsEqual(initial, updated))
    }

    @Test func renderLonePillTabGeneratesValidBitmap() {
        let window = makeWindow(title: "agy ~")
        defer { Tako.CustomTabGroup.leave(window) }
        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: window)
        draw(bar)
        let rep = snapshot(bar)
        let pngData = rep.representation(using: .png, properties: [:])
        #expect((pngData?.count ?? 0) > 0)
    }
}
