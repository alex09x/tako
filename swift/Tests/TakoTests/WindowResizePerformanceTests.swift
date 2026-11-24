/*
 * tako — Live resize must not re-layout every hidden terminal session
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Testing
@testable import Tako

@MainActor @Suite(.serialized)
struct WindowResizePerformanceTests {
    final class Window: NSWindow {
        var resizing = false
        var frameWrites = 0
        override var inLiveResize: Bool { resizing }
        override func setFrame(_ frameRect: NSRect, display flag: Bool) {
            frameWrites += 1
            super.setFrame(frameRect, display: flag)
        }
    }

    private func window() -> Window {
        let w = Window(contentRect: NSRect(x: 200, y: 200, width: 500, height: 300),
                       styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        return w
    }

    @Test func liveResizeDefersHiddenSessionFramesAndCommitsTheFinalSizeOnce() {
        let a = window(), b = window(), c = window()
        defer { for w in [a, b, c] { Tako.CustomTabGroup.leave(w); w.close() } }
        Tako.CustomTabGroup.join(b, to: a, select: false)
        Tako.CustomTabGroup.join(c, to: a, select: false)
        let group = Tako.CustomTabGroup.group(for: a)
        group.selectedWindow = a
        b.frameWrites = 0; c.frameWrites = 0
        let original = b.frame
        a.resizing = true
        for offset in 1...100 {
            a.setFrame(NSRect(x: 200, y: 200, width: 500 + offset, height: 300 + offset), display: false)
            group.syncFrame(from: a)
        }
        #expect(b.frameWrites == 0 && c.frameWrites == 0)
        #expect(b.frame == original && Tako.CustomTabGroup.lastActiveWindowFrame == a.frame)
        a.resizing = false
        group.syncFrame(from: a)
        #expect(b.frame == a.frame && c.frame == a.frame)
        #expect(b.frameWrites == 1 && c.frameWrites == 1)
        group.syncFrame(from: a)
        #expect(b.frameWrites == 1 && c.frameWrites == 1, "Duplicate notifications must not re-layout unchanged siblings")
    }

    @Test func titlebarLookupIsReusedUntilAppKitReplacesTheHierarchy() {
        let w = window()
        defer { w.close() }
        let root = NSView(), container = NSView(), bar = NSView()
        root.addSubview(container); container.addSubview(bar)
        var searches = 0
        var current = container
        var currentBar = bar
        let cache = TitlebarBackgroundCache { view, name in
            searches += 1
            return name == "NSTitlebarContainerView" && view === root ? current :
                (name == "NSTitlebarView" && view === current ? currentBar : nil)
        }
        for _ in 0..<200 { #expect(cache.views(in: w, root: root) == [container, bar]) }
        #expect(searches == 2, "Status/resize refresh must not walk the terminal view tree")
        container.removeFromSuperview()
        current = NSView(); currentBar = NSView()
        root.addSubview(current); current.addSubview(currentBar)
        #expect(cache.views(in: w, root: root) == [current, currentBar])
        #expect(searches == 4, "A replaced titlebar must be rediscovered")
    }
}
