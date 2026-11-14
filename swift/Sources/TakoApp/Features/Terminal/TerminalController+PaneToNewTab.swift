/*
 * tako — Taking one pane out of a split into a tab of its own
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

extension TerminalController {
    /// Moves `source`, one of several panes here, into a new tab right after
    /// this one: same window, same workspace, the same live view and
    /// process. «Move to Tab ▸ New Tab» in the pane's header and in the
    /// sidebar come here.
    ///
    /// - Not undoable: this tab's older undo snapshots are dropped, since
    ///   each would put the pane back while it lives in the new tab.
    /// - The pane keeps its look: what it inherited from this tab is carried
    ///   into its own appearance record first; a failed write refuses the
    ///   move with this tab unchanged.
    /// - `select: false` adds the tab behind the selected one and changes no
    ///   selection or unread state.
    @discardableResult
    func movePaneToNewTab(
        _ source: Tako.SurfaceView,
        select: Bool = true,
        appearance: ScopedAppearanceStore = .shared,
        workspaces: WorkspaceStore = .shared
    ) throws -> TerminalController {
        guard let node = surfaceTree.root?.node(view: source) else {
            throw MovePaneError(description: "the pane is not in this tab")
        }
        guard surfaceTree.isSplit else { throw MovePaneError(description: "the pane already is a tab of its own") }
        guard let parent = window else { throw MovePaneError(description: "the tab has no window") }
        if let style = fullscreenStyle, style.isFullscreen && !style.supportsTabs {
            throw MovePaneError(description: "new tabs are unsupported in non-native fullscreen")
        }
        let session = parent.stableTabIdentifier
        let workspace = workspaces.workspace(forTab: session)?.id ?? workspaces.activeWorkspaceId

        // Its look first: a refusal here leaves the tab as it was. The new
        // tab's session has no record yet, so only the workspace remains.
        do {
            try appearance.carryMovedPaneStyle(from: (workspace: workspace, session: session),
                                               to: (workspace: workspace, session: nil), toPane: source.id)
        } catch {
            throw MovePaneError(description: "the pane's appearance could not be kept, so it was not moved: \(error.localizedDescription)")
        }
        undoManager?.removeAllActions(withTarget: self)

        let size = source.frame.size
        takeOutMovedPane(source, node: node, leaving: surfaceTree.removing(node), select: select)
        if size.width > 0, size.height > 0 { source.initialSize = size }

        let controller = TerminalController(tako, withSurfaceTree: SplitTree(view: source))
        controller.appliesConfiguredWindowSize = false
        Self.system.attachWindow(controller)
        controller.isBackgroundOpaque = isBackgroundOpaque
        guard let window = controller.window else { return controller }

        let rank = workspaces.rank(ofTab: session, in: workspace).map { $0 + 1 }
        workspaces.assignTab(tabIdentifier: window.stableTabIdentifier, to: workspace, at: rank)
        let group = Tako.CustomTabGroup.group(for: parent)
        let index = group.windows.firstIndex(of: parent).map { $0 + 1 } ?? group.windows.count
        Tako.CustomTabGroup.insert(window, into: parent, at: index, select: select)

        if select {
            controller.revealMovedPane(source, workspaces: workspaces)
        } else {
            controller.setFocusedSurfaceUnseen(source)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak controller] in controller?.relabelTabs() }
        return controller
    }
}
