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
import Foundation
import SwiftUI
@testable import Tako

/// Three workspaces holding agent tabs and plain terminals, the session
/// sidebar mounted in a real window, and a way to look at what it draws.
@MainActor
final class WorkspaceSwitchVisualScene {
    struct Tab {
        let window: NSWindow
        let controller: BaseTerminalController
        let surfaces: [Tako.SurfaceView]
        let workspace: UUID
    }

    let defaults: UserDefaults
    let store: SessionSidebarStore
    let workspaces: WorkspaceStore
    let dir: URL
    private(set) var tabs: [Tab] = []
    let sidebarWindow: NSWindow
    private(set) var sidebar: NSHostingView<SessionSidebarView>!
    let main: Workspace, legal: Workspace, frontend: Workspace

    init() {
        let suite = "test.tako.ws.visual.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        store = SessionSidebarStore(defaults: defaults)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tako-ws-visual-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workspaces = WorkspaceStore(storeURL: dir.appendingPathComponent("workspaces.json"), isTesting: true)
        workspaces.resetForTesting()
        main = workspaces.activeWorkspace
        legal = workspaces.createWorkspace(name: "Legal", color: "purple")
        frontend = workspaces.createWorkspace(name: "Frontend", color: "green")

        sidebarWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 640),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        sidebarWindow.isReleasedWhenClosed = false
        sidebarWindow.appearance = NSAppearance(named: .darkAqua)
    }

    /// The sidebar, as a tab's window shows it: it reads that window's tab group.
    func mountSidebar() {
        let config = tabs[0].controller.tako.config
        sidebar = NSHostingView(rootView: SessionSidebarView(isPresented: .constant(true), containingWindow: anchor,
                                                              backgroundColor: config.backgroundColor.opacity(config.backgroundOpacity),
                                                              store: store, workspaceStore: workspaces))
        sidebar.frame = NSRect(x: 0, y: 0, width: 280, height: 640)
        sidebarWindow.contentView = sidebar
    }

    func surface(_ title: String, _ status: Tako.PaneStatus, pwd: String = "/Users/dev/project") -> Tako.SurfaceView {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.title = title
        view.pwd = pwd
        if status != .idle { view.crab.setStatus(status, text: nil) }
        return view
    }

    /// A tab of one pane, or of a split when `split` is given, in `workspace`.
    @discardableResult
    /// `ownWindow`: the tab opens a window of its own, as a workspace's first
    /// tab does when the workspace had none, instead of joining the others.
    func addTab(_ first: Tako.SurfaceView, split: Tako.SurfaceView? = nil, to workspace: Workspace,
                ownWindow: Bool = false) -> Tab {
        var tree = SplitTree<Tako.SurfaceView>(view: first)
        if let split { tree = (try? tree.inserting(view: split, at: first, direction: .right)) ?? tree }
        let controller = BaseTerminalController(Tako.App(), surfaceTree: tree)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.windowController = controller
        controller.window = window
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        content.addSubview(first)
        if let split { content.addSubview(split) }
        window.contentView = content
        if !ownWindow, let anchor = tabs.first?.window { Tako.CustomTabGroup.join(window, to: anchor, select: false) }
        workspaces.assignTab(tabIdentifier: window.stableTabIdentifier, to: workspace.id)
        let tab = Tab(window: window, controller: controller, surfaces: [first] + (split.map { [$0] } ?? []),
                      workspace: workspace.id)
        tabs.append(tab)
        return tab
    }

    /// The agent tabs and terminals the tests switch between.
    func populate() {
        addTab(surface("Claude · petition", .working, pwd: "/Users/dev/legal"), to: main)
        addTab(surface("tail -f app.log", .idle, pwd: "/Users/dev/app"), to: main)
        addTab(surface("Codex · review", .working, pwd: "/Users/dev/legal"),
               split: surface("Antigravity · brief", .needsApproval, pwd: "/Users/dev/legal"), to: legal)
        addTab(surface("Claude · exhibits", .done, pwd: "/Users/dev/legal"), to: legal)
        addTab(surface("Vite dev", .waitingForInput, pwd: "/Users/dev/web"), to: frontend)
        addTab(surface("zsh", .idle, pwd: "/Users/dev/web"), to: frontend)
        Tako.CustomTabGroup.group(for: tabs[0].window).select(tabs[0].window)
        mountSidebar()
    }

    var anchor: NSWindow { tabs[0].window }

    var groups: [SessionSidebarWorkspaceGroup] {
        store.workspaceGroups(for: anchor, workspaceStore: workspaces)
    }

    /// Switches as a click on the workspace's header in the sidebar does.
    func switchTo(_ workspace: Workspace) {
        let from = tabs.first(where: { $0.workspace == workspaces.activeWorkspaceId })?.window ?? anchor
        store.selectWorkspace(workspace.id, in: from, workspaceStore: workspaces)
        settle()
    }

    func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        sidebar.layoutSubtreeIfNeeded()
    }

    /// What the sidebar draws, at 2x, the way the window shows it.
    func snapshot() -> NSBitmapImageRep {
        settle()
        let b = sidebar.bounds
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * 2), pixelsHigh: Int(b.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = b.size
        sidebar.cacheDisplay(in: b, to: rep)
        return rep
    }

    func export(_ rep: NSBitmapImageRep, _ name: String) {
        guard let out = ProcessInfo.processInfo.environment["TAKO_WS_FRAMES_DIR"], !out.isEmpty,
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: out).appendingPathComponent(name + ".png"))
    }

    func tearDown() {
        for tab in tabs { tab.window.close() }
        sidebarWindow.close()
        try? FileManager.default.removeItem(at: dir)
    }
}
