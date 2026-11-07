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

private final class FullscreenStubTerminalWindow: TerminalWindow {
    var simulatedFullScreen = false
    override var styleMask: NSWindow.StyleMask {
        get { simulatedFullScreen ? super.styleMask.union([.fullScreen]) : super.styleMask }
        set { super.styleMask = newValue.subtracting([.fullScreen]) }
    }
}

@Suite(.serialized)
@MainActor
struct PermanentSidebarLayoutTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "test.tako.permanent-sidebar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func findFirst<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for sub in root.subviews {
            if let found = findFirst(of: type, in: sub) { return found }
        }
        return nil
    }

    @Test func permanentSidebarCannotBeHiddenViaStoreDefaultsActionsOrMenus() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: SessionSidebarStore.isShowingKey)
        let store = SessionSidebarStore(defaults: defaults)
        #expect(store.isShowing)

        store.isShowing = false
        #expect(store.isShowing)
        #expect(defaults.bool(forKey: SessionSidebarStore.isShowingKey))

        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }

        #expect(controller.supportsSessionSidebar)
        #expect(controller.sessionSidebarIsShowing)

        controller.sessionSidebarIsShowing = false
        #expect(controller.sessionSidebarIsShowing)

        controller.toggleSessionSidebar(nil)
        #expect(controller.sessionSidebarIsShowing)

        let sidebarMenuItem = NSMenuItem(
            title: "Session Sidebar",
            action: #selector(BaseTerminalController.toggleSessionSidebar(_:)),
            keyEquivalent: "s"
        )
        #expect(controller.validateMenuItem(sidebarMenuItem) == false)

        let delegate = AppDelegate()
        let delegateItem = NSMenuItem(
            title: "Session Sidebar",
            action: #selector(AppDelegate.toggleSessionSidebar(_:)),
            keyEquivalent: "s"
        )
        #expect(delegate.validateMenuItem(delegateItem) == false)
        delegate.toggleSessionSidebar(nil)
        #expect(controller.sessionSidebarIsShowing)

        let mainMenu = NSMenu(title: "Main")
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let viewSubmenu = NSMenu(title: "View")
        viewSubmenu.addItem(sidebarMenuItem)
        viewItem.submenu = viewSubmenu
        mainMenu.addItem(viewItem)
        let previousMenu = NSApp.mainMenu
        NSApp.mainMenu = mainMenu
        defer { NSApp.mainMenu = previousMenu }

        delegate.setupSidebarMenuItem()
        #expect(viewSubmenu.items.contains { $0.action == #selector(BaseTerminalController.toggleSessionSidebar(_:)) } == false)

        // Split resize handle cannot collapse sidebar width to zero or negative.
        #expect(SessionSidebarWidth.clamped(0) == SessionSidebarWidth.range.lowerBound)
        #expect(SessionSidebarWidth.clamped(-120) == SessionSidebarWidth.range.lowerBound)
        #expect(SessionSidebarWidth.clamped(2000) == SessionSidebarWidth.range.upperBound)
        #expect(SessionSidebarWidth.range.lowerBound > 0)
    }

    @Test func quickTerminalDoesNotShowPermanentSessionSidebar() {
        TerminalTestSupport.preventQuitting()
        let app = Tako.App()
        let quick = QuickTerminalController(app, position: .top)
        #expect(!quick.supportsSessionSidebar)
        #expect(!quick.sessionSidebarIsShowing)

        quick.sessionSidebarIsShowing = true
        #expect(!quick.sessionSidebarIsShowing)

        quick.toggleSessionSidebar(nil)
        #expect(!quick.sessionSidebarIsShowing)
    }

    @Test func desktopWindowHasNoTopTabBarAndRightTerminalExtendsToTopEdge() throws {
        TerminalTestSupport.preventQuitting()
        let app = Tako.App()
        let controller = TerminalController(app, withBaseConfig: nil, withSurfaceTree: nil)
        let window = FullscreenStubTerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        controller.window = window
        controller.windowDidLoad()
        defer { TerminalTestSupport.tearDown(controller, window) }

        let contentView = try #require(window.contentView)
        contentView.frame = NSRect(x: 0, y: 0, width: 960, height: 600)
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        contentView.layoutSubtreeIfNeeded()

        // No visual top tab strip exists anywhere in the window.
        #expect(findFirst(of: Tako.TabBarView.self, in: contentView) == nil)
        #expect(Tako.TabBarController.bar(for: window) == nil)
        #expect(Tako.TabBarController.contentTopInset(for: window) == 0)

        if let themeFrame = contentView.superview,
           let titlebarContainer = themeFrame.firstDescendant(withClassName: "NSTitlebarContainerView") {
            #expect(titlebarContainer.layer?.backgroundColor == NSColor.clear.cgColor)
            #expect(titlebarContainer.layer?.isOpaque == false)
        }

        let surface = try #require(findFirst(of: Tako.SurfaceView.self, in: contentView))
        let surfaceRect = surface.convert(surface.bounds, to: contentView)
        let contentBounds = contentView.bounds

        // Right terminal occupies the full height right up to the top edge of the window.
        #expect(abs(surfaceRect.maxY - contentBounds.maxY) < 1.5,
                "terminal maxY=\(surfaceRect.maxY) must reach contentView maxY=\(contentBounds.maxY)")
        #expect(abs(surfaceRect.minY - contentBounds.minY) < 1.5)
        #expect(surfaceRect.minX >= SessionSidebarWidth.range.lowerBound - 1.5)

        // Left sidebar drag strip and resize handle expose stable AppKit AX identifiers and frames.
        let dragStrip = try #require(findFirst(of: SidebarTitlebarDragView.self, in: contentView))
        #expect(dragStrip.accessibilityIdentifier() == "SidebarWindowDragRegion")
        #expect(dragStrip.accessibilityRole() == .group)
        let gripView = try #require(findFirst(of: SessionSidebarGripView.self, in: contentView))
        #expect(gripView.accessibilityIdentifier() == "SessionSidebarResizeHandle")
        #expect(gripView.accessibilityRole() == .splitter)
        let gripRect = gripView.convert(gripView.bounds, to: contentView)
        #expect(gripRect.width == SessionSidebarResizeHandle.hitWidth)
        #expect(gripRect.height > 100)

        let dragRect = dragStrip.convert(dragStrip.bounds, to: contentView)
        #expect(abs(dragRect.height - SessionSidebarChrome.titlebarStripHeight) < 1.0)
        #expect(abs(dragRect.maxY - contentBounds.maxY) < 1.5)
        #expect(dragRect.maxX <= surfaceRect.minX + 1.5)

        #expect(SessionSidebarChrome.showsTitlebarStrip(for: window) == true)
        window.simulatedFullScreen = true
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        contentView.layoutSubtreeIfNeeded()
        #expect(SessionSidebarChrome.showsTitlebarStrip(for: window) == false)
        #expect(SessionSidebarChrome.topStripHeight(for: window) == 0)
        #expect(findFirst(of: SidebarTitlebarDragView.self, in: contentView) == nil)
        window.simulatedFullScreen = false
    }

    @Test func sidebarSessionLifecycleCreateSwitchAndSingleTabClosePreservesTabGroup() throws {
        let previousSystem = TerminalController.system
        let previousSuppress = Tako.CustomTabGroup.suppressWindowOrderingForTesting
        TerminalController.system = TerminalTestSupport.injectedWindowSystem()
        Tako.CustomTabGroup.suppressWindowOrderingForTesting = true
        defer {
            TerminalController.system = previousSystem
            Tako.CustomTabGroup.suppressWindowOrderingForTesting = previousSuppress
        }

        let defaults = makeDefaults()
        let store = SessionSidebarStore(defaults: defaults)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tako-perm-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wsStore = WorkspaceStore(storeURL: dir.appendingPathComponent("workspaces.json"), isTesting: true)
        wsStore.resetForTesting()

        let (c1, w1) = TerminalTestSupport.loaded()
        Tako.TabBarController.install(in: w1)
        wsStore.assignTab(tabIdentifier: w1.stableTabIdentifier, to: wsStore.activeWorkspaceId)

        // Create second session from sidebar action.
        store.createNewTab(in: w1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let group = Tako.CustomTabGroup.group(for: w1)
        #expect(group.windows.count == 2)
        let w2 = try #require(group.windows.first { $0 !== w1 })
        Tako.TabBarController.install(in: w2)
        wsStore.assignTab(tabIdentifier: w2.stableTabIdentifier, to: wsStore.activeWorkspaceId)

        defer {
            Tako.CustomTabGroup.leave(w2)
            Tako.CustomTabGroup.leave(w1)
            w2.orderOut(nil)
            w1.orderOut(nil)
        }

        // Switch back to first session via sidebar item selection.
        let itemsBefore = store.workspaceGroups(for: w1, workspaceStore: wsStore).flatMap(\.items)
        let firstItem = try #require(itemsBefore.first { $0.tabId == w1.stableTabIdentifier && !$0.isChild })
        let secondItem = try #require(itemsBefore.first { $0.tabId == w2.stableTabIdentifier && !$0.isChild })

        store.selectTab(item: firstItem, in: w1, workspaceStore: wsStore)
        #expect(group.selectedWindow === w1)

        // Keyboard tab navigation still works without TabBarView.
        c1.nextTab(nil)
        #expect(group.selectedWindow === w2)
        if let c2 = w2.windowController as? TerminalController {
            c2.previousTab(nil)
            #expect(group.selectedWindow === w1)
        }

        // Closing second session from sidebar closes ONLY w2 and keeps w1 open.
        store.closeTab(item: secondItem, in: w1)
        #expect(group.windows == [w1])
        #expect(group.selectedWindow === w1)

        // Footer SessionSidebarNewSession button action resolves containingWindow and creates a new session.
        let sidebarView = SessionSidebarView(
            isPresented: .constant(true),
            containingWindow: w1,
            store: store,
            workspaceStore: wsStore
        )
        #expect(sidebarView.newSessionHint.contains("New session"))
        sidebarView.triggerNewSession()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(group.windows.count == 2)
        if let w3 = group.windows.first(where: { $0 !== w1 }) {
            Tako.CustomTabGroup.leave(w3)
            w3.orderOut(nil)
        }
    }
}
