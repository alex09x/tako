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
import SwiftUI
import TakoKit

extension TerminalController {
    // MARK: Terminal Creation

    /// Returns all the available terminal controllers present in the app currently.
    static var all: [TerminalController] {
        return NSApplication.shared.windows.compactMap {
            $0.windowController as? TerminalController
        }
    }

    // Keep track of the last point that our window was launched at so that new
    // windows "cascade" over each other and don't just launch directly on top
    // of each other.
    static var lastCascadePoint = NSPoint(x: 0, y: 0)

    private static func applyCascade(to window: NSWindow, hasFixedPos: Bool) {
        if hasFixedPos { return }

        if all.count > 1 {
            lastCascadePoint = window.cascadeTopLeft(from: lastCascadePoint)
        } else {
            // We assume the window frame is already correct at this point,
            // so we pass .zero to let cascade use the current frame position.
            lastCascadePoint = window.cascadeTopLeft(from: .zero)
        }
    }

    // The preferred parent terminal controller.
    static var preferredParent: TerminalController? {
        all.first {
            $0.window?.isMainWindow ?? false
        } ?? lastMain ?? all.last
    }

    // The last controller to be main. We use this when paired with "preferredParent"
    // to find the preferred window to attach new tabs, perform actions, etc. We
    // always prefer the main window but if there isn't any (because we're triggered
    // by something like an AppleScript command) then we prefer the most previous main.
    static internal(set) weak var lastMain: TerminalController?

    /// The "new window" action.
    static func newWindow(
        _ tako: Tako.App,
        withBaseConfig baseConfig: Tako.SurfaceConfiguration? = nil,
        withParent explicitParent: NSWindow? = nil
    ) -> TerminalController {
        // Resolve working directory from active workspace if baseConfig doesn't specify one
        var effectiveBaseConfig = baseConfig
        if effectiveBaseConfig?.workingDirectory == nil,
           let root = WorkspaceStore.shared.activeWorkspace.rootDirectory,
           !root.isEmpty {
            effectiveBaseConfig = effectiveBaseConfig ?? Tako.SurfaceConfiguration()
            effectiveBaseConfig?.workingDirectory = root
        }

        let c = TerminalController.init(tako, withBaseConfig: effectiveBaseConfig)
        Self.system.attachWindow(c)

        if let window = c.window {
            WorkspaceStore.shared.assignTab(
                tabIdentifier: window.stableTabIdentifier,
                to: WorkspaceStore.shared.activeWorkspaceId
            )
        }

        // Get our parent. Our parent is the one explicitly given to us,
        // otherwise the focused terminal, otherwise an arbitrary one.
        let parent: NSWindow? = explicitParent ?? preferredParent?.window
        if let parentController = parent?.windowController as? TerminalController {
            c.isBackgroundOpaque = parentController.isBackgroundOpaque
        }

        if let parent, parent.styleMask.contains(.fullScreen) {
            // If our previous window was fullscreen then we want our new window to
            // be fullscreen. This behavior actually doesn't match the native tabbing
            // behavior of macOS apps where new windows create tabs when in native
            // fullscreen but this is how we've always done it. This matches iTerm2
            // behavior.
            c.toggleFullscreen(mode: .native)
        } else if let fullscreenMode = tako.config.windowFullscreen {
            switch fullscreenMode {
            case .native:
                // Native has to be done immediately so that our stylemask contains
                // fullscreen for the logic later in this method.
                c.toggleFullscreen(mode: .native)

            case .nonNative, .nonNativeVisibleMenu, .nonNativePaddedNotch:
                // If we're non-native then we have to do it on a later loop
                // so that the content view is setup.
                DispatchQueue.main.async {
                    c.toggleFullscreen(mode: fullscreenMode)
                }
            }
        }

        // We're dispatching this async because otherwise the lastCascadePoint doesn't
        // take effect. Our best theory is there is some next-event-loop-tick logic
        // that Cocoa is doing that we need to be after.
        c.scheduleInitialPresentation {
            c.showWindow(self)

            // Only cascade if we aren't fullscreen.
            if let window = c.window {
                if !window.styleMask.contains(.fullScreen) {
                    let hasFixedPos = c.derivedConfig.windowPositionX != nil && c.derivedConfig.windowPositionY != nil
                    Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
                }
            }

            // All new_window actions force our app to be active, so that the new
            // window is focused and visible.
            NSApp.activate(ignoringOtherApps: true)
            if let target = c.focusedSurface {
                Tako.moveFocus(to: target)
            }
        }

        // Setup our undo
        if let undoManager = c.undoManager {
            undoManager.setActionName("New Window")
            undoManager.registerUndo(
                withTarget: c,
                expiresAfter: c.undoExpiration
            ) { target in
                // Close the window when undoing
                undoManager.disableUndoRegistration {
                    target.closeWindow(nil)
                }

                // Register redo action
                undoManager.registerUndo(
                    withTarget: tako,
                    expiresAfter: target.undoExpiration
                ) { tako in
                    _ = TerminalController.newWindow(
                        tako,
                        withBaseConfig: baseConfig,
                        withParent: explicitParent)
                }
            }
        }

        return c
    }

