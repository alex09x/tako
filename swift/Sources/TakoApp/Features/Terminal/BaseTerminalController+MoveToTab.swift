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

/// Why a pane could not join another tab.
struct MovePaneError: Error, CustomStringConvertible {
    let description: String
}

/// In front for the user: the selected tab of the key window of the active
/// app, on screen. Replaceable so a test host, never the active app, can
/// stand a tab in front.
@MainActor
enum MovePaneFront {
    static var isInFront: (NSWindow) -> Bool = { window in
        NSApp.isActive && window.isKeyWindow && window.isVisible && !window.isMiniaturized
            && Tako.CustomTabGroup.group(for: window).selectedWindow === window
    }
}

extension BaseTerminalController {
    /// Moves `source`, from whichever tab holds it, into this tab beside
    /// `destination`: the same live view and process, nothing restarted. The
    /// pane-header menu's «Move to Tab» and `takoctl pane move --into` both
    /// come here.
    ///
    /// - Within one tab it is the same step as dropping a split onto
    ///   another, undoable as «Move Split».
    /// - Into another tab it is not undoable. Both tabs' older undo
    ///   snapshots are dropped, since each would put the pane back where it
    ///   no longer is (or take it out of where it now is). A tab the pane
    ///   leaves empty closes.
    /// - The pane keeps its look: what it inherited from its old tab (and old
    ///   workspace) is carried into its own appearance record first; a
    ///   failed write refuses the move with both tabs unchanged.
    /// - `select: false` changes no selection, window, workspace or unread
    ///   state; only a source tab whose focused pane left gets a new focus.
    ///   `select: true` switches to the destination's workspace, selects its
    ///   tab and focuses the pane.
    /// - `batchStep: true` (one pane of a whole-session move): the source's
    ///   focus moves only logically, so no pane passed over is marked seen.
    func movePaneHere(
        _ source: Tako.SurfaceView,
        beside destination: Tako.SurfaceView,
        direction: SplitTree<Tako.SurfaceView>.NewDirection,
        select: Bool = true,
        batchStep: Bool = false,
        appearance: ScopedAppearanceStore = .shared,
        workspaces: WorkspaceStore = .shared
    ) throws {
        guard source !== destination else { throw MovePaneError(description: "a pane cannot move beside itself") }
        guard surfaceTree.contains(destination) else {
            throw MovePaneError(description: "the destination pane is not in this tab")
        }

        if let node = surfaceTree.root?.node(view: source) {
            let newTree: SplitTree<Tako.SurfaceView>
            do {
                newTree = try surfaceTree.removing(node).inserting(view: source, at: destination, direction: direction)
            } catch {
                throw MovePaneError(description: "the pane could not be placed: \(error)")
            }
            replaceSurfaceTree(newTree, moveFocusTo: select ? source : nil,
                               moveFocusFrom: select ? focusedSurface : nil, undoAction: "Move Split")
            if select { revealMovedPane(source, workspaces: workspaces) }
            return
        }

        guard let from = BaseTerminalController.owningController(for: source), from !== self,
              let node = from.surfaceTree.root?.node(view: source) else {
            throw MovePaneError(description: "the pane is not in any tab")
        }
        let newTree: SplitTree<Tako.SurfaceView>
        do {
            newTree = try surfaceTree.inserting(view: source, at: destination, direction: direction)
        } catch {
            throw MovePaneError(description: "the pane could not be placed: \(error)")
        }
        let leftover = from.surfaceTree.removing(node)

        // Its look first: a refusal here leaves both tabs as they were.
        let fromWorkspace = from.window.flatMap { workspaces.workspace(forTab: $0.stableTabIdentifier)?.id }
            ?? workspaces.activeWorkspaceId
        let toWorkspace = window.flatMap { workspaces.workspace(forTab: $0.stableTabIdentifier)?.id }
            ?? workspaces.activeWorkspaceId
        do {
            try appearance.carryMovedPaneStyle(
                from: (workspace: fromWorkspace, session: from.window?.stableTabIdentifier),
                to: (workspace: toWorkspace, session: window?.stableTabIdentifier),
                toPane: source.id)
        } catch {
            throw MovePaneError(description: "the pane's appearance could not be kept, so it was not moved: \(error.localizedDescription)")
        }

        for controller in [from, self] {
            controller.undoManager?.removeAllActions(withTarget: controller)
        }

        // Out of its tab first, so the view leaves the old hierarchy before
        // it joins the new one. Its subagent links and prompts stay: it lives on.
        from.takeOutMovedPane(source, node: node, leaving: leftover, handOffInFront: !select && !batchStep)
        surfaceTree = newTree

        if leftover.isEmpty, let tab = from as? TerminalController {
            tab.closeTabImmediately(registerRedo: false)
        }
        if select { revealMovedPane(source, workspaces: workspaces) }
    }

    /// Sets this tab's tree to `leftover`, `source`'s tree without it. If
    /// `source` had the focus, it goes to what is left. Only a tab in front
    /// for the user (the selected tab of the key window of the active app,
    /// on screen), and only with `handOffInFront` (it stays in front and this
    /// is not a step of a larger move), gets real focus; any other only gets
    /// its logical focus moved, nothing marked seen.
    func takeOutMovedPane(_ source: Tako.SurfaceView, node: SplitTree<Tako.SurfaceView>.Node,
                          leaving leftover: SplitTree<Tako.SurfaceView>, handOffInFront: Bool) {
        let leavingFocus = focusedSurface === source
        let inFront = window.map(MovePaneFront.isInFront) ?? false
        let next = leavingFocus ? findNextFocusTargetAfterClosing(node: node) : nil
        surfaceTree = leftover
        guard leavingFocus else { return }
        if let next, inFront, handOffInFront {
            focusMovedPane(next)
        } else {
            setFocusedSurfaceUnseen(next)
        }
    }

    /// This tab in front, in its own workspace, with `surface` focused.
    func revealMovedPane(_ surface: Tako.SurfaceView, workspaces: WorkspaceStore) {
        guard let window else { return }
        let tab = window.stableTabIdentifier
        if let workspace = workspaces.workspace(forTab: tab)?.id, workspace != workspaces.activeWorkspaceId {
            workspaces.setActiveTab(tabIdentifier: tab, in: workspace)
            _ = workspaces.switchWorkspace(to: workspace)
        }
        Tako.CustomTabGroup.group(for: window).select(window)
        if !Tako.CustomTabGroup.suppressWindowOrderingForTesting { window.makeKeyAndOrderFront(nil) }
        focusMovedPane(surface)
    }

    /// Keyboard to `surface`, as closing a split moves it.
    func focusMovedPane(_ surface: Tako.SurfaceView) {
        if usesFloatingCanvas {
            revealAndFocusFloatingPane(surface)
        } else {
            let previous = focusedSurface
            focusedSurface = surface
            DispatchQueue.main.async { Tako.moveFocus(to: surface, from: previous) }
        }
    }
}
