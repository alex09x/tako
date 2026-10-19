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

/// A pane that works shows its ring, never how long it has been at it: the
/// tab, the sidebar row and the Overview card look the same at 1m 14s as
/// at no time at all.
@Suite(.serialized) @MainActor
struct NoTimerTests {
    private func workingPane(title: String = "claude") -> (NSWindow, Tako.SurfaceView, NSView) {
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        surface.title = title
        surface.crab.setStatus(.working, text: nil)
        let window = makeWindow(title: title)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        content.addSubview(surface)
        window.contentView = content
        return (window, surface, content)
    }

    @Test func aWorkingTabDrawsNoTimer() {
        let (window, surface, content) = workingPane()
        defer { Tako.CustomTabGroup.leave(window) }
        let bar = Tako.TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: 38))
        content.addSubview(bar)

        func shot() -> NSBitmapImageRep {
            bar.layoutTabs()
            _ = snapshot(bar)
            for layer in bar.statusLayers.values { layer.applySnapshotPhase(at: 1.1, doneElapsed: 0.35) }
            return snapshot(bar)
        }
        surface.crab.setElapsed(74)
        let atAMinute = shot()
        #expect(bar.pillSurfaceState(for: window) == .working)
        #expect(bar.pillMetaText(for: window) == nil)
        surface.crab.setElapsed(nil)
        #expect(bitmapsEqual(atAMinute, shot()))
    }

    @Test func aWorkingSidebarRowDrawsNoTimer() throws {
        let (window, surface, _) = workingPane()
        defer { Tako.CustomTabGroup.leave(window) }
        let store = SessionSidebarStore(defaults: UserDefaults(suiteName: "NoTimer-\(UUID().uuidString)")!)

        func shot() throws -> (SessionSidebarItem, NSBitmapImageRep) {
            let item = try #require(store.items(for: window).first)
            let row = SessionSidebarRowView(
                item: item, index: 0, selectedIndex: -1, targetWindow: nil, editingItemId: .constant(nil),
                editingDescriptionText: .constant(""), isPresented: .constant(true),
                now: Date(timeIntervalSinceReferenceDate: 1.1), reduceMotion: false, onSelect: {})
            let renderer = ImageRenderer(content: row.frame(width: 260).environment(\.colorScheme, .dark))
            renderer.proposedSize = ProposedViewSize(width: 260, height: nil)
            let image = try #require(renderer.cgImage)
            return (item, NSBitmapImageRep(cgImage: image))
        }
        surface.crab.setElapsed(74)
        let (item, atAMinute) = try shot()
        #expect(item.surfaceState == .working)
        #expect(item.metaDisplayText == nil)
        surface.crab.setElapsed(nil)
        #expect(bitmapsEqual(atAMinute, try shot().1))
    }

    @Test func aWorkingOverviewCardShowsNoTimer() {
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let controller = BaseTerminalController(Tako.App(), surfaceTree: SplitTree<Tako.SurfaceView>(view: surface))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.windowController = controller
        controller.window = window
        surface.crab.setStatus(.working, text: nil)
        surface.crab.setElapsed(74)
        let store = PaneOverviewStore()
        store.refresh(fromControllers: [controller])
        #expect(store.items.first?.surfaceState == .working)
        #expect(store.items.first?.metaDisplayText == nil)
    }
}
