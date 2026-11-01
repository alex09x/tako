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

@MainActor
@Suite(.serialized)
struct SessionSidebarFrameTests {
    @Test func sidebarUsesTheSuppliedTerminalBackgroundInsideAndOutsideTheFrame() throws {
        let color = NSColor(srgbRed: 0.19, green: 0.27, blue: 0.35, alpha: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            SessionSidebarView(isPresented: .constant(true), backgroundColor: Color(nsColor: color))
                .frame(width: 280)
            Color(nsColor: color).frame(width: 100)
        })
        host.frame = NSRect(x: 0, y: 0, width: 380, height: 600)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let terminal = try #require(bitmap.colorAt(x: 330, y: 300)?.usingColorSpace(.sRGB))
        for point in [(2, 300), (140, 300)] {
            let pixel = try #require(bitmap.colorAt(x: point.0, y: point.1)?.usingColorSpace(.sRGB))
            #expect(abs(pixel.redComponent - terminal.redComponent) < 0.01)
            #expect(abs(pixel.greenComponent - terminal.greenComponent) < 0.01)
            #expect(abs(pixel.blueComponent - terminal.blueComponent) < 0.01)
        }
    }

    @Test func newSessionHintUsesTheConfiguredShortcut() {
        let shortcut = KeyboardShortcut("n", modifiers: [.command, .shift])
        let custom = SessionSidebarView(isPresented: .constant(true), newSessionShortcut: shortcut)
        let unbound = SessionSidebarView(isPresented: .constant(true), newSessionShortcut: nil)
        #expect(custom.newSessionHint == "[⇧⌘N]  New session")
        #expect(unbound.newSessionHint == "New session")
    }
}
