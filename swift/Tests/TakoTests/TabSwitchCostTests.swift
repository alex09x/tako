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
import Combine
import Foundation
import Testing
@testable import Tako

/// A tab switch shows up at once. Clicks took 200-700 ms to reach the
/// screen because the main thread never rested: every tooltip or panel
/// that closed became a tab listed in the workspace for good (895 of them
/// next to 6 live tabs), and the tab bar walked that list for every tab on
/// every draw.
@Suite(.serialized) @MainActor
struct TabSwitchCostTests {
    private func temporaryStore() -> (WorkspaceStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("workspaces.json")
        return (WorkspaceStore(storeURL: url, isTesting: false), url)
    }

    @Test func aClosingWindowThatIsNoTabStaysNoTab() {
        _ = NSApplication.shared
        let sidebar = SessionSidebarStore(defaults: UserDefaults(suiteName: "TabSwitchCost-\(UUID().uuidString)")!)
        let tooltip = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 20), styleMask: [.borderless],
                               backing: .buffered, defer: true)
        let listed = WorkspaceStore.shared.workspaces.map(\.tabIdentifiers)
        withExtendedLifetime(sidebar) {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: tooltip)
        }
        #expect(Tako.CustomTabGroup.existingGroup(for: tooltip) == nil)
        #expect(WorkspaceStore.shared.workspaces.map(\.tabIdentifiers) == listed)
    }

    @Test func tabsLongClosedDoNotSlowTheTabBar() {
        _ = NSApplication.shared
        let store = WorkspaceStore.shared
        let windows = (0..<6).map { makeWindow(title: "t\($0)") }
        for window in windows.dropFirst() {
            Tako.CustomTabGroup.join(window, to: windows[0], select: false)
        }
        defer {
            windows.forEach(Tako.CustomTabGroup.leave)
            store.resetForTesting()
        }
        let group = Tako.CustomTabGroup.group(for: windows[0])
        // Thousands of tabs listed before the live ones, which are in
        // reverse order of the group's.
        let index = store.workspaces.firstIndex { $0.id == store.activeWorkspaceId }!
        store.workspaces[index].tabIdentifiers = (0..<3000).map { _ in UUID().uuidString }
            + windows.reversed().map(\.stableTabIdentifier)
        #expect(group.visibleWindows == windows.reversed())

        // The tab bar asks this for every tab on every draw.
        let took = ContinuousClock().measure {
            for _ in 0..<300 { _ = group.visibleWindows }
        }
        #expect(took < .milliseconds(100), "300 asks took \(took)")
    }

    @Test func aTabsPanesComeFromItsControllerNotFromEveryView() {
        _ = NSApplication.shared
        let left = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let right = Tako.SurfaceView(frame: NSRect(x: 200, y: 0, width: 200, height: 200))
        var tree = SplitTree<Tako.SurfaceView>(view: left)
        tree = (try? tree.inserting(view: right, at: left, direction: .right)) ?? tree
        let controller = BaseTerminalController(Tako.App(), surfaceTree: tree)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.windowController = controller
        controller.window = window
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        content.addSubview(left)
        content.addSubview(right)
        // A sidebar's worth of views, and then some.
        for _ in 0..<3000 { content.addSubview(NSView(frame: .zero)) }
        window.contentView = content

        #expect(Tako.surfaces(in: window) == [left, right])
        #expect(Tako.surface(in: window) === left)
        let took = ContinuousClock().measure {
            for _ in 0..<300 { _ = Tako.surfaces(in: window) }
        }
        #expect(took < .milliseconds(50), "300 asks took \(took)")
    }

    @Test func aWindowShowingWhatItsControllerDoesNotHoldIsStillSearched() {
        _ = NSApplication.shared
        let held = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let shown = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let controller = BaseTerminalController(Tako.App(), surfaceTree: SplitTree(view: held))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.windowController = controller
        controller.window = window
        window.contentView = shown
        #expect(Tako.surfaces(in: window) == [shown])
    }

    @Test func aLongTitleIsCutInOnePassWhereEveryPrefixWouldCutIt() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let title = String(repeating: "alex09x@ram11: /solana/hl-order-book-server ✳ ", count: 30)
        func prefixByPrefix(_ width: CGFloat) -> String {
            let safe = Tako.TabText.displayText(title, font: font)
            guard Tako.TabText.width(of: safe, font: font) > width else { return safe }
            let ellipsisWidth = Tako.TabText.width(of: "\u{2026}", font: font)
            guard ellipsisWidth <= width else { return "" }
            var result = ""
            for character in safe {
                let candidate = result + String(character)
                if Tako.TabText.width(of: candidate, font: font) + ellipsisWidth > width { break }
                result = candidate
            }
            return result + "\u{2026}"
        }
        for width: CGFloat in [4, 30, 120, 260, 900] {
            #expect(Tako.TabText.truncate(title, to: width, font: font) == prefixByPrefix(width))
        }
        #expect(Tako.TabText.truncate("short", to: 900, font: font) == "short")

        let took = ContinuousClock().measure {
            for _ in 0..<5 { _ = Tako.TabText.truncate(title, to: 4000, font: font) }
        }
        #expect(took < .milliseconds(150), "5 cuts took \(took)")
    }

    @Test func aLaunchForgetsEveryTabThatWasNotRestored() {
        let (store, url) = temporaryStore()
        let def = WorkspaceStore.defaultWorkspaceId
        let other = store.createWorkspace(name: "other")
        for id in ["a", "b", "c", "d"] { store.assignTab(tabIdentifier: id, to: def) }
        store.assignTab(tabIdentifier: "x", to: other.id)
        store.setActiveTab(tabIdentifier: "c", in: def)

        store.pruneTabs(keeping: ["b", "d", "x"])
        #expect(store.workspace(for: def)?.tabIdentifiers == ["b", "d"])
        #expect(store.workspace(for: def)?.activeTabIdentifier == "b")
        #expect(store.workspace(forTab: "a") == nil)
        #expect(store.workspace(forTab: "x")?.id == other.id)
        #expect(store.rank(ofTab: "d", in: def) == 1)

        let reloaded = WorkspaceStore(storeURL: url, isTesting: false)
        #expect(reloaded.workspace(for: def)?.tabIdentifiers == ["b", "d"])
        #expect(reloaded.rank(ofTab: "d", in: def) == 1)
    }

    @Test func aTabsPlaceFollowsEveryChange() {
        let (store, _) = temporaryStore()
        let def = WorkspaceStore.defaultWorkspaceId
        let other = store.createWorkspace(name: "other")
        store.assignTab(tabIdentifier: "a", to: def)
        store.assignTab(tabIdentifier: "b", to: def)
        #expect(store.rank(ofTab: "b", in: def) == 1)
        #expect(store.rank(ofTab: "b", in: other.id) == nil)

        store.reorderTabs(in: def, newOrder: ["b", "a"])
        #expect(store.rank(ofTab: "b", in: def) == 0)
        store.assignTab(tabIdentifier: "b", to: other.id)
        #expect(store.rank(ofTab: "b", in: other.id) == 0)
        #expect(store.rank(ofTab: "a", in: def) == 0)
        store.removeTab(tabIdentifier: "a")
        #expect(store.workspace(forTab: "a") == nil)
        #expect(store.deleteWorkspace(id: other.id))
        #expect(store.workspace(forTab: "b")?.id == def)
    }

    @Test func choosingTheChosenTabAgainChangesNothing() throws {
        let (store, url) = temporaryStore()
        let def = WorkspaceStore.defaultWorkspaceId
        store.assignTab(tabIdentifier: "a", to: def)
        store.setActiveTab(tabIdentifier: "a", in: def)
        try FileManager.default.removeItem(at: url)
        var published = 0
        let watch = store.objectWillChange.sink { published += 1 }
        defer { watch.cancel() }

        store.setActiveTab(tabIdentifier: "a", in: def)
        #expect(published == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
