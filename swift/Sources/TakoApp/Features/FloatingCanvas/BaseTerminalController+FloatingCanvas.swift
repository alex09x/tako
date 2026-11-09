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
import TakoKit

extension BaseTerminalController {
    /// Finds the controller owning `surface` in its `surfaceTree` even when `surface` is minimized (`surface.window == nil`).
    static func owningController(for surface: Tako.SurfaceView) -> BaseTerminalController? {
        if let direct = surface.window?.windowController as? BaseTerminalController {
            return direct
        }
        for controller in TerminalController.all where controller.surfaceTree.contains(surface) {
            return controller
        }
        if let app = NSApp?.delegate as? AppDelegate,
           app.quickControllerInitialized,
           app.quickController.surfaceTree.contains(surface) {
            return app.quickController
        }
        return nil
    }

    func isMinimizedInFloatingCanvas(_ surfaceId: UUID) -> Bool {
        usesFloatingCanvas && floatingCanvas.isMinimized(surfaceId)
    }

    func configureFloatingCanvasPersistence() {
        guard usesFloatingCanvas else { return }
        floatingCanvas.onPersistNeeded = { [weak self] in
            self?.invalidateRestorableState()
            self?.window?.invalidateRestorableState()
        }
        floatingCanvas.sync(with: surfaceTree, fallbackSize: nil)
    }

    func estimatedFloatingCanvasSize() -> CGSize? {
        guard let contentBounds = window?.contentView?.bounds,
              contentBounds.width > 0,
              contentBounds.height > 0 else {
            return nil
        }
        var width = contentBounds.width
        if sessionSidebarIsShowing {
            width = max(100, width - SessionSidebarWidth.current())
        }
        let candidate = CGSize(width: width, height: contentBounds.height)
        return FloatingPaneGeometry.isValidCanvasSize(candidate) ? candidate : nil
    }

    /// Creates a new floating terminal surface inside the current session (including when `surfaceTree.isEmpty`).
    @discardableResult
    func createSurfaceInCurrentSession(
        direction: SplitTree<Tako.SurfaceView>.NewDirection = .right,
        baseConfig: Tako.SurfaceConfiguration? = nil
    ) -> Tako.SurfaceView? {
        var effectiveConfig = baseConfig
        if effectiveConfig?.workingDirectory == nil,
           let root = WorkspaceStore.shared.activeWorkspace.rootDirectory,
           !root.isEmpty {
            effectiveConfig = effectiveConfig ?? Tako.SurfaceConfiguration()
            effectiveConfig?.workingDirectory = root
        }

        if let anchor = focusedSurface ?? topmostVisibleFloatingSurface() ?? surfaceTree.first {
            return newSplit(at: anchor, direction: direction, baseConfig: effectiveConfig)
        }

        let created = Tako.SurfaceView(tako, baseConfig: effectiveConfig)
        let newTree = SplitTree<Tako.SurfaceView>(view: created)
        replaceSurfaceTree(newTree, moveFocusTo: created, moveFocusFrom: nil, undoAction: "New Terminal")
        revealAndFocusFloatingPane(created)
        return created
    }

    func topmostVisibleFloatingSurface() -> Tako.SurfaceView? {
        guard usesFloatingCanvas else { return focusedSurface ?? surfaceTree.first }
        guard let topId = floatingCanvas.topmostVisiblePane?.surfaceId else { return nil }
        return surfaceTree.first(where: { $0.id == topId })
    }

    // MARK: - Activate, Minimize, Maximize, Restore, Close

    func activateFloatingPane(_ surface: Tako.SurfaceView) {
        guard surfaceTree.contains(surface) else { return }
        if usesFloatingCanvas {
            floatingCanvas.bringToFront(surface.id)
        }
        revealAndFocusFloatingPane(surface)
    }

