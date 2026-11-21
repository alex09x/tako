/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Testing
import AppKit
import SwiftUI
import Foundation
@testable import Tako

// MARK: - Offscreen Capture Benchmark (30 Panes Rasterization)

/// A window AppKit does not fit to the screen: `constrainFrameRect` keeps the
/// frame as given, so a fixture larger than a small display is not shrunk.
final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

extension PaneOverviewTests {
    /// Offscreen capture benchmark verifying rasterization of 30 panes to an offscreen bitmap within budget (< 3.5s),
    /// verifying non-blank rendered cards with distinct visual elements.
    /// Note: This validates offscreen layout and bitmap caching; interactive live first-frame presentation via production
    /// open action/callback remains a separate contract.
    @Test func overviewOffscreenCaptureBenchmarkWith30Panes() throws {
        let store = PaneOverviewStore.shared

        // Construct 30 simulated surfaces across multiple controllers
        var controllers: [BaseTerminalController] = []
        for cIdx in 0..<6 {
            var surfacesInController: [Tako.SurfaceView] = []
            for sIdx in 0..<5 {
                let status: Tako.PaneStatus = switch (cIdx * 5 + sIdx) % 5 {
                case 0: .running
                case 1: .error
                case 2: .done
                case 3: .waitingForInput
                default: .idle
                }
                let surf = makeSurface(
                    title: "Pane \(cIdx)-\(sIdx)",
                    pwd: "/Users/alex/workspace/repo-\(cIdx)",
                    status: status
                )
                surfacesInController.append(surf)
            }
            controllers.append(makeController(surfaces: surfacesInController))
        }

        // Warm up SwiftUI runtime, SF Symbols, and AppKit rasterizer so framework/glyph caches are hot
        let warmupStore = PaneOverviewStore()
        warmupStore.refresh(fromControllers: [controllers[0]])
        let warmupView = NSHostingView(rootView: PaneOverviewView(isPresented: .constant(true), store: warmupStore))
        warmupView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        warmupView.layoutSubtreeIfNeeded()
        if let warmupRep = warmupView.bitmapImageRepForCachingDisplay(in: warmupView.bounds) {
            warmupView.cacheDisplay(in: warmupView.bounds, to: warmupRep)
        }

        // Create an actual buffered window for live UI presentation measurement, at
        // the full fixture size. A titled 700 pt window does not fit a hosted runner's
        // 1024×768 below its menu bar, and AppKit clamped it to 642 pt; this window
        // keeps the frame it is given, so the capture is the size asked for.
        let fixture = NSSize(width: 1000, height: 700)
        let window = UnconstrainedWindow(
            contentRect: NSRect(origin: .zero, size: fixture),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            store.stopObserving()
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }

        // Measure actual UI opening time: from trigger to first presented frame (data refresh + view init + layout + render pass + bitmap rasterization)
        let tStart = CFAbsoluteTimeGetCurrent()

        let t0 = CFAbsoluteTimeGetCurrent()
        store.refresh(fromControllers: controllers)
        let tRefresh = CFAbsoluteTimeGetCurrent() - t0

        let t1 = CFAbsoluteTimeGetCurrent()
        let overviewView = PaneOverviewView(isPresented: .constant(true), store: store)
        let hostingView = NSHostingView(rootView: overviewView)
        hostingView.frame = NSRect(origin: .zero, size: fixture)
        window.contentView = hostingView
        window.orderFrontRegardless()
        hostingView.layoutSubtreeIfNeeded()
        let tLayout = CFAbsoluteTimeGetCurrent() - t1

        let t2 = CFAbsoluteTimeGetCurrent()
        window.displayIfNeeded()
        let tDisplay = CFAbsoluteTimeGetCurrent() - t2

        let t3 = CFAbsoluteTimeGetCurrent()
        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            Issue.record("Failed to create bitmap cache rep for overview window")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        let tCache = CFAbsoluteTimeGetCurrent() - t3

        let elapsed = CFAbsoluteTimeGetCurrent() - tStart
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        print("[OFFSCREEN CAPTURE] 30-pane overview offscreen rasterization breakdown: refresh=\(Int(tRefresh*1000))ms, layout=\(Int(tLayout*1000))ms, display=\(Int(tDisplay*1000))ms, cacheDisplay=\(Int(tCache*1000))ms -> offscreenCapture=\(Int(elapsed*1000))ms")
        print("[OFFSCREEN CAPTURE] fixture \(fixture) pt; content \(hostingView.bounds.size) pt; bitmap \(rep.pixelsWide)×\(rep.pixelsHigh) px; screen \(screen)")

        // Verify visible / presented expected content for 30 panes
        #expect(store.items.count == 30, "Expected 30 items populated in overview store")
        #expect(store.filteredItems.count == 30, "Expected 30 cards presented in overview grid")
        // The defined fixture fits: not clamped, and captured at least one pixel per point.
        #expect(hostingView.bounds.size == fixture, "the overview window was clamped: \(hostingView.bounds.size) on \(screen)")
        #expect(rep.pixelsWide >= Int(fixture.width) && rep.pixelsHigh >= Int(fixture.height),
                "Window rendered frame dimensions must match: \(rep.pixelsWide)×\(rep.pixelsHigh) px")

