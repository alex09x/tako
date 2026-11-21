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

extension BaseTerminalController {
    /// Moves `target` out of this tab into a window of its own, the same
    /// live view and process, undoable as one step. Nil when it is not one
    /// of several panes here: a lone pane already is a tab of its own.
    /// Dragging a pane out (`takoSurfaceDragEndedNoTarget`) and
    /// `takoctl pane move --window new` both come here.
    @discardableResult
    func moveSurfaceToNewWindow(_ target: Tako.SurfaceView, position: NSPoint? = nil) -> TerminalController? {
        guard let targetNode = surfaceTree.root?.node(view: target) else { return nil }

        // If our tree isn't split, then we never create a new window, because
        // it is already a single split.
        guard surfaceTree.isSplit else { return nil }

        // Collapsing the old SwiftUI tree can resize a moved NSView before
        // the new controller mounts it. Preserve its current viewport first.
        let draggedContentSize = target.frame.size

        // If we are removing our focused surface then we move it. We need to
        // keep track of our old one so undo sends focus back to the right place.
        let oldFocusedSurface = focusedSurface
        if focusedSurface == target {
            focusedSurface = findNextFocusTargetAfterClosing(node: targetNode)
        }

        // Remove the surface from our tree
        let removedTree = surfaceTree.removing(targetNode)

        // Create a new tree with the dragged surface and open a new window
        let newTree = SplitTree<Tako.SurfaceView>(view: target)

        // Treat our undo below as a full group.
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Move Split")
        defer {
            undoManager?.endUndoGrouping()
        }

        replaceSurfaceTree(removedTree, moveFocusFrom: oldFocusedSurface)
        if draggedContentSize.width > 0, draggedContentSize.height > 0 {
            target.initialSize = draggedContentSize
        }
        return TerminalController.newWindow(
            tako,
            tree: newTree,
            position: position,
            confirmUndo: false,
            inheritBackgroundOpacity: isBackgroundOpaque)
    }
}