    func toggleMaximizeFloatingPane(_ surface: Tako.SurfaceView, in canvasSize: CGSize? = nil) {
        guard usesFloatingCanvas, surfaceTree.contains(surface) else { return }
        floatingCanvas.toggleMaximize(surface.id, in: canvasSize ?? estimatedFloatingCanvasSize())
        revealAndFocusFloatingPane(surface, in: canvasSize)
    }

    /// Header mode icon: detach a grid pane to free floating or return it to the grid.
    /// The same Surface/PTY stays mounted and keeps focus.
    func togglePaneFloating(_ surface: Tako.SurfaceView, in canvasSize: CGSize? = nil) {
        guard usesFloatingCanvas, surfaceTree.contains(surface) else { return }
        floatingCanvas.toggleFloating(surface.id, in: canvasSize ?? estimatedFloatingCanvasSize())
        revealAndFocusFloatingPane(surface, in: canvasSize)
    }

    func minimizeFloatingPane(_ surface: Tako.SurfaceView) {
        guard usesFloatingCanvas, surfaceTree.contains(surface) else { return }
        if let est = estimatedFloatingCanvasSize(), floatingCanvas.lastValidCanvasSize == nil {
            floatingCanvas.lastValidCanvasSize = est
        }
        let bgColor = NSColor(surface.backgroundColor ?? surface.derivedConfig.backgroundColor)
        floatingCanvas.minimize(
            surface.id,
            title: FloatingPaneGeometry.shortTitle(for: surface),
            backgroundColor: bgColor,
            backgroundOpacity: surface.derivedConfig.backgroundOpacity,
            statusColor: FloatingPaneGeometry.statusNSColor(for: surface.crab.paneStatus, surface: surface)
        )

        // Explicit minimized visibility & focus policy (Correction #3):
        // drop focus and pause presentation immediately, preserving the live PTY and last grid size.
        surface.focusDidChange(false)
        surface.isPresentationPaused = true
        surface.isWindowVisible = false

        if let next = topmostVisibleFloatingSurface() {
            revealAndFocusFloatingPane(next)
        } else {
            focusedSurface = nil
            if let window, window.firstResponder === surface {
                _ = window.makeFirstResponder(window)
            }
            syncFocusToSurfaceTree()
        }
        SessionSidebarStore.shared.objectWillChange.send()
    }

    /// Restores a minimized pane (to its prior `.maximized` or `.normal` mode) or brings a visible pane forward,
    /// arming an attach-driven `pendingFocus` request by UUID that completes when the `NSView` attaches to `NSWindow`.
    func revealAndFocusFloatingPane(_ surface: Tako.SurfaceView, in canvasSize: CGSize? = nil) {
        guard surfaceTree.contains(surface) else { return }
        if let window {
            Tako.CustomTabGroup.group(for: window).select(window)
        }
        if usesFloatingCanvas {
            if floatingCanvas.isMinimized(surface.id) {
                _ = floatingCanvas.restore(surface.id, in: canvasSize ?? estimatedFloatingCanvasSize())
            } else {
                floatingCanvas.bringToFront(surface.id)
            }
            floatingCanvas.requestPendingFocus(for: surface.id)
        }

        focusedSurface = surface
        NotificationStore.shared.markRead(surfaceId: surface.id)
        AttentionManager.shared.markSeen(surfaceId: surface.id)

        if let attachedWindow = surface.window, (window == nil || attachedWindow === window) {
            completeSurfaceAttachAndFocus(surface, in: attachedWindow, layoutReady: surface.bounds.width > 0 && surface.bounds.height > 0)
        }
        SessionSidebarStore.shared.objectWillChange.send()
    }

    func closeFloatingPane(_ surface: Tako.SurfaceView) {
        guard surfaceTree.contains(surface) else { return }
        let needsConfirm = surface.needsConfirmClose || SubagentHierarchyStore.shared.hasChildren(surface.id)
        if needsConfirm, !isMinimizedInFloatingCanvas(surface.id) {
            activateFloatingPane(surface)
        }
        closeSurface(surface, withConfirmation: needsConfirm)
    }