        // Visual content assertion: verify the captured bitmap is not blank and contains painted cards
        // Check dark backdrop at the window perimeter
        let cornerPixel = rep.colorAt(x: 10, y: 10)
        #expect(cornerPixel != nil, "Captured bitmap must have valid pixel data")
        #expect((cornerPixel?.alphaComponent ?? 0) > 0.5, "Backdrop must be rendered with non-zero alpha")

        // Check center of the modal area has painted content
        let midX = rep.pixelsWide / 2
        let midY = rep.pixelsHigh / 2
        let centerPixel = rep.colorAt(x: midX, y: midY)
        #expect(centerPixel != nil, "Center modal pixel must exist")
        #expect((centerPixel?.alphaComponent ?? 0) > 0.8, "Modal card content must be fully opaque")

        // Separate assertion: one real PaneOverviewCard paints its parts. The grid capture's
        // midline can fall between card rows (it does at this fixture size), so the card
        // itself -- the same item type, the first of these 30 -- is hosted alone at a known
        // frame and its middle row is scanned. This proves a card paints; it does not prove
        // every cell of the grid did (the 30-card count and alpha checks above cover the grid).
        let cardItem = try #require(store.filteredItems.first)
        let cardHost = NSHostingView(rootView: PaneOverviewCard(item: cardItem, isSelected: false, now: Date(),
                                                                reduceMotion: true, showsAnimatedEffects: false)
            .frame(width: 320))
        cardHost.frame = NSRect(origin: .zero, size: CGSize(width: 320, height: cardHost.fittingSize.height))
        cardHost.layoutSubtreeIfNeeded()
        let cardRep = try #require(cardHost.bitmapImageRepForCachingDisplay(in: cardHost.bounds))
        cardHost.cacheDisplay(in: cardHost.bounds, to: cardRep)
        print("[OFFSCREEN CAPTURE] isolated card \(cardHost.bounds.size) pt; bitmap \(cardRep.pixelsWide)×\(cardRep.pixelsHigh) px")
        #expect(cardHost.bounds.height > 100, "the card must lay out to a real height: \(cardHost.bounds.size)")
        var distinctColors = Set<Int>()
        // Every pixel of the one middle row: the card's and its thumbnail's 1 pt borders are
        // 2 px wide here, which a coarser stride steps over.
        let cardMidY = cardRep.pixelsHigh / 2
        for x in 0..<cardRep.pixelsWide {
            if let c = cardRep.colorAt(x: x, y: cardMidY) {
                let r = Int((c.redComponent * 255).rounded())
                let g = Int((c.greenComponent * 255).rounded())
                let b = Int((c.blueComponent * 255).rounded())
                distinctColors.insert((r << 16) | (g << 8) | b)
            }
        }
        #expect(distinctColors.count >= 3, "A card must paint its boundaries/content (found \(distinctColors.count) distinct colors)")

        // Documented contract:
        // Offscreen software rasterization capture to CPU bitmap rep must complete within 3.5 s on unaccelerated CI runner.
        #expect(elapsed < 3.500, "Full offscreen capture and rasterization for 30 panes took \(Int(elapsed * 1000)) ms, exceeding 3.5s budget")
    }
}
