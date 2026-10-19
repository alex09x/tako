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

/// A program that is busy but cannot say how far along it is -- the agent
/// hooks say exactly that on every prompt -- shows as working: the ring
/// turns and the comet runs round the row. It used to be drawn as 35%: the
/// number, a ring a third full, and a strip standing still under the row.
@Suite(.serialized) @MainActor
struct IndeterminateProgressTests {
    private func busyPane(_ status: Tako.PaneStatus = .working) -> (NSWindow, Tako.SurfaceView) {
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        surface.title = "agy"
        surface.crab.setStatus(status, text: nil)
        reportBusy(surface)
        let window = makeWindow(title: "agy")
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        content.addSubview(surface)
        window.contentView = content
        return (window, surface)
    }

    /// What `takoctl progress indeterminate` does to a pane.
    private func reportBusy(_ surface: Tako.SurfaceView) {
        surface.crab.progressReported(state: 3, value: nil)
        surface.updateProgressBar(state: .indeterminate, progress: nil)
    }

    private func sidebarStore() -> SessionSidebarStore {
        SessionSidebarStore(defaults: UserDefaults(suiteName: "Indeterminate-\(UUID().uuidString)")!)
    }

    @Test func aSidebarRowShowsWorkNotAPercentage() throws {
        for status in [Tako.PaneStatus.working, .idle] {
            let (window, surface) = busyPane(status)
            defer { Tako.CustomTabGroup.leave(window) }
            #expect(surface.crab.progressState == .indeterminate)
            let item = try #require(sidebarStore().items(for: window).first)
            #expect(item.surfaceState == .working, "status \(status)")
            #expect(item.metaDisplayText == nil, "status \(status)")
        }
    }

    @Test func aTabShowsWorkNotAPercentage() {
        for status in [Tako.PaneStatus.working, .idle] {
            let (window, _) = busyPane(status)
            defer { Tako.CustomTabGroup.leave(window) }
            let bar = Tako.TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: 38))
            window.contentView?.addSubview(bar)
            #expect(bar.pillSurfaceState(for: window) == .working, "status \(status)")
            #expect(bar.pillMetaText(for: window) == nil, "status \(status)")
        }
    }

    @Test func anOverviewCardShowsWorkNotAPercentage() {
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let controller = BaseTerminalController(Tako.App(), surfaceTree: SplitTree<Tako.SurfaceView>(view: surface))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.windowController = controller
        controller.window = window
        surface.crab.setStatus(.working, text: nil)
        reportBusy(surface)
        let store = PaneOverviewStore()
        store.refresh(fromControllers: [controller])
        #expect(store.items.first?.progressState == .indeterminate)
        #expect(store.items.first?.surfaceState == .working)
        #expect(store.items.first?.metaDisplayText == nil)
    }

    /// Frames across a lap of the comet: the comet passes through the
    /// bottom of the row, a strip that stands still is orange in all of them.
    @Test func underTheRowOnlyTheCometMoves() throws {
        let (window, _) = busyPane()
        defer { Tako.CustomTabGroup.leave(window) }
        let item = try #require(sidebarStore().items(for: window).first)

        func frame(at seconds: TimeInterval) throws -> NSBitmapImageRep {
            let row = SessionSidebarRowView(
                item: item, index: 0, selectedIndex: -1, targetWindow: nil, editingItemId: .constant(nil),
                editingDescriptionText: .constant(""), isPresented: .constant(true),
                now: Date(timeIntervalSinceReferenceDate: seconds), reduceMotion: false, onSelect: {})
            let renderer = ImageRenderer(content: row.frame(width: 260).environment(\.colorScheme, .dark))
            renderer.proposedSize = ProposedViewSize(width: 260, height: nil)
            return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        }
        let frames = try stride(from: 100.0, through: 103.0, by: 0.5).map { try frame(at: $0) }

        // It moves.
        #expect(frames.indices.dropFirst().contains { !bitmapsEqual(frames[$0 - 1], frames[$0]) })

        // Nothing orange stands still along the bottom of the row.
        func orange(_ rep: NSBitmapImageRep, _ x: Int) -> Bool {
            (max(0, rep.pixelsHigh - 5)..<rep.pixelsHigh).contains { y in
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return c.redComponent > 0.55 && c.greenComponent > 0.12 && c.greenComponent < 0.55
                    && c.blueComponent < 0.35
            }
        }
        let width = frames[0].pixelsWide
        let standing = (0..<width).filter { x in frames.allSatisfy { orange($0, x) } }.count
        #expect(standing < width / 20, "\(standing) of \(width) columns stay orange in every frame")
    }
}
