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

import AppKit
import Foundation
import Testing
@testable import Tako

// Coverage for the drawn tab strip's membership/order/selection model
// (`Tako.CustomTabGroup`), where it's mounted (`Tako.TabBarController`), and
// the view that actually draws it (`Tako.TabBarView`). TabText's CoreText
// layout is already covered by TabBarTextTests.swift.

@MainActor
func makeWindow(title: String) -> NSWindow {
    let window = NSWindow(
        // Inside the visible frame: ordering a window front moves it off the
        // Dock and menu bar, which would make frame comparisons meaningless.
        contentRect: NSRect(origin: NSScreen.main.map { NSPoint(x: $0.visibleFrame.minX + 40, y: $0.visibleFrame.minY + 40) } ?? .zero,
                            size: NSSize(width: 400, height: 200)),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false)
    window.title = title
    window.isReleasedWhenClosed = false
    return window
}

/// Renders `view` into a real bitmap so pixels can be compared against a
/// baseline, per the task's prescribed technique for proving drawn state
/// actually changed (hover fills, active-tab highlighting, and so on).
@MainActor
func snapshot(_ view: NSView) -> NSBitmapImageRep {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        fatalError("could not create a bitmap rep for \(view)")
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

func bitmapsEqual(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
          let da = a.bitmapData, let db = b.bitmapData
    else { return false }
    let length = a.bytesPerRow * a.pixelsHigh
    guard length == b.bytesPerRow * b.pixelsHigh else { return false }
    return memcmp(da, db, length) == 0
}

