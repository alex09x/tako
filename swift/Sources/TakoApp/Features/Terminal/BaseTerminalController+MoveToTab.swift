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

extension BaseTerminalController {
    /// Moves `source`, from whichever tab holds it, into this tab beside
    /// `destination`: the same live view and process, nothing restarted. A tab
    /// the pane leaves empty closes. The pane-header menu's «Move to Tab» and
    /// `takoctl pane move --into` both come here.
    func movePaneHere(
        _ source: Tako.SurfaceView,
        beside destination: Tako.SurfaceView,
        direction: SplitTree<Tako.SurfaceView>.NewDirection
    ) throws {
        guard source !== destination else { throw MovePaneError(description: "a pane cannot move beside itself") }
        guard surfaceTree.contains(destination) else {
            throw MovePaneError(description: "the destination pane is not in this tab")
        }

        // Within this tab: the same step as dropping a split onto another.
        if let node = surfaceTree.root?.node(view: source) {
            let newTree: SplitTree<Tako.SurfaceView>
            do {
                newTree = try surfaceTree.removing(node).inserting(view: source, at: destination, direction: direction)
            } catch {
                throw MovePaneError(description: "the pane could not be placed: \(error)")
            }
            replaceSurfaceTree(newTree, moveFocusTo: source, moveFocusFrom: focusedSurface, undoAction: "Move Split")
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
        let closesSource = leftover.isEmpty

        // A tab that closes cannot be undone back into; the move is then not
        // undoable either, rather than half undoable.
        let managers = [undoManager, from.undoManager].compactMap { $0 }
        let distinct = managers.reduce(into: [UndoManager]()) { list, m in if !list.contains(where: { $0 === m }) { list.append(m) } }
        if closesSource { distinct.forEach { $0.disableUndoRegistration() } }
        distinct.forEach { $0.beginUndoGrouping(); $0.setActionName("Move Pane") }
        defer {
            distinct.forEach { $0.endUndoGrouping() }
            if closesSource { distinct.forEach { $0.enableUndoRegistration() } }
        }

        // Out of its tab first, so the view leaves the old hierarchy before
        // it joins the new one. Its subagent links and prompts stay: it lives on.
        let sourceFocus = from.focusedSurface == source ? from.findNextFocusTargetAfterClosing(node: node) : from.focusedSurface
        from.replaceSurfaceTree(leftover, moveFocusTo: sourceFocus)
        replaceSurfaceTree(newTree, moveFocusTo: source, moveFocusFrom: focusedSurface)
        if closesSource, let tab = from as? TerminalController {
            tab.closeTabImmediately(registerRedo: false)
        }
    }

    /// This tab in front, its window key.
    func bringTabToFront() {
        guard let window else { return }
        Tako.CustomTabGroup.group(for: window).select(window)
        window.makeKeyAndOrderFront(nil)
    }
}
