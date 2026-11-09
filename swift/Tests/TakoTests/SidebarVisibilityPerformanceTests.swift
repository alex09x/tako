/*
 * tako — Hidden session windows do not keep rendering a duplicate sidebar
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Testing
@testable import Tako

@MainActor @Suite(.serialized)
struct SidebarVisibilityPerformanceTests {
    @Test func searchFieldAndQueryRemainMountedWhileTheHiddenListIsSuspended() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer {
            SessionSidebarStore.shared.setFilterText("", for: window)
            window.close(); TerminalTestSupport.tearDown(controller, window)
        }
        window.setContentSize(NSSize(width: 1280, height: 700))
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        let content = try #require(window.contentView)
        func field(_ root: NSView) -> SidebarSearchNSTextField? {
            (root as? SidebarSearchNSTextField) ?? root.subviews.lazy.compactMap(field).first
        }
        #expect(TerminalTestSupport.waitUntil { content.layoutSubtreeIfNeeded(); return field(content) != nil })
        SessionSidebarStore.shared.setFilterText("saved query", for: window)
        let initial = try #require(field(content))
        #expect(window.makeFirstResponder(initial))
        #expect((window.firstResponder as? NSTextView)?.delegate === initial)
        window.orderOut(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        window.makeKeyAndOrderFront(nil)
        #expect(TerminalTestSupport.waitUntil { content.layoutSubtreeIfNeeded(); return field(content) != nil })
        #expect(field(content) === initial, "Hiding a list must not replace the native search editor")
        #expect(field(content)?.stringValue == "saved query")
    }

    @Test func presentationObservesWindowOrderingEvenWhenTheSwiftUIViewIsSuspended() {
        let w = TerminalWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        defer { w.close() }
        let presentation = TerminalWindowPresentation()
        presentation.bind(to: w)
        #expect(!presentation.isVisible)
        w.orderFrontRegardless()
        #expect(TerminalTestSupport.waitUntil { presentation.isVisible })
        w.orderOut(nil)
        #expect(TerminalTestSupport.waitUntil { !presentation.isVisible })
        w.orderFrontRegardless()
        #expect(TerminalTestSupport.waitUntil { presentation.isVisible })
    }

    @Test func hiddenWindowStopsBuildingSidebarContentAndRestoresRowsWithoutStealingFocus() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        window.setContentSize(NSSize(width: 1280, height: 700))
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        let surface = try #require(controller.focusedSurface)
        let pty = surface.pty
        let content = try #require(window.contentView)
        var builds = 0
        SessionSidebarView.onContentBuildForTesting = { if $0 === window { builds += 1 } }
        defer { SessionSidebarView.onContentBuildForTesting = nil }
        func settle() {
            content.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            content.layoutSubtreeIfNeeded()
        }
        func rowHosts(_ root: NSView) -> Int {
            let own = String(describing: type(of: root)).hasPrefix("SidebarRowAXContainerNSView") ? 1 : 0
            return own + root.subviews.reduce(0) { $0 + rowHosts($1) }
        }
        settle()
        #expect(window.isVisible && rowHosts(content) > 0)
        window.orderOut(nil)
        settle()
        #expect(!window.isVisible)
        let hiddenBuilds = builds
        surface.crab.setStatus(.working, text: "working")
        for _ in 0..<10 { SessionSidebarStore.shared.objectWillChange.send(); settle() }
        #expect(builds == hiddenBuilds, "A hidden tab must not rebuild rows, menus and notification subscriptions")
        #expect(controller.surfaceTree.contains(surface) && surface.pty === pty)
        #expect(surface.crab.paneStatus == .working)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(surface)
        settle()
        _ = TerminalTestSupport.waitUntil { rowHosts(content) > 0 }
        #expect(rowHosts(content) > 0)
        #expect(window.firstResponder === surface, "Remounting navigation must not steal terminal input")
        #expect(controller.surfaceTree.contains(surface) && surface.pty === pty)
    }
}
