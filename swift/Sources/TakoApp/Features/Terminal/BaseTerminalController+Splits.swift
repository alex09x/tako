/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Cocoa
import TakoKit

extension BaseTerminalController {
    func syncFocusToSurfaceTree() {
        for surfaceView in surfaceTree {
            // Our focus state requires that this window is key and our currently
            // focused surface is the surface in this view.
            let focused: Bool = (window?.isKeyWindow ?? false) &&
                surfaceView == focusedSurface &&
                surfaceView.isFirstResponder
            surfaceView.focusDidChange(focused)
        }
    }

    /// Close a surface from a view.
    func closeSurface(
        _ view: Tako.SurfaceView,
        withConfirmation: Bool = true
    ) {
        guard let node = surfaceTree.root?.node(view: view) else { return }
        closeSurface(node, withConfirmation: withConfirmation)
    }

    // MARK: Split Tree Management

    /// Find the next surface to focus when a node is being closed.
    /// Goes to previous split unless we're the leftmost leaf, then goes to next.
    func findNextFocusTargetAfterClosing(node: SplitTree<Tako.SurfaceView>.Node) -> Tako.SurfaceView? {
        if usesFloatingCanvas {
            let closedIds = Set(node.map(\.id))
            guard let topVisible = floatingCanvas.visiblePanesSortedByZ.last(where: { !closedIds.contains($0.surfaceId) }) else {
                return nil
            }
            return surfaceTree.first(where: { $0.id == topVisible.surfaceId })
        }
        guard let root = surfaceTree.root else { return nil }

        // If we're the leftmost, then we move to the next surface after closing.
        // Otherwise, we move to the previous.
        if root.leftmostLeaf() == node.leftmostLeaf() {
            return surfaceTree.focusTarget(for: .next, from: node)
        } else {
            return surfaceTree.focusTarget(for: .previous, from: node)
        }
    }

    /// Remove a node from the surface tree and move focus appropriately.
    ///
    /// This also updates the undo manager to support restoring this node.
    ///
    /// This does no confirmation and assumes confirmation is already done.
    func removeSurfaceNode(_ node: SplitTree<Tako.SurfaceView>.Node) {
        for surface in node {
            PromptManager.shared.paneClosed(surfaceId: surface.id)
            SubagentHierarchyStore.shared.unregister(paneId: surface.id)
        }

        let closedWasFocused = node.contains(where: { $0 == focusedSurface })
        let targetFocus: Tako.SurfaceView? = closedWasFocused
            ? findNextFocusTargetAfterClosing(node: node)
            : focusedSurface

        replaceSurfaceTree(
            surfaceTree.removing(node),
            moveFocusTo: targetFocus,
            undoAction: "Close Terminal"
        )
    }

    func applySurfaceTreeReplacement(
        _ newTree: SplitTree<Tako.SurfaceView>,
        moveFocusTo newView: Tako.SurfaceView? = nil,
        moveFocusFrom oldView: Tako.SurfaceView? = nil,
        undoAction: String? = nil
    ) {
        let oldTree = surfaceTree
        let oldSnapshot = usesFloatingCanvas ? floatingCanvas.snapshot() : nil
        surfaceTree = newTree
        if usesFloatingCanvas {
            if let newView, newTree.contains(newView), !isMinimizedInFloatingCanvas(newView.id) {
                revealAndFocusFloatingPane(newView)
            } else if newTree.isEmpty || floatingCanvas.visiblePanesSortedByZ.isEmpty {
                focusedSurfaceDidChange(to: nil)
                if let window {
                    _ = window.makeFirstResponder(window)
                }
            }
        } else if let newView {
            DispatchQueue.main.async {
                Tako.moveFocus(to: newView, from: oldView)
            }
        }

        // Setup our undo
        guard let undoManager else { return }
        if let undoAction {
            undoManager.setActionName(undoAction)
        }

        undoManager.registerUndo(
            withTarget: self,
            expiresAfter: undoExpiration
        ) { target in
            target.surfaceTree = oldTree
            if target.usesFloatingCanvas {
                target.floatingCanvas.loadRestoredSnapshot(
                    oldSnapshot,
                    for: oldTree,
                    fallbackSize: target.estimatedFloatingCanvasSize()
                )
                if let oldView, !target.isMinimizedInFloatingCanvas(oldView.id) {
                    target.revealAndFocusFloatingPane(oldView)
                }
            } else if let oldView {
                DispatchQueue.main.async {
                    Tako.moveFocus(to: oldView, from: target.focusedSurface)
                }
            }

            undoManager.registerUndo(
                withTarget: target,
                expiresAfter: target.undoExpiration
            ) { target in
                target.replaceSurfaceTree(
                    newTree,
                    moveFocusTo: newView,
                    moveFocusFrom: target.focusedSurface,
                    undoAction: undoAction)
            }
        }
    }
}
