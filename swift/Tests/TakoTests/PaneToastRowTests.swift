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

/// A toast is one row high, however tall the window it lies over: the stack
/// is an overlay across the whole terminal, which offers it the full height.
/// A toast once stretched to it and slid in as a full-height panel.
@Suite @MainActor
struct PaneToastRowTests {
    @Test func aToastIsOneRowHighInATallWindow() {
        for message in ["", "The command exited with an error"] {
            let toast = PaneToast(id: UUID(), surfaceID: UUID(), state: .done, headline: "muse — done",
                                  message: message, place: "in the background")
            let host = NSHostingController(rootView: PaneToastRow(toast: toast, open: {}).frame(width: 300))
            let height = host.sizeThatFits(in: CGSize(width: 300, height: 800)).height
            #expect(height > 20 && height < 120, "a toast \(message.isEmpty ? "without" : "with") a message is \(height) pt high in an 800 pt window")
        }
    }

    @Test func aToastNativeButtonIsAccessibleAndUsesTheCurrentAction() async throws {
        _ = NSApplication.shared
        let pane = UUID(), toastID = UUID()
        let identifier = "PaneToast-\(pane.uuidString.lowercased())"
        var opened: [String] = []
        func row(_ headline: String) -> some View {
            PaneToastRow(toast: PaneToast(id: toastID, surfaceID: pane, state: .done,
                                         headline: headline, message: "", place: "minimized"),
                         open: { opened.append(headline) })
                .frame(width: 300)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        // The real titlebar-band HID regression is DesktopToastUITests. This
        // offscreen host materializes the native bridge and tests its updates.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: row("first"))
        window.contentView = host
        func draw() throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        func target(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.accessibilityIdentifier() == identifier { return button }
            for child in view.subviews { if let found = target(in: child) { return found } }
            return nil
        }
        try draw()
        let first = try #require(target(in: host), "a native click target, not only a SwiftUI gesture")
        #expect(first.accessibilityRole() == .button)
        #expect(first.accessibilityLabel()?.contains("first") == true)
        #expect(first.bounds.width == 300 && first.bounds.height > 20)
        first.performClick(nil)
        #expect(opened == ["first"])

        host.rootView = row("updated")
        try await Task.sleep(for: .milliseconds(30))
        try draw()
        let updated = try #require(target(in: host))
        #expect(updated.accessibilityLabel()?.contains("updated") == true)
        updated.performClick(nil)
        #expect(opened == ["first", "updated"], "a reused native target must open the current toast")
    }
}
