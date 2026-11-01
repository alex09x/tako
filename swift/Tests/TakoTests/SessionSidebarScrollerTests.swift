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
import Testing
@testable import Tako

@MainActor
@Suite(.serialized)
struct SessionSidebarScrollerTests {
    @Test func theSessionListInstallsAnOverlayScrollerWithoutChangingOtherScrollViews() throws {
        let scene = WorkspaceSwitchVisualScene()
        defer { scene.tearDown() }
        scene.populate()
        for i in 0..<15 {
            scene.addTab(scene.surface("Session \(i)", .idle), to: scene.main)
        }
        scene.settle()
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            let current = (view as? NSScrollView).map { [$0] } ?? []
            return current + view.subviews.flatMap(scrollViews)
        }
        let scroller = try #require(scrollViews(scene.sidebar).first {
            $0.verticalScroller is SessionSidebarScroller
        })
        #expect(scroller.scrollerStyle == .overlay)
        #expect(scroller.hasVerticalScroller)
        #expect(scroller.autohidesScrollers)
        #expect(SessionSidebarScroller.isCompatibleWithOverlayScrollers)
        scroller.flashScrollers()
        scene.export(scene.snapshot(), "sidebar-scrollbar-long")

        let other = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        #expect(!(other.verticalScroller is SessionSidebarScroller))
    }

    @Test func installerDoesNotInterceptClicks() {
        let probe = SessionSidebarScrollerInstaller.Probe(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        #expect(probe.hitTest(NSPoint(x: 5, y: 5)) == nil)
    }

    @Test func scrollbarDrawsAThinThumbWithoutATrack() throws {
        let scroller = SessionSidebarScroller(frame: NSRect(x: 0, y: 0, width: 15, height: 200))
        scroller.scrollerStyle = .overlay
        scroller.knobProportion = 0.25
        scroller.doubleValue = 0.5
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 15, pixelsHigh: 200,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: 15, height: 200).fill()
        scroller.drawKnobSlot(in: scroller.bounds, highlight: false)
        scroller.drawKnob()
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        var paintedColumns = Set<Int>()
        var paintedPixels = 0
        for y in 0..<200 {
            for x in 0..<15 {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.03 || color.greenComponent > 0.03 || color.blueComponent > 0.03 {
                    paintedColumns.insert(x)
                    paintedPixels += 1
                }
            }
        }
        #expect(!paintedColumns.isEmpty, "the thumb must be visible")
        #expect(paintedColumns.count <= 4, "the thumb must stay thin and leave no track")
        #expect(paintedPixels < 15 * 100, "the background must not be filled by a track")
    }
}
