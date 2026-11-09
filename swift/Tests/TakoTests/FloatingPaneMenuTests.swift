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

/// The pane header's right-click menu (reference header.js winMenu) runs the
/// pane's real actions: a split beside it, maximize, float, minimize, close.
@Suite(.serialized) @MainActor
struct FloatingPaneMenuTests {
    private func run(_ items: [NSMenuItem], _ id: String) {
        guard let item = items.first(where: { $0.identifier?.rawValue == id }), let action = item.action else {
            Issue.record("no \(id)"); return
        }
        _ = (item.target as? NSObject)?.perform(action, with: item)
    }

    @Test func titlesAndSplitFollowTheMode() {
        _ = NSApplication.shared
        var log: [String] = []
        func menu(_ mode: FloatingPaneMode, tiled: Bool) -> FloatingPaneMenu {
            FloatingPaneMenu(mode: mode, isTiled: tiled, split: { log.append("split \($0)") },
                             toggleMaximize: { log.append("max") }, toggleFloating: { log.append("float") },
                             minimize: { log.append("min") }, close: { log.append("close") })
        }
        let tiled = menu(.normal, tiled: true).items()
        #expect(tiled.filter { !$0.isSeparatorItem }.map(\.title)
                == ["Rename…", "Split Right", "Split Down", "Maximize", "Float Terminal", "Minimize", "Close Terminal"])
        #expect(tiled.first { $0.identifier?.rawValue == "FloatingPaneMenuSplitRight" }?.isEnabled == true)
        for id in ["FloatingPaneMenuSplitRight", "FloatingPaneMenuSplitDown", "FloatingPaneMenuMaximize",
                   "FloatingPaneMenuFloat", "FloatingPaneMenuMinimize", "FloatingPaneMenuClose"] { run(tiled, id) }
        #expect(log == ["split right", "split down", "max", "float", "min", "close"])

        let free = menu(.normal, tiled: false)
        #expect(free.floatTitle == "Return to Grid")
        #expect(free.items().first { $0.identifier?.rawValue == "FloatingPaneMenuSplitRight" }?.isEnabled == false,
                "a free-floating pane offers to split")
        #expect(menu(.maximized, tiled: false).maximizeTitle == "Restore")
    }

    @Test func theHeaderMenuSplitsAndMinimizesTheRealPane() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        window.setContentSize(NSSize(width: 1000 + SessionSidebarWidth.current(), height: 700))
        controller.showWindow(nil)
        let p1 = try #require(controller.focusedSurface)
        let p2 = try #require(controller.newSplit(at: p1, direction: .right))
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        func header(_ p: Tako.SurfaceView) throws -> FloatingPaneHeaderDragNSView {
            func find(_ v: NSView) -> FloatingPaneHeaderDragNSView? {
                if let h = v as? FloatingPaneHeaderDragNSView,
                   h.accessibilityIdentifier() == "FloatingPaneHeader-\(p.id.uuidString.lowercased())" { return h }
                for s in v.subviews { if let hit = find(s) { return hit } }
                return nil
            }
            return try #require(find(content))
        }
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                                     clickCount: 1, pressure: 1))
        let before = Array(controller.surfaceTree).count
        let items = try #require(try header(p2).menu(for: event)).items
        #expect(items.contains { $0.title == "Move Pane to New Window" }, "the existing items are gone")
        #expect(items.contains { $0.identifier?.rawValue == "FloatingPaneMenuSplitRight" })
        #expect(p2.window?.windowController === controller, "the pane's window is \(String(describing: p2.window))")
        run(items, "FloatingPaneMenuSplitRight")
        #expect(Array(controller.surfaceTree).count == before + 1)
        content.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let again = try #require(try header(p1).menu(for: event)).items
        run(again, "FloatingPaneMenuMinimize")
        TerminalTestSupport.waitUntil(timeout: 1) { controller.floatingCanvas.state(for: p1.id)?.mode == .minimized }
        #expect(controller.floatingCanvas.state(for: p1.id)?.mode == .minimized)
    }
}
