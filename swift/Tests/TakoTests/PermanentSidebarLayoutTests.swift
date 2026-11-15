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

    @Test func desktopWindowHasNoTopTabBarAndItsSoleTerminalIsTheInsetCard() throws {
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

        let paneHeader = try #require(findFirst(of: FloatingPaneHeaderDragNSView.self, in: contentView))
        let headerRect = paneHeader.convert(paneHeader.bounds, to: contentView)
        let surface = try #require(findFirst(of: Tako.SurfaceView.self, in: contentView))
        let surfaceRect = surface.convert(surface.bounds, to: contentView)
        let contentBounds = contentView.bounds

        // The canvas runs the window's full height; the tab's only terminal is the same card
        // a terminal among several gets: inset by the canvas gap, its header on top, and the
        // terminal inside the card's body margin.
        let gap = DesktopCanvasMetrics.paneGap
        let body = FloatingPaneGeometry.bodyInsets
        #expect(abs(headerRect.maxY - (contentBounds.maxY - gap)) < 0.5,
                "card header maxY=\(headerRect.maxY) must sit \(gap) pt below contentView maxY=\(contentBounds.maxY)")
        #expect(abs(surfaceRect.maxY - (contentBounds.maxY - gap - FloatingPaneGeometry.headerHeight - body.top)) < 0.5,
                "terminal maxY=\(surfaceRect.maxY) must start below the header and the body's top margin")
        #expect(abs(surfaceRect.minY - (contentBounds.minY + gap + body.bottom)) < 0.5,
                "terminal minY=\(surfaceRect.minY) must keep the gap and the body's bottom margin")
        #expect(abs(surfaceRect.maxX - (contentBounds.maxX - gap - body.right)) < 0.5,
                "terminal maxX=\(surfaceRect.maxX) must keep the gap and the body's right margin")
        #expect(surfaceRect.minX >= SessionSidebarWidth.range.lowerBound + gap + body.left - 0.5)

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
        // The whole 44 pt reference header (A01 `.sb-hd`) drags the window.
        #expect(abs(dragRect.height - SessionSidebarView.referenceHeaderHeight) < 1.0)
        #expect(abs(dragRect.maxY - contentBounds.maxY) < 1.5)
        #expect(dragRect.maxX <= surfaceRect.minX + 1.5)

        #expect(SessionSidebarChrome.showsTitlebarStrip(for: window) == true)
        let dragStripMounted = { () -> Bool in
            contentView.layoutSubtreeIfNeeded()
            return findFirst(of: SidebarTitlebarDragView.self, in: contentView) != nil
        }
        func fullScreen(_ on: Bool) {
            window.simulatedFullScreen = on
            NotificationCenter.default.post(
                name: on ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification,
                object: window)
        }

        // A hidden window's sidebar builds nothing and is not re-laid out on fullscreen
        // changes; it catches up when the window is shown.
        #expect(!window.isVisible, "this part runs while the window is hidden")
        fullScreen(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        #expect(SessionSidebarChrome.topStripHeight(for: window) == 0)
        #expect(dragStripMounted(), "a hidden sidebar is not rebuilt for a fullscreen change")
        fullScreen(false)

        // Shown -- ordered in without becoming key -- the sidebar follows fullscreen both ways.
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        #expect(TerminalTestSupport.waitUntil { window.isVisible && dragStripMounted() })
        fullScreen(true)
        #expect(SessionSidebarChrome.showsTitlebarStrip(for: window) == false)
        #expect(TerminalTestSupport.waitUntil { !dragStripMounted() },
                "a shown window in fullscreen has no titlebar strip to drag")
        fullScreen(false)
        #expect(TerminalTestSupport.waitUntil { dragStripMounted() },
                "leaving fullscreen brings the strip back")
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

        // The + menu's “New Session” resolves containingWindow and creates a new session.
        let sidebarView = SessionSidebarView(
            isPresented: .constant(true),
            containingWindow: w1,
            store: store,
            workspaceStore: wsStore
        )
        sidebarView.triggerNewSession()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(group.windows.count == 2)
        if let w3 = group.windows.first(where: { $0 !== w1 }) {
            Tako.CustomTabGroup.leave(w3)
            w3.orderOut(nil)
        }
    }

    @Test func multiWorkspaceSidebarGroupsMarkOnlyActiveWorkspaceForScopedTabIndexing() throws {
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tako-perm-multiws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wsStore = WorkspaceStore(storeURL: dir.appendingPathComponent("workspaces.json"), isTesting: true)
        wsStore.resetForTesting()

        let (_, defW1) = TerminalTestSupport.loaded()
        let (_, defW2) = TerminalTestSupport.loaded()
        Tako.CustomTabGroup.insert(defW2, into: defW1, at: 1, select: false)
        wsStore.assignTab(tabIdentifier: defW1.stableTabIdentifier, to: WorkspaceStore.defaultWorkspaceId)
        wsStore.assignTab(tabIdentifier: defW2.stableTabIdentifier, to: WorkspaceStore.defaultWorkspaceId)

        let ws2 = wsStore.createWorkspace(name: "Workspace 2")
        let (_, ws2W1) = TerminalTestSupport.loaded()
        let (_, ws2W2) = TerminalTestSupport.loaded()
        Tako.CustomTabGroup.insert(ws2W2, into: ws2W1, at: 1, select: false)
        wsStore.assignTab(tabIdentifier: ws2W1.stableTabIdentifier, to: ws2.id)
        wsStore.assignTab(tabIdentifier: ws2W2.stableTabIdentifier, to: ws2.id)
        #expect(wsStore.switchWorkspace(to: ws2.id))

        defer {
            for w in [defW1, defW2, ws2W1, ws2W2] {
                Tako.CustomTabGroup.leave(w)
                w.orderOut(nil)
            }
        }

        let groups = store.workspaceGroups(for: ws2W1, workspaceStore: wsStore)
        #expect(groups.map(\.name) == ["Default", "Workspace 2"])
        #expect(groups.map(\.isActive) == [false, true])
        #expect(groups.allSatisfy { !$0.isCollapsed })

        let activeGroup = try #require(groups.first { $0.isActive })
        let activeItems = activeGroup.items.filter { !$0.isChild }
        #expect(activeItems.map(\.tabId) == [ws2W1.stableTabIdentifier, ws2W2.stableTabIdentifier])
    }
}