    // MARK: - Event-Driven NSView Attach Completion

    func surfaceDidAttachToWindow(_ surface: Tako.SurfaceView, hostBounds: CGSize) {
        guard surfaceTree.contains(surface), let attachedWindow = surface.window else { return }
        guard window == nil || attachedWindow === window else { return }
        let layoutReady = hostBounds.width > 0 && hostBounds.height > 0
        completeSurfaceAttachAndFocus(surface, in: attachedWindow, layoutReady: layoutReady)
    }

    func surfaceHostDidLayout(_ surface: Tako.SurfaceView, hostBounds: CGSize) {
        guard usesFloatingCanvas,
              hostBounds.width > 0,
              hostBounds.height > 0,
              floatingCanvas.pendingFocus?.surfaceId == surface.id,
              let attachedWindow = surface.window,
              (window == nil || attachedWindow === window) else {
            return
        }
        completeSurfaceAttachAndFocus(surface, in: attachedWindow, layoutReady: true)
    }

    private func completeSurfaceAttachAndFocus(
        _ surface: Tako.SurfaceView,
        in attachedWindow: NSWindow,
        layoutReady: Bool
    ) {
        guard !isMinimizedInFloatingCanvas(surface.id) else {
            surface.isPresentationPaused = true
            surface.isWindowVisible = false
            return
        }

        // Restore actual window visibility policy after attach.
        let windowShowing = Tako.SurfaceVisibilityWatch.isShowing(attachedWindow)
        surface.isPresentationPaused = !windowShowing
        let occludedVisible = attachedWindow.occlusionState.contains(.visible)
        if let rawSurface = surface.surface, surface.isWindowVisible != occludedVisible {
            tako_surface_set_occlusion(rawSurface, occludedVisible)
        }
        surface.isWindowVisible = occludedVisible

        guard !usesFloatingCanvas || floatingCanvas.pendingFocus?.surfaceId == surface.id else {
            return
        }

        _ = attachedWindow.makeFirstResponder(surface)
        focusedSurface = surface
        surface.focusDidChange(attachedWindow.isKeyWindow && attachedWindow.firstResponder === surface)

        if !usesFloatingCanvas || (layoutReady && attachedWindow.firstResponder === surface) {
            _ = floatingCanvas.consumePendingFocusIfMatching(surface.id)
        }
    }

    // MARK: - Split Event Routing for Floating Canvas

    func handleFloatingEqualizeSplits() {
        let size = estimatedFloatingCanvasSize() ?? FloatingPaneGeometry.fallbackCanvasSize
        floatingCanvas.equalizeVisiblePanes(in: size)
        (self as? TerminalController)?.reflowSurfaces(forcePtyResize: true)
    }

    func handleFloatingFocusSplit(from target: Tako.SurfaceView, direction: Tako.SplitFocusDirection) {
        let size = estimatedFloatingCanvasSize() ?? FloatingPaneGeometry.fallbackCanvasSize
        guard let nextId = floatingCanvas.spatialFocusTarget(direction: direction, from: target.id, in: size),
              let nextSurface = surfaceTree.first(where: { $0.id == nextId }) else {
            return
        }
        revealAndFocusFloatingPane(nextSurface, in: size)
    }

    func handleFloatingToggleZoom(target: Tako.SurfaceView) {
        toggleMaximizeFloatingPane(target, in: estimatedFloatingCanvasSize())
    }

    func handleFloatingResizeSplit(target: Tako.SurfaceView, direction: Tako.SplitResizeDirection, amount: UInt16) {
        let size = estimatedFloatingCanvasSize() ?? FloatingPaneGeometry.fallbackCanvasSize
        floatingCanvas.resizeByKeyboard(target.id, direction: direction, amount: CGFloat(amount), in: size)
        (self as? TerminalController)?.reflowSurfaces(forcePtyResize: true)
    }
}
