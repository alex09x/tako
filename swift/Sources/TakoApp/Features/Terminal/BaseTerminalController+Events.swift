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
    func setupNotificationObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onConfirmClipboardRequest),
            name: Tako.Notification.confirmClipboard,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(didChangeScreenParametersNotification),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(takoConfigDidChangeBase(_:)),
            name: .takoConfigDidChange,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(takoCommandPaletteDidToggle(_:)),
            name: .takoCommandPaletteDidToggle,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(takoMaximizeDidToggle(_:)),
            name: .takoMaximizeDidToggle,
            object: nil)

        // Splits
        center.addObserver(
            self,
            selector: #selector(takoDidCloseSurface(_:)),
            name: Tako.Notification.takoCloseSurface,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(takoDidNewSplit(_:)),
            name: Tako.Notification.takoNewSplit,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(takoDidEqualizeSplits(_:)),
            name: Tako.Notification.didEqualizeSplits,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(takoDidFocusSplit(_:)),
            name: Tako.Notification.takoFocusSplit,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(takoDidToggleSplitZoom(_:)),
            name: Tako.Notification.didToggleSplitZoom,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(takoDidResizeSplit(_:)),
            name: Tako.Notification.didResizeSplit,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(takoDidPresentTerminal(_:)),
            name: Tako.Notification.takoPresentTerminal,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(takoSurfaceDragEndedNoTarget(_:)),
            name: .takoSurfaceDragEndedNoTarget,
            object: nil)

        self.eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged]
        ) { [weak self] event in self?.localEventHandler(event) }
    }

    // MARK: Notifications

    @objc func didChangeScreenParametersNotification(_ notification: Notification) {
        // If we have a window that is visible and it is outside the bounds of the
        // screen then we clamp it back to within the screen.
        guard let window else { return }
        guard window.isVisible else { return }

        // We ignore fullscreen windows because macOS automatically resizes
        // those back to the fullscreen bounds.
        guard !window.styleMask.contains(.fullScreen) else { return }

        guard let screen = window.screen else { return }
        let visibleFrame = screen.visibleFrame
        var newFrame = window.frame

        // Clamp width/height
        if newFrame.size.width > visibleFrame.size.width {
            newFrame.size.width = visibleFrame.size.width
        }
        if newFrame.size.height > visibleFrame.size.height {
            newFrame.size.height = visibleFrame.size.height
        }

        // Ensure the window is on-screen. We only do this if the previous frame
        // was also on screen. If a user explicitly wanted their window off screen
        // then we let it stay that way.
        x: if newFrame.origin.x < visibleFrame.origin.x {
            if let savedFrame, savedFrame.window.origin.x < savedFrame.screen.origin.x {
                break x
            }

            newFrame.origin.x = visibleFrame.origin.x
        }
        y: if newFrame.origin.y < visibleFrame.origin.y {
            if let savedFrame, savedFrame.window.origin.y < savedFrame.screen.origin.y {
                break y
            }

            newFrame.origin.y = visibleFrame.origin.y
        }

        // Apply the new window frame
        window.setFrame(newFrame, display: true)
    }

    @objc func takoConfigDidChangeBase(_ notification: Notification) {
        // We only care if the configuration is a global configuration, not a
        // surface-specific one.
        guard notification.object == nil else { return }

        // Get our managed configuration object out
        guard let config = notification.userInfo?[
            Notification.Name.TakoConfigChangeKey
        ] as? Tako.Config else { return }

        // Update our derived config
        self.baseDerivedConfig = DerivedConfig(config)

        // Keep the Rust terminal and PTY alive; only rebuild renderer state
        // so a palette/font switch takes effect without reopening tabs.
        for surface in surfaceTree {
            surface.updateTheme(config.theme)
        }
    }

    @objc func takoCommandPaletteDidToggle(_ notification: Notification) {
        guard let surfaceView = notification.object as? Tako.SurfaceView else { return }
        guard surfaceTree.contains(surfaceView) else { return }
        toggleCommandPalette(nil)
    }

    @objc func takoMaximizeDidToggle(_ notification: Notification) {
        guard let window else { return }
        guard let surfaceView = notification.object as? Tako.SurfaceView else { return }
        guard surfaceTree.contains(surfaceView) else { return }
        window.zoom(nil)
    }

    @objc func takoDidCloseSurface(_ notification: Notification) {
        guard let target = notification.object as? Tako.SurfaceView else { return }
        guard let node = surfaceTree.root?.node(view: target) else { return }
        closeSurface(
            node,
            withConfirmation: (notification.userInfo?["process_alive"] as? Bool) ?? false)
    }

    @objc func takoDidNewSplit(_ notification: Notification) {
        // The target must be within our tree
        guard let oldView = notification.object as? Tako.SurfaceView else { return }
        guard surfaceTree.root?.node(view: oldView) != nil else { return }

        // Notification must contain our base config
        let configAny = notification.userInfo?[Tako.Notification.NewSurfaceConfigKey]
        let config = configAny as? Tako.SurfaceConfiguration

        // Determine our desired direction
        guard let directionAny = notification.userInfo?["direction"] else { return }
        guard let direction = directionAny as? tako_action_split_direction_e else { return }
        let splitDirection: SplitTree<Tako.SurfaceView>.NewDirection
        switch direction {
        case TAKO_SPLIT_DIRECTION_RIGHT: splitDirection = .right
        case TAKO_SPLIT_DIRECTION_LEFT: splitDirection = .left
        case TAKO_SPLIT_DIRECTION_DOWN: splitDirection = .down
        case TAKO_SPLIT_DIRECTION_UP: splitDirection = .up
        default: return
        }

        newSplit(at: oldView, direction: splitDirection, baseConfig: config)
    }

    @objc func takoDidEqualizeSplits(_ notification: Notification) {
        guard let target = notification.object as? Tako.SurfaceView else { return }

        // Check if target surface is in current controller's tree
        guard surfaceTree.contains(target) else { return }

        // Equalize the splits
        surfaceTree = surfaceTree.equalized()
    }

    @objc func takoDidFocusSplit(_ notification: Notification) {
        // The target must be within our tree
        guard let target = notification.object as? Tako.SurfaceView else { return }
        guard surfaceTree.root?.node(view: target) != nil else { return }

        // Get the direction from the notification
        guard let directionAny = notification.userInfo?[Tako.Notification.SplitDirectionKey] else { return }
        guard let direction = directionAny as? Tako.SplitFocusDirection else { return }

        // Find the node for the target surface
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }

        // Find the next surface to focus
        guard let nextSurface = surfaceTree.focusTarget(for: direction.toSplitTreeFocusDirection(), from: targetNode) else {
            return
        }

        if surfaceTree.zoomed != nil {
            if baseDerivedConfig.splitPreserveZoom.contains(.navigation) {
                surfaceTree = SplitTree(
                    root: surfaceTree.root,
                    zoomed: surfaceTree.root?.node(view: nextSurface))
            } else {
                surfaceTree = SplitTree(root: surfaceTree.root, zoomed: nil)
            }
        }

        // Move focus to the next surface
        DispatchQueue.main.async {
            Tako.moveFocus(to: nextSurface, from: target)
        }
    }

    @objc func takoDidToggleSplitZoom(_ notification: Notification) {
        // The target must be within our tree
        guard let target = notification.object as? Tako.SurfaceView else { return }
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }

        // Toggle the zoomed state
        if surfaceTree.zoomed == targetNode {
            // Already zoomed, unzoom it
            surfaceTree = SplitTree(root: surfaceTree.root, zoomed: nil)
        } else {
            // We require that the split tree have splits
            guard surfaceTree.isSplit else { return }

            // Not zoomed or different node zoomed, zoom this node
            surfaceTree = SplitTree(root: surfaceTree.root, zoomed: targetNode)
        }

        // Move focus to our window. Importantly this ensures that if we click the
        // reset zoom button in a tab bar of an unfocused tab that we become focused.
        // select(), not makeKeyAndOrderFront directly: native tabbing is
        // disallowed, so nothing else hides whichever sibling tab was
        // showing before the way AppKit used to.
        if let window {
            Tako.CustomTabGroup.group(for: window).select(window)
        }

        // Ensure focus stays on the target surface. We lose focus when we do
        // this so we need to grab it again.
        DispatchQueue.main.async {
            Tako.moveFocus(to: target)
        }
    }

    @objc func takoDidResizeSplit(_ notification: Notification) {
        // The target must be within our tree
        guard let target = notification.object as? Tako.SurfaceView else { return }
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }

        // Extract direction and amount from notification
        guard let directionAny = notification.userInfo?[Tako.Notification.ResizeSplitDirectionKey] else { return }
        guard let direction = directionAny as? Tako.SplitResizeDirection else { return }

        guard let amountAny = notification.userInfo?[Tako.Notification.ResizeSplitAmountKey] else { return }
        guard let amount = amountAny as? UInt16 else { return }

        // Convert Tako.SplitResizeDirection to SplitTree.Spatial.Direction
        let spatialDirection: SplitTree<Tako.SurfaceView>.Spatial.Direction
        switch direction {
        case .up: spatialDirection = .up
        case .down: spatialDirection = .down
        case .left: spatialDirection = .left
        case .right: spatialDirection = .right
        }

        // Use viewBounds for the spatial calculation bounds
        let bounds = CGRect(origin: .zero, size: surfaceTree.viewBounds())

        // Perform the resize using the new SplitTree resize method
        do {
            surfaceTree = try surfaceTree.resizing(node: targetNode, by: amount, in: spatialDirection, with: bounds)
        } catch {
            Tako.logger.warning("failed to resize split: \(error, privacy: .public)")
        }
    }

    @objc func takoDidPresentTerminal(_ notification: Notification) {
        guard let target = notification.object as? Tako.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }

        // Bring the window to front and focus the surface.
        // select(), not makeKeyAndOrderFront directly: native tabbing is
        // disallowed, so nothing else hides whichever sibling tab was
        // showing before the way AppKit used to.
        if let window {
            Tako.CustomTabGroup.group(for: window).select(window)
        }

        // We use a small delay to ensure this runs after any UI cleanup
        // (e.g., command palette restoring focus to its original surface).
        Tako.moveFocus(to: target)
        Tako.moveFocus(to: target, delay: 0.1)

        // Focusing a pane marks it read (B4) and seen (B7)
        NotificationStore.shared.markRead(surfaceId: target.id)
        AttentionManager.shared.markSeen(surfaceId: target.id)

        // Show a brief highlight to help the user locate the presented terminal.
        target.highlight()
    }

    @objc func takoSurfaceDragEndedNoTarget(_ notification: Notification) {
        guard let target = notification.object as? Tako.SurfaceView else { return }
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }

        // If our tree isn't split, then we never create a new window, because
        // it is already a single split.
        guard surfaceTree.isSplit else { return }

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
        _ = TerminalController.newWindow(
            tako,
            tree: newTree,
            position: notification.userInfo?[Notification.Name.takoSurfaceDragEndedNoTargetPointKey] as? NSPoint,
            confirmUndo: false,
            inheritBackgroundOpacity: isBackgroundOpaque)
    }

}
