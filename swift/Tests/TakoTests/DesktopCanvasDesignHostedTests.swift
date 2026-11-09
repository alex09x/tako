/*
 * tako — Live hosted canvas tests: controller transitions, mounted frames, identity, icon hits
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation
import Testing
@testable import Tako

extension DesktopCanvasDesignTests {
    @Suite(.serialized)
    @MainActor
    struct Hosted {
        private let canvasWidth: CGFloat = 1000
        private let height: CGFloat = 700

        private func makeWindow() -> (TerminalController, TerminalWindow) {
            TerminalTestSupport.preventQuitting()
            let sidebar = SessionSidebarWidth.current()
            let controller = TerminalController(Tako.App())
            let window = TerminalWindow(
                contentRect: NSRect(x: 0, y: 0, width: canvasWidth + sidebar, height: height),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            controller.window = window
            window.windowController = controller
            controller.windowDidLoad()
            controller.floatingCanvas.reduceMotionProvider = { true }
            window.setFrame(NSRect(x: 80, y: 80, width: canvasWidth + sidebar, height: height), display: true)
            controller.showWindow(nil)
            return (controller, window)
        }

        private func settle(_ window: NSWindow) {
            for _ in 0..<3 {
                window.contentView?.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.04))
            }
        }

        private func find(_ id: String, in view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == id { return view }
            for sub in view.subviews { if let hit = find(id, in: sub) { return hit } }
            return nil
        }

        /// Mounted frame in canvas coordinates (top-left origin, right of the sidebar).
        private func mounted(_ id: String, _ window: NSWindow) -> CGRect? {
            guard let content = window.contentView, let view = find(id, in: content) else { return nil }
            let r = view.convert(view.bounds, to: nil)
            let h = content.bounds.height
            return CGRect(x: r.minX - SessionSidebarWidth.current(), y: h - r.maxY, width: r.width, height: r.height)
        }

        private func key(_ s: Tako.SurfaceView) -> String { s.id.uuidString.lowercased() }

        private func close(_ a: CGRect?, _ b: CGRect?) -> Bool {
            guard let a, let b else { return false }
            return abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2
                && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
        }

        private func expectMountedMatchesStore(_ c: TerminalController, _ w: NSWindow,
                                               _ surfaces: [Tako.SurfaceView]) {
            let size = CGSize(width: canvasWidth, height: w.contentView!.bounds.height)
            let frames = c.floatingCanvas.presentedFrames(in: size)
            for s in surfaces where !c.floatingCanvas.isMinimized(s.id) {
                let live = mounted("FloatingPane-\(key(s))", w)
                #expect(close(live, frames[s.id]), "pane \(key(s)) mounted \(String(describing: live)) vs \(String(describing: frames[s.id]))")
            }
        }

        @Test func liveTileFloatMinimizeKeepsIdentityFocusAndMountedFrames() throws {
            let (c, w) = makeWindow()
            defer { w.close(); TerminalTestSupport.tearDown(c, w) }
            let p1 = try #require(c.focusedSurface)
            let p2 = try #require(c.newSplit(at: p1, direction: .right))
            let p3 = try #require(c.newSplit(at: p2, direction: .down))
            let ptys = [p1, p2, p3].map { $0.pty.map(ObjectIdentifier.init) }
            settle(w)
            let store = c.floatingCanvas
            #expect([p1, p2, p3].allSatisfy { store.isTiled($0.id) && store.state(for: $0.id)?.mode == .normal })

            // All three tiled with 8pt gaps inside the 8pt-inset grid.
            let f1 = try #require(mounted("FloatingPane-\(key(p1))", w))
            let f2 = try #require(mounted("FloatingPane-\(key(p2))", w))
            let f3 = try #require(mounted("FloatingPane-\(key(p3))", w))
            #expect(abs(f1.minX - 8) <= 2 && abs(f1.minY - 8) <= 2)
            #expect(abs(f2.minX - f1.maxX - 8) <= 2)
            #expect(abs(f3.minY - f2.maxY - 8) <= 2)
            expectMountedMatchesStore(c, w, [p1, p2, p3])

            // Detach p2 through its real header icon.
            let icon = try #require(find("FloatingPaneFloat-\(key(p2))", in: w.contentView!))
            #expect(icon.accessibilityPerformPress())
            settle(w)
            #expect(!store.isTiled(p2.id))
            #expect(c.focusedSurface === p2)
            let preferred = try #require(store.state(for: p2.id)?.rect)
            let floated = try #require(mounted("FloatingPane-\(key(p2))", w))
            let size = CGSize(width: canvasWidth, height: w.contentView!.bounds.height)
            #expect(close(floated, FloatingPaneGeometry.clamp(preferred, to: CGRect(origin: .zero, size: size))))
            // Remaining tiles reflow without the floating pane.
            let g1 = try #require(mounted("FloatingPane-\(key(p1))", w))
            let g3 = try #require(mounted("FloatingPane-\(key(p3))", w))
            #expect(abs(g3.minX - g1.maxX - 8) <= 2 && abs(g3.height - g1.height) <= 2)
            expectMountedMatchesStore(c, w, [p1, p2, p3])

            // Minimize p3: excluded from tiling, p1 takes the whole grid.
            c.minimizeFloatingPane(p3)
            settle(w)
            #expect(mounted("FloatingPane-\(key(p3))", w) == nil)
            expectMountedMatchesStore(c, w, [p1, p2, p3])

            // Return p2 to the grid and detach again: preferred rect survives.
            c.togglePaneFloating(p2)
            settle(w)
            #expect(store.isTiled(p2.id) && c.focusedSurface === p2)
            c.togglePaneFloating(p2)
            #expect(store.state(for: p2.id)?.rect == preferred)
            c.togglePaneFloating(p2)

            // Maximize separately from the icon; restore returns to the tile.
            c.toggleMaximizeFloatingPane(p1)
            settle(w)
            let maxFrame = try #require(mounted("FloatingPane-\(key(p1))", w))
            #expect(abs(maxFrame.width - canvasWidth) <= 2 && abs(maxFrame.minX) <= 2)
            c.toggleMaximizeFloatingPane(p1)
            #expect(store.isTiled(p1.id) && store.state(for: p1.id)?.mode == .normal)
            c.revealAndFocusFloatingPane(p3)
            settle(w)
            expectMountedMatchesStore(c, w, [p1, p2, p3])

            // Same Surface objects and PTYs throughout.
            #expect(Array(c.surfaceTree).count == 3)
            #expect([p1, p2, p3].allSatisfy { s in c.surfaceTree.contains { $0 === s } })
            #expect([p1, p2, p3].map { $0.pty.map(ObjectIdentifier.init) } == ptys)
            #expect(c.focusedSurface === p3)
        }

        @Test func iconHitTargetsDoNotOverlapResizeOrTopMargin() throws {
            let (c, w) = makeWindow()
            defer { w.close(); TerminalTestSupport.tearDown(c, w) }
            let p1 = try #require(c.focusedSurface)
            let p2 = try #require(c.newSplit(at: p1, direction: .right))
            c.togglePaneFloating(p2)
            settle(w)
            let content = try #require(w.contentView)
            let paneRect = try #require(find("FloatingPane-\(key(p2))", in: content))
            let paneFrame = paneRect.convert(paneRect.bounds, to: nil)
            for name in ["FloatingPaneFloat", "FloatingPaneMinimize", "FloatingPaneMaximize", "FloatingPaneClose"] {
                let button = try #require(find("\(name)-\(key(p2))", in: content), "\(name) missing")
                let f = button.convert(button.bounds, to: nil)
                #expect(abs(f.width - 22) <= 0.5 && abs(f.height - 22) <= 0.5, "\(name) \(f)")
                #expect(abs(paneFrame.maxY - f.maxY - 3) <= 0.5, "\(name) top margin \(paneFrame.maxY - f.maxY)")
                let hit = content.superview!.hitTest(NSPoint(x: f.midX, y: f.midY))
                var node = hit
                while let n = node, n !== button { node = n.superview }
                #expect(node === button, "\(name) hit \(String(describing: hit))")
                for edge in FloatingPaneResizeEdge.allCases {
                    if let handle = find("FloatingPaneResize-\(edge.rawValue)-\(key(p2))", in: content) {
                        #expect(!handle.convert(handle.bounds, to: nil).intersects(f), "\(edge) overlaps \(name)")
                    }
                }
            }
            #expect(FloatingPaneResizeHandlesView.topEdgeHitThickness == 3)
            let top = try #require(find("FloatingPaneResize-top-\(key(p2))", in: content))
            #expect(top.bounds.height == 3)
            // The icon flips the grid/floating mode and its AX value.
            let icon = try #require(find("FloatingPaneFloat-\(key(p2))", in: content))
            #expect(icon.accessibilityValue() as? String == "floating")
            #expect(icon.accessibilityPerformPress())
            settle(w)
            #expect(c.floatingCanvas.isTiled(p2.id))
            let back = try #require(find("FloatingPaneFloat-\(key(p2))", in: content))
            #expect(back.accessibilityValue() as? String == "tiled")
        }

        @Test func oldV1SnapshotRestoresFloatingModesAndV2KeepsGrid() throws {
            let (c, w) = makeWindow()
            defer { w.close(); TerminalTestSupport.tearDown(c, w) }
            let p1 = try #require(c.focusedSurface)
            let p2 = try #require(c.newSplit(at: p1, direction: .right))
            let p3 = try #require(c.newSplit(at: p2, direction: .down))
            let rect = CGRect(x: 40, y: 30, width: 400, height: 300)
            let v1 = FloatingCanvasSnapshot(panes: [
                FloatingPaneState(surfaceId: p1.id, mode: .normal, rect: rect, zOrder: 1),
                FloatingPaneState(surfaceId: p2.id, mode: .maximized, rect: rect, zOrder: 2),
                FloatingPaneState(surfaceId: p3.id, mode: .minimized, restoreMode: .maximized, rect: rect, zOrder: 3),
            ])
            // Old JSON has no "tiled" key.
            let json = try JSONEncoder().encode(v1)
            #expect(!(String(data: json, encoding: .utf8) ?? "").contains("tiled"))
            let decoded = try JSONDecoder().decode(FloatingCanvasSnapshot.self, from: json)
            let store = c.floatingCanvas
            store.loadRestoredSnapshot(decoded, for: c.surfaceTree, fallbackSize: CGSize(width: canvasWidth, height: 600))
            #expect(store.tiledIds.isEmpty)
            #expect(store.presentation(of: store.state(for: p1.id)!).mode == .floating)
            #expect(store.state(for: p2.id)?.mode == .maximized)
            #expect(store.state(for: p3.id)?.mode == .minimized)
            settle(w)
            let size = CGSize(width: canvasWidth, height: w.contentView!.bounds.height)
            let area = FloatingPaneGeometry.workArea(in: size, hasMinimizedPanes: true)
            #expect(close(mounted("FloatingPane-\(key(p2))", w), area)) // sole maximized fills work area
            #expect(store.restore(p3.id) == .maximized)
            #expect(store.presentationSnapshot().pane(p1.id)?.preferredRect == rect)

            // v2 round trip keeps grid membership.
            c.togglePaneFloating(p1)
            #expect(store.isTiled(p1.id))
            let saved = try JSONDecoder().decode(FloatingCanvasSnapshot.self, from: JSONEncoder().encode(store.snapshot()))
            store.loadRestoredSnapshot(nil, for: SplitTree<Tako.SurfaceView>(), fallbackSize: nil)
            store.loadRestoredSnapshot(saved, for: c.surfaceTree, fallbackSize: nil)
            #expect(store.isTiled(p1.id) && !store.isTiled(p2.id))
            #expect(c.surfaceTree.contains { $0 === p1 })
        }
    }
}
