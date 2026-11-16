/*
 * tako — Desktop canvas overlays and sidebar menu wiring
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI
import Testing
@testable import Tako

@Suite(.serialized) @MainActor
struct CanvasOverlayRegressionTests {
    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { views(type, in: $0) }
    }

    private func wait(_ root: NSView, until predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            root.layoutSubtreeIfNeeded()
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return predicate()
    }

    @Test func aCanvasCommandPaletteMountsForTheControllersInitialFocus() async throws {
        let fixture = try PrivateSurfaceFixture()
        defer { fixture.cleanUp() }
        let surface = fixture.surface()
        let (controller, window) = TerminalTestSupport.loaded(baseConfig: fixture.configuration,
                                                            surfaceTree: .init(view: surface))
        defer { TerminalTestSupport.tearDown(controller, window) }
        controller.tako.readiness = .ready
        window.setContentSize(CGSize(width: 800, height: 600))
        #expect(controller.usesFloatingCanvas)
        #expect(controller.focusedSurface === surface)
        let root = try #require(window.contentView)
        #expect(await wait(root) {
            views(NSTextField.self, in: root).contains { $0.accessibilityIdentifier() == "SessionSidebarSearchField" }
        }, "the real terminal view must be mounted before toggling its palette")
        let existing = Set(views(NSTextField.self, in: root).map(ObjectIdentifier.init))
        controller.toggleCommandPalette(nil)
        #expect(controller.commandPaletteIsShowing)
        #expect(await wait(root) {
            views(NSTextField.self, in: root).contains { !existing.contains(ObjectIdentifier($0)) }
        }, "the palette must mount its query field without a SwiftUI focus-value change")
        controller.toggleCommandPalette(nil)
        #expect(await wait(root) {
            views(NSTextField.self, in: root).allSatisfy { existing.contains(ObjectIdentifier($0)) }
        }, "closing the palette removes its query field")
    }

    @Test func theSidebarPlusOpensItsMenuOnThePress() async throws {
        let fixture = try PrivateSurfaceFixture()
        defer { fixture.cleanUp() }
        let (controller, window) = TerminalTestSupport.loaded(baseConfig: fixture.configuration,
                                                            surfaceTree: .init(view: fixture.surface()))
        defer { TerminalTestSupport.tearDown(controller, window) }
        let sidebar = SessionSidebarView(isPresented: .constant(true), containingWindow: window)
        let host = NSHostingView(rootView: sidebar.headerView(sessionCount: 1, attentionCount: 0))
        host.frame = CGRect(x: 0, y: 0, width: 260, height: 32)
        let container = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        container.isReleasedWhenClosed = false
        container.contentView = host
        defer { container.close() }
        #expect(await wait(host) {
            views(FloatingActionButtonNSView.self, in: host).contains {
                $0.accessibilityIdentifier() == "SessionSidebarHeaderNewSession"
            }
        })
        let button = try #require(views(FloatingActionButtonNSView.self, in: host).first {
            $0.accessibilityIdentifier() == "SessionSidebarHeaderNewSession"
        })
        let menu = try #require(button.menuProvider?(), "the existing mouseDown menu primitive must own the popup")
        #expect(menu.items.contains { $0.title == "New Session" })
        #expect(menu.items.contains { $0.title == "New Terminal to the Right" })
        #expect(menu.items.contains { $0.title == "New Workspace" })
    }
}
