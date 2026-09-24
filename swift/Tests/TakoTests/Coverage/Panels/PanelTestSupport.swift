import AppKit
import Foundation
import SwiftUI
@testable import Tako

// Shared plumbing for the Splits/About/Settings/ClipboardConfirmation/Custom
// App Icon coverage suites in this directory: an offscreen host window (per
// the task's "host in NSScreen.main.visibleFrame" instruction), a
// deadline-based waiter (no fixed sleeps), and a real-mouse-event clicker.
//
// This harness has no live SwiftUI `App`/`Scene` runtime (views are hosted
// directly in a hand-built NSWindow), so `.keyboardShortcut`-driven command
// dispatch and the accessibility tree are both unavailable here -- neither
// `window.performKeyEquivalent` nor an `accessibilityChildren()` walk finds
// anything. Real `NSEvent`s dispatched through `window.sendEvent(_:)` do
// work, since SwiftUI's tap/drag gesture recognizers process them the same
// way a live app would; that is the only interaction technique used below.

@MainActor
func makePanelWindow(size: NSSize = NSSize(width: 480, height: 320)) -> NSWindow {
    // A test host is a background app whose windows come and go; left to
    // automatic termination, macOS sends it a quit once none is open, and
    // the run ends midway with exit status 0.
    ProcessInfo.processInfo.disableAutomaticTermination("windows under test")
    let origin = NSScreen.main.map { NSPoint(x: $0.visibleFrame.minX + 40, y: $0.visibleFrame.minY + 40) } ?? .zero
    let window = NSWindow(
        contentRect: NSRect(origin: origin, size: size),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    return window
}

/// Hosts `view` as the content of `window` and forces a layout pass so the
/// SwiftUI `body` actually evaluates before the caller inspects anything.
@MainActor
func hostPanel<V: View>(_ view: V, in window: NSWindow) -> NSHostingView<V> {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(origin: .zero, size: window.frame.size)
    window.contentView = hosting
    hosting.layout()
    hosting.layoutSubtreeIfNeeded()
    return hosting
}

@MainActor
func waitUntilPanel(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return condition() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return true
}

/// `waitUntilPanel` for code that finishes on `DispatchQueue.main.async`:
/// a synchronous wait never lets the main queue drain in a test host, while
/// awaiting a sleep does.
@MainActor
func waitUntilPanelAsync(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return condition() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return true
}

/// Renders `view` into a real bitmap so pixel output can be compared across
/// two states, proving something was actually drawn differently (the same
/// technique TakoTabBarCoverageTests.swift uses for TabBarView).
@MainActor
func panelSnapshot(_ view: NSView) -> NSBitmapImageRep {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        fatalError("could not create a bitmap rep for \(view)")
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

func panelBitmapsEqual(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
          let da = a.bitmapData, let db = b.bitmapData
    else { return false }
    let length = a.bytesPerRow * a.pixelsHigh
    guard length == b.bytesPerRow * b.pixelsHigh else { return false }
    return memcmp(da, db, length) == 0
}
