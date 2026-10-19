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
import SwiftUI
import Testing
@testable import Tako

/// What the user does not see any more, read back from rendered pixels:
/// no Ember bar under the open tab, no Ember frame around a terminal that
/// wants the user.
@Suite(.serialized) @MainActor
struct QuietChromeTests {
    private func isEmber(_ color: NSColor?) -> Bool {
        guard let c = color?.usingColorSpace(.sRGB) else { return false }
        return c.redComponent > 0.8 && c.greenComponent > 0.2 && c.greenComponent < 0.5 && c.blueComponent < 0.3
    }

    @Test func theOpenTabHasNoEmberBarUnderIt() throws {
        let window = makeWindow(title: "solo-term")
        defer { Tako.CustomTabGroup.leave(window) }
        let bar = Tako.TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 38))
        window.contentView?.addSubview(bar)
        bar.layoutTabs()
        try #require(bar.effectiveTabStyle == .pill)
        let tab = try #require(bar.tabs.first)
        try #require(tab.isActive)

        let rep = snapshot(bar)
        let scale = max(1, rep.pixelsHigh / Int(bar.bounds.height))
        let pill = bar.pillRect(for: tab)
        // The bar's bottom 4pt, under the whole pill (bitmap rows run top-down).
        var ember = 0
        for y in (rep.pixelsHigh - 4 * scale)..<rep.pixelsHigh {
            for x in stride(from: Int(pill.minX) * scale, to: Int(pill.maxX) * scale, by: 2)
            where isEmber(rep.colorAt(x: x, y: y)) {
                ember += 1
            }
        }
        #expect(ember == 0)
    }

    @Test func aTerminalThatWantsYouHasNoFrameAroundIt() throws {
        let (view, window) = hostedSurface()
        defer { window.close() }
        view.setStatus(Tako.PaneStatus.needsApproval.rawValue, text: nil, ttl: nil)
        try #require(view.crab.paneStatus == .needsApproval)
        try #require(!view.isBeingLookedAt)

        let renderer = ImageRenderer(content: Tako.InspectableSurface(surfaceView: view)
            .frame(width: 480, height: 240))
        renderer.proposedSize = ProposedViewSize(width: 480, height: 240)
        let image = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let edge = [(0, h / 2), (1, h / 2), (w - 1, h / 2), (w / 2, 0), (w / 2, h - 1), (w / 3, h - 1)]
        #expect(!edge.contains { isEmber(rep.colorAt(x: $0.0, y: $0.1)) })
    }
}
