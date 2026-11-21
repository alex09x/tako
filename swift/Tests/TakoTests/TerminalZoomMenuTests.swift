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

/// A terminal's temporary zoom (reference A07 and its terminal menu): “Zoom In”,
/// “Zoom Out”, “Reset Zoom” change only this terminal, 4–255 pt, never
/// the saved base size, and say so to Settings' “Current Zoom”.
@Suite(.serialized) @MainActor
struct TerminalZoomMenuTests {
    private func run(_ items: [NSMenuItem], _ id: String) {
        guard let item = items.first(where: { $0.identifier?.rawValue == id }), let action = item.action else {
            Issue.record("no \(id)"); return
        }
        _ = (item.target as? NSObject)?.perform(action, with: item)
    }

    @Test func theTerminalMenuZoomsThisTerminalOnlyAndResets() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        let surface = try #require(controller.focusedSurface)
        let base = surface.fontBaseSize
        var notes = 0
        let token = NotificationCenter.default.addObserver(forName: .takoSurfaceZoomDidChange, object: surface, queue: nil) { _ in
            MainActor.assumeIsolated { notes += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
                                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 1, clickCount: 1, pressure: 1))
        let menu = try #require(surface.menu(for: event))
        let ids = menu.items.compactMap { $0.identifier?.rawValue }
        #expect(ids.contains("TerminalZoomIn") && ids.contains("TerminalZoomOut") && ids.contains("TerminalZoomReset"))
        let selectAll = try #require(menu.items.firstIndex { $0.action == #selector(NSText.selectAll(_:)) })
        let zoomIn = try #require(menu.items.firstIndex { $0.identifier?.rawValue == "TerminalZoomIn" })
        #expect(zoomIn > selectAll, "zoom is not after «Select All»")
        #expect(menu.items.first { $0.identifier?.rawValue == "TerminalZoomReset" }?.isEnabled == false)

        run(menu.items, "TerminalZoomIn")
        run(menu.items, "TerminalZoomIn")
        #expect(surface.fontZoomDelta == 2 && surface.theme.fontSize == base + 2 && surface.fontBaseSize == base)
        #expect(notes == 2)
        #expect(surface.zoomMenuItems().first { $0.identifier?.rawValue == "TerminalZoomReset" }?.isEnabled == true)
        #expect(DesktopPaneZoomRow.describe(delta: surface.fontZoomDelta, effective: surface.theme.fontSize)
                .hasPrefix("+2 pt — displayed at \(DesktopStepper.render(Double(base + 2))) pt"))

        run(surface.zoomMenuItems(), "TerminalZoomReset")
        #expect(surface.fontZoomDelta == 0 && surface.theme.fontSize == base)

        for _ in 0..<300 { surface.changeFontSize(.decrease(1)) }
        #expect(surface.theme.fontSize == 4, "the zoom went below 4 pt: \(surface.theme.fontSize)")
        surface.changeFontSize(.reset)
        #expect(DesktopPaneZoomRow.describe(delta: 0, effective: base).hasPrefix("No temporary zoom."))
    }
}
