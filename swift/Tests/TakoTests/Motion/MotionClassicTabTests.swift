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
import QuartzCore
import Testing
@testable import Tako

/// A classic tab (tab-style = classic) shows the pills' 1b ring where its
/// crab was (Alex, 2026-10-20: the crab is replaced): the ring alone, 14 pt
/// in the slot left of the title, with every state and motion of the ring --
/// which the ring-only rows of MotionStateMatrixTests and
/// MotionTransitionMatrixTests hold -- a failed tab shaking whole as a pill
/// does, the ⌘ badge over it, and a Claw dot where no ✕ is.
@Suite(.serialized) @MainActor
struct MotionClassicTabTests {
    private func ring(of layer: Tako.TabStatusLayer) -> CGRect { layer.ringContainer.frame }

    @Test func theClassicStripDrawsEachTabWithTheRingAloneInItsSlot() throws {
        let scene = StripScene(tabs: 2, style: .classic)
        defer { scene.close() }
        let bar = scene.shown
        bar.display()
        #expect(bar.tabs.count == 2)
        #expect(bar.statusLayers.count == bar.tabs.count, "\(bar.statusLayers.count) rings for \(bar.tabs.count) tabs")
        for tab in bar.tabs {
            let layer = try #require(bar.statusLayers[ObjectIdentifier(tab.window)])
            #expect(layer.superlayer === bar.layer)
            #expect(!layer.drawsSurface, "a classic tab has no comet, glow, glint or line")
            #expect(layer.frame == tab.frame)
            let slotMidX = (tab.frame.minX + Tako.TabBarView.Metrics.tabPaddingLeft).rounded() + Tako.TabBarView.Metrics.crabSize / 2
            let ring = ring(of: layer)
            #expect(ring.size == CGSize(width: MotionSpec.ringSide, height: MotionSpec.ringSide))
            #expect(abs(tab.frame.minX + ring.midX - slotMidX) <= 0.5 && abs(tab.frame.minY + ring.midY - tab.frame.midY) <= 1,
                    "ring at \(ring) in \(tab.frame)")
            #expect(!layer.ringContainer.isHidden)
        }
        bar.styleOverride = .pill
        bar.display()
        for tab in bar.tabs {
            let layer = try #require(bar.statusLayers[ObjectIdentifier(tab.window)])
            #expect(layer.drawsSurface, "a pill lives as a surface")
            #expect(layer.geometry.ringOrigin == nil, "a pill puts its ring 8-9 pt in")
        }
    }

    @Test func theCommandBadgeCoversTheRing() throws {
        let scene = StripScene(tabs: 2, style: .classic)
        defer { scene.close() }
        let bar = scene.shown
        bar.showingBadges = true
        bar.display()
        for tab in bar.tabs {
            let layer = try #require(bar.statusLayers[ObjectIdentifier(tab.window)])
            #expect(layer.ringContainer.isHidden, "the ⌘ badge sits where the ring is")
        }
        bar.showingBadges = false
        bar.display()
        #expect(bar.statusLayers.values.allSatisfy { !$0.ringContainer.isHidden })
    }

    @Test func aClassicTabShowsItsPanesStateAndShakesWholeWhenItFails() throws {
        try withMotionOn { try classicTabShakes() }
    }

    private func classicTabShakes() throws {
        _ = NSApplication.shared
        let surface = Tako.SurfaceView(frame: .zero)
        let window = makeWindow(title: "classic")
        window.contentView = surface
        defer { window.close() }
        let bar = Tako.TabBarView(frame: NSRect(x: 0, y: 0, width: 520, height: 38))
        bar.styleOverride = .classic
        let tab = Tako.TabBarView.Tab(window: window, frame: CGRect(x: 0, y: 5, width: 160, height: 28), isActive: true, index: 0)
        bar.tabs = [tab]
        let image = NSImage(size: bar.bounds.size)
        func draw() {
            image.lockFocus()
            defer { image.unlockFocus() }
            bar.drawTab(tab, in: NSGraphicsContext.current!.cgContext)
        }

        draw()
        let layer = try #require(bar.statusLayers[ObjectIdentifier(window)])
        #expect(layer.currentState == .idle)
        surface.crab.setStatus(.working, text: nil)
        draw()
        #expect(layer.currentState == .working)
        surface.crab.setStatus(.error, text: nil)
        draw()
        #expect(layer.currentState == .failed)
        #expect(!LivingAnimationState.shared.reduceMotion && !LivingAnimationState.shared.isTimelinePaused, "motion is off: the test would see nothing")
        // The strip shakes it frame by frame from the moment it failed.
        var moved: CGFloat = 0
        let until = Date().addingTimeInterval(MotionSpec.shakeDuration)
        while Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            draw()
            moved = max(moved, abs(layer.transform.m41))
        }
        #expect(moved > 0.5, "a failed classic tab shook \(moved) pt")
        #expect(moved <= 2.001, "the design shakes 2 pt each way")
    }

    @Test func aBackgroundTabThatFailedShowsAClawDotWhereNoCloseIs() throws {
        _ = NSApplication.shared
        let surface = Tako.SurfaceView(frame: .zero)
        let window = makeWindow(title: "background")
        window.contentView = surface
        defer { window.close() }
        let bar = Tako.TabBarView(frame: NSRect(x: 0, y: 0, width: 520, height: 38))
        bar.styleOverride = .classic
        let tab = Tako.TabBarView.Tab(window: window, frame: CGRect(x: 0, y: 5, width: 160, height: 28), isActive: false, index: 0)
        bar.tabs = [tab]
        let dot = CGPoint(x: tab.frame.maxX - Tako.TabBarView.Metrics.tabPaddingRight - 2.5, y: tab.frame.midY)
        func clawAtDot() -> Bool {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 520, pixelsHigh: 38, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            bar.drawTab(tab, in: NSGraphicsContext.current!.cgContext)
            NSGraphicsContext.restoreGraphicsState()
            let c = rep.colorAt(x: Int(dot.x), y: 38 - 1 - Int(dot.y))?.usingColorSpace(.sRGB)
            return (c?.alphaComponent ?? 0) > 0.5 && (c?.redComponent ?? 0) > 0.9 && (c?.greenComponent ?? 0) > 0.35
        }
        #expect(!clawAtDot(), "nothing unseen yet")
        surface.crab.setStatus(.error, text: nil)
        #expect(clawAtDot(), "a background tab that failed carries the Claw dot")
    }
}