    /// Create a new window with an existing split tree.
    /// The window will be sized to match the tree's current view bounds if available.
    /// - Parameters:
    ///   - tako: The Tako app instance.
    ///   - tree: The split tree to use for the new window.
    ///   - position: Optional screen position (top-left corner) for the new window.
    ///               If nil, the window will cascade from the last cascade point.
    static func newWindow(
        _ tako: Tako.App,
        tree: SplitTree<Tako.SurfaceView>,
        position: NSPoint? = nil,
        confirmUndo: Bool = true,
        inheritBackgroundOpacity: Bool? = nil
    ) -> TerminalController {
        let c = TerminalController.init(tako, withSurfaceTree: tree)
        Self.system.attachWindow(c)
        if let inheritBackgroundOpacity {
            c.isBackgroundOpaque = inheritBackgroundOpacity
        }

        // Calculate the target frame based on the tree's view bounds
        let treeSize: CGSize? = tree.root?.viewBounds()

        c.scheduleInitialPresentation {
            c.showWindow(self)
            if let window = c.window {
                // If we have a tree size, resize the window's content to match
                if let treeSize, treeSize.width > 0, treeSize.height > 0 {
                    window.setContentSize(treeSize)
                    window.constrainToScreen()
                }

                if !window.styleMask.contains(.fullScreen) {
                    if let position {
                        window.setFrameTopLeftPoint(position)
                        window.constrainToScreen()
                    } else {
                        let hasFixedPos = c.derivedConfig.windowPositionX != nil && c.derivedConfig.windowPositionY != nil
                        Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
                    }
                }
            }
            if let target = c.focusedSurface {
                Tako.moveFocus(to: target)
            }
        }

        // Setup our undo
        if let undoManager = c.undoManager {
            undoManager.setActionName("New Window")
            undoManager.registerUndo(
                withTarget: c,
                expiresAfter: c.undoExpiration
            ) { target in
                undoManager.disableUndoRegistration {
                    if confirmUndo {
                        target.closeWindow(nil)
                    } else {
                        target.closeWindowImmediately()
                    }
                }

                undoManager.registerUndo(
                    withTarget: tako,
                    expiresAfter: target.undoExpiration
                ) { tako in
                    _ = TerminalController.newWindow(
                        tako,
                        tree: tree,
                        inheritBackgroundOpacity: inheritBackgroundOpacity
                    )
                }
            }
        }

        return c
    }

