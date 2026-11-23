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

/// A pane's header and its shelf pill hold the frozen desktop reference:
/// the header shows the pill's 14 pt status ring (`.fw-hd .ring`), a
/// minimized pane is a 30 pt pill with the 16 pt small ring, 6 pt from the
/// next and 14 pt from the canvas's right edge (`.dock`, `.pill`).
@Suite(.serialized) @MainActor
struct FloatingChromeReferenceTests {
    private func find(_ id: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == id { return root }
        for sub in root.subviews { if let hit = find(id, in: sub) { return hit } }
        return nil
    }

    private func rings(in root: NSView) -> [StatusLayerHostView] {
        root.subviews.flatMap { ($0 as? StatusLayerHostView).map { [$0] } ?? rings(in: $0) }
    }

    @Test func headerRingAndShelfPillsFollowTheReference() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        window.setContentSize(NSSize(width: 1000 + SessionSidebarWidth.current(), height: 700))
        controller.showWindow(nil)

        let p1 = try #require(controller.focusedSurface)
        let p2 = try #require(controller.newSplit(at: p1, direction: .right))
        let p3 = try #require(controller.newSplit(at: p2, direction: .right))
        controller.minimizeFloatingPane(p1)
        controller.minimizeFloatingPane(p2)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        content.layoutSubtreeIfNeeded()

        // Pills: 30 pt, 6 pt apart, the rightmost 14 pt from the edge.
        let cards = try [p1, p2].map { p in
            try #require(find("FloatingMinimizedCard-\(p.id.uuidString.lowercased())", in: content))
        }
        let frames = cards.map { $0.convert($0.bounds, to: content) }.sorted { $0.minX < $1.minX }
        for frame in frames { #expect(abs(frame.height - 30) < 0.5, "pill \(frame)") }
        #expect(abs(frames[1].minX - frames[0].maxX - 6) < 0.5, "pills \(frames)")
        #expect(abs(content.bounds.maxX - frames[1].maxX - 14) < 0.5, "edge \(frames[1]) in \(content.bounds)")
        #expect(abs(frames[1].minY - content.bounds.minY - 14) < 0.5, "bottom \(frames[1]) in \(content.bounds)")

        // Each pill's ring is the small 16 pt ring, inside the pill.
        let shelfRings = rings(in: content).filter { ring in
            let r = ring.convert(ring.bounds, to: content)
            return frames.contains { $0.insetBy(dx: -1, dy: -1).contains(r) }
        }
        #expect(shelfRings.count == 2)
        for ring in shelfRings { #expect(abs(ring.statusLayer.transform.m11 - 16.0 / 14) < 0.01) }

        // The visible pane's header has the 14 pt ring, inside its 28 pt header.
        let header = try #require(find("FloatingPaneHeader-\(p3.id.uuidString.lowercased())", in: content))
        let band = header.convert(header.bounds, to: content)
        let headerRings = rings(in: content).filter { band.insetBy(dx: -1, dy: -1).contains($0.convert($0.bounds, to: content)) }
        let ring = try #require(headerRings.first, "no status ring in the header \(band)")
        #expect(abs(ring.bounds.width - 14) < 0.5 && abs(ring.statusLayer.transform.m11 - 1) < 0.01)
        // The header's left corner is a square inset: the ring as far from the
        // left edge as from the top.
        let ringFrame = ring.convert(ring.bounds, to: content)
        let ringLeft = ringFrame.minX - band.minX, ringTop = band.maxY - ringFrame.maxY
        #expect(abs(ringLeft - 7) < 1 && abs(ringLeft - ringTop) < 0.5, "ring left \(ringLeft), top \(ringTop)")
    }
}
