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

/// A click on the session sidebar of a window in the background selects its
/// row, as a sidebar in Finder does. The rows sit in a SwiftUI scroll view
/// whose clip view does not take a first click, so AppKit would spend the
/// click on bringing the window forward and the row would need a second one.
enum SessionSidebarFirstClick {
    /// Whether `event` lands on the sidebar of `window` where AppKit would
    /// otherwise only activate the window: left of the sidebar's resize grip,
    /// on a view that does not take the first click itself.
    static func wants(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .leftMouseDown,
              let root = window.contentView,
              let grip = grip(in: root), !grip.isHiddenOrHasHiddenAncestor
        else { return false }
        let gripFrame = grip.convert(grip.bounds, to: nil)
        let point = event.locationInWindow
        guard point.x < gripFrame.minX, point.y >= gripFrame.minY, point.y <= gripFrame.maxY,
              let hit = (root.superview ?? root).hitTest(point)
        else { return false }
        return !hit.acceptsFirstMouse(for: event)
    }

    /// Hands a click that brought `window` forward to the sidebar once the
    /// window is key. The button may be up by then; the row still needs its
    /// release to count the click.
    static func redeliver(_ event: NSEvent, to window: NSWindow, send: @escaping (NSEvent) -> Void) {
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isKeyWindow else { return }
            send(event)
            guard NSEvent.pressedMouseButtons & 1 == 0,
                  let up = NSEvent.mouseEvent(
                    with: .leftMouseUp, location: event.locationInWindow, modifierFlags: event.modifierFlags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: 0)
            else { return }
            send(up)
        }
    }

    private static func grip(in view: NSView) -> SessionSidebarGripView? {
        if let grip = view as? SessionSidebarGripView { return grip }
        for sub in view.subviews {
            if let found = grip(in: sub) { return found }
        }
        return nil
    }
}