    static func newTab(
        _ tako: Tako.App,
        from parent: NSWindow? = nil,
        withBaseConfig baseConfig: Tako.SurfaceConfiguration? = nil
    ) -> TerminalController? {
        // Making sure that we're dealing with a TerminalController. If not,
        // then we just create a new window.
        guard let parent,
              let parentController = parent.windowController as? TerminalController else {
            return newWindow(tako, withBaseConfig: baseConfig, withParent: parent)
        }

        // If our parent is in non-native fullscreen, then new tabs do not work.
        if let fullscreenStyle = parentController.fullscreenStyle,
           fullscreenStyle.isFullscreen && !fullscreenStyle.supportsTabs {
            let alert = NSAlert()
            alert.messageText = "Cannot Create New Tab"
            alert.informativeText = "New tabs are unsupported while in non-native fullscreen. Exit fullscreen and try again."
            alert.addButton(withTitle: "OK")
            alert.alertStyle = .warning
            alert.beginSheetModal(for: parent)
            return nil
        }

        // Resolve working directory from active workspace if baseConfig doesn't specify one
        var effectiveBaseConfig = baseConfig
        if effectiveBaseConfig?.workingDirectory == nil,
           let root = WorkspaceStore.shared.activeWorkspace.rootDirectory,
           !root.isEmpty {
            effectiveBaseConfig = effectiveBaseConfig ?? Tako.SurfaceConfiguration()
            effectiveBaseConfig?.workingDirectory = root
        }

        // Create a new window and add it to the parent
        let controller = TerminalController.init(tako, withBaseConfig: effectiveBaseConfig)
        // A new tab takes the size of the window group it joins, not
        // `window-width`/`window-height` (those apply only to a new window).
        controller.appliesConfiguredWindowSize = false
        Self.system.attachWindow(controller)
        controller.isBackgroundOpaque = parentController.isBackgroundOpaque
        guard let window = controller.window else { return controller }

        // If the parent is miniaturized, then macOS exhibits really strange behaviors
        // so we have to bring it back out.
        if parent.isMiniaturized { parent.deminiaturize(self) }

        // Add the window to our custom tab group and show it. AppKit's
        // native tabbing is disallowed for every terminal window (see
        // TerminalWindow.swift), so grouping/order/selection is modelled in
        // Tako.CustomTabGroup instead of read from window.tabGroup.
        let group = Tako.CustomTabGroup.group(for: parent)
        switch tako.config.windowNewTabPosition {
        case "end":
            WorkspaceStore.shared.assignTab(
                tabIdentifier: window.stableTabIdentifier,
                to: WorkspaceStore.shared.activeWorkspaceId
            )
            // If we already have a group and we want the new tab to open at the end,
            // then we use the last window in the group as the anchor.
            if let last = group.windows.last {
                Tako.CustomTabGroup.join(window, to: last, select: true)
            } else {
                Tako.CustomTabGroup.join(window, to: parent, select: true)
            }

        case "current": fallthrough
        default:
            if let currentIdx = group.visibleWindows.firstIndex(of: parent) {
                Tako.CustomTabGroup.insert(window, into: parent, at: currentIdx + 1, select: true)
            } else {
                WorkspaceStore.shared.assignTab(
                    tabIdentifier: window.stableTabIdentifier,
                    to: WorkspaceStore.shared.activeWorkspaceId
                )
                Tako.CustomTabGroup.join(window, to: parent, select: true)
            }
        }

        // We're dispatching this async because otherwise the lastCascadePoint doesn't
        // take effect. Our best theory is there is some next-event-loop-tick logic
        // that Cocoa is doing that we need to be after.
        controller.scheduleInitialPresentation {
            // Only cascade if we aren't fullscreen and are alone in the group --
            // `join` above already positioned a grouped window to match its
            // neighbor, so cascading it here would immediately undo that.
            if !window.styleMask.contains(.fullScreen) && group.windows.count == 1 {
                let hasFixedPos = controller.derivedConfig.windowPositionX != nil && controller.derivedConfig.windowPositionY != nil
                Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
            }

            controller.showWindow(self)
            window.makeKeyAndOrderFront(self)

            // We also activate our app so that it becomes front. This may be
            // necessary for the dock menu.
            NSApp.activate(ignoringOtherApps: true)
        }

        // It takes an event loop cycle until the macOS tabGroup state becomes
        // consistent which causes our tab labeling to be off when the "+" button
        // is used in the tab bar. This fixes that. If we can find a more robust
        // solution we should do that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            controller.relabelTabs()
        }

        // Setup our undo
        if let undoManager = parentController.undoManager {
            undoManager.setActionName("New Tab")
            undoManager.registerUndo(
                withTarget: controller,
                expiresAfter: controller.undoExpiration
            ) { target in
                // Close the tab when undoing
                undoManager.disableUndoRegistration {
                    target.closeTab(nil)
                }

                // Register redo action
                undoManager.registerUndo(
                    withTarget: tako,
                    expiresAfter: target.undoExpiration
                ) { tako in
                    _ = TerminalController.newTab(
                        tako,
                        from: parent,
                        withBaseConfig: baseConfig)
                }
            }
        }

        return controller
    }

}
