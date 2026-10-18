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

/// A click on the sidebar of a window in the background is the row's click,
/// not only the window's activation.
@Suite @MainActor
struct SessionSidebarFirstClickTests {
    private final class TakesFirstClick: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private func window() -> (NSWindow, SessionSidebarGripView, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let rows = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
        let grip = SessionSidebarGripView(frame: NSRect(x: 272, y: 0, width: 12, height: 400))
        let button = TakesFirstClick(frame: NSRect(x: 10, y: 370, width: 40, height: 20))
        root.addSubview(rows)
        root.addSubview(button)
        root.addSubview(grip)
        window.contentView = root
        return (window, grip, root)
    }

    private func click(_ x: CGFloat, _ y: CGFloat, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                           pressure: 1)!
    }

    @Test func aRowOfTheSidebarTakesTheFirstClick() {
        let (window, _, _) = window()
        #expect(SessionSidebarFirstClick.wants(click(100, 200, in: window), in: window))
    }

    @Test func theTerminalAndWhatTakesItAnywayAreLeftAlone() {
        let (window, _, _) = window()
        // Right of the sidebar: the terminal decides for itself.
        #expect(!SessionSidebarFirstClick.wants(click(500, 200, in: window), in: window))
        // The grip and a view that takes the first click already need nothing.
        #expect(!SessionSidebarFirstClick.wants(click(278, 200, in: window), in: window))
        #expect(!SessionSidebarFirstClick.wants(click(20, 380, in: window), in: window))
    }

    @Test func noSidebarShownNoFirstClick() {
        let (window, grip, _) = window()
        grip.isHidden = true
        #expect(!SessionSidebarFirstClick.wants(click(100, 200, in: window), in: window))
        grip.removeFromSuperview()
        #expect(!SessionSidebarFirstClick.wants(click(100, 200, in: window), in: window))
    }
}
