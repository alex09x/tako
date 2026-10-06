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

extension BaseTerminalController {
    var containingWindow: NSWindow? { self.window }

    var focusFollowsMouse: Bool {
        self.derivedConfig.focusFollowsMouse
    }
    func computeTitle(title: String, bell: Bool) -> String {
        var result = title
        if bell && tako.config.bellFeatures.contains(.title) {
            result = "🔔 \(result)"
        }

        return result
    }

    func titleDidChange(to: String) {
        lastComputedTitle = to
        applyTitleToWindow()
    }

    func applyTitleToWindow() {
        guard let window else { return }

        // A title the user set for this tab beats everything else.
        if let titleOverride {
            window.title = computeTitle(
                title: titleOverride,
                bell: focusedSurface?.bell ?? false)
            return
        }

        // `title` in the configuration fixes the title: the terminal is not
        // allowed to change it. The window is given this once when it is
        // created, but a surface reporting its own title through OSC 0/2 --
        // which every shell integration does, immediately -- used to
        // overwrite it a moment later, so the setting looked like it did
        // nothing at all.
        if let configured = derivedConfig.title {
            window.title = computeTitle(
                title: configured,
                bell: focusedSurface?.bell ?? false)
            return
        }

        window.title = lastComputedTitle
    }

    func pwdDidChange(to: URL?) {
        guard let window else { return }

        if derivedConfig.macosTitlebarProxyIcon == .visible {
            // Use the 'to' URL directly
            window.representedURL = to
        } else {
            window.representedURL = nil
        }
    }

    func cellSizeDidChange(to: NSSize) {
        guard derivedConfig.windowStepResize else { return }
        // Stage manager can sometimes present windows in such a way that the
        // cell size is temporarily zero due to the window being tiny. We can't
        // set content resize increments to this value, so avoid an assertion failure.
        guard to.width > 0 && to.height > 0 else { return }
        self.window?.contentResizeIncrements = to
    }

    func performSplitAction(_ action: TerminalSplitOperation) {
        switch action {
        case .resize(let resize):
            splitDidResize(node: resize.node, to: resize.ratio)
        case .drop(let drop):
            splitDidDrop(source: drop.payload, destination: drop.destination, zone: drop.zone)
        }
    }

    func splitDidResize(node: SplitTree<Tako.SurfaceView>.Node, to newRatio: Double) {
        let resizedNode = node.resizing(to: newRatio)
        do {
            surfaceTree = try surfaceTree.replacing(node: node, with: resizedNode)
        } catch {
            Tako.logger.warning("failed to replace node during split resize: \(error, privacy: .public)")
        }
    }

    func splitDidDrop(
        source: Tako.SurfaceView,
        destination: Tako.SurfaceView,
        zone: TerminalSplitDropZone
    ) {
        // Map drop zone to split direction
        let direction: SplitTree<Tako.SurfaceView>.NewDirection = switch zone {
        case .top: .up
        case .bottom: .down
        case .left: .left
        case .right: .right
        }

        // Check if source is in our tree
        if let sourceNode = surfaceTree.root?.node(view: source) {
            // Source is in our tree - same window move
            let treeWithoutSource = surfaceTree.removing(sourceNode)
            let newTree: SplitTree<Tako.SurfaceView>
            do {
                newTree = try treeWithoutSource.inserting(view: source, at: destination, direction: direction)
            } catch {
                Tako.logger.warning("failed to insert surface during drop: \(error, privacy: .public)")
                return
            }

            replaceSurfaceTree(
                newTree,
                moveFocusTo: source,
                moveFocusFrom: focusedSurface,
                undoAction: "Move Split")
            return
        }

        // Source is not in our tree - search other windows
        var sourceController: BaseTerminalController?
        var sourceNode: SplitTree<Tako.SurfaceView>.Node?
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            guard controller !== self else { continue }
            if let node = controller.surfaceTree.root?.node(view: source) {
                sourceController = controller
                sourceNode = node
                break
            }
        }

        guard let sourceController, let sourceNode else {
            Tako.logger.warning("source surface not found in any window during drop")
            return
        }

        // Remove from source controller's tree and add it to our tree.
        // We do this first because if there is an error then we can
        // abort.
        let newTree: SplitTree<Tako.SurfaceView>
        do {
            newTree = try surfaceTree.inserting(view: source, at: destination, direction: direction)
        } catch {
            Tako.logger.warning("failed to insert surface during cross-window drop: \(error, privacy: .public)")
            return
        }

        // Treat our undo below as a full group.
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Move Split")
        defer {
            undoManager?.endUndoGrouping()
        }

        // Remove the node from the source.
        sourceController.removeSurfaceNode(sourceNode)

        // Add in the surface to our tree
        replaceSurfaceTree(
            newTree,
            moveFocusTo: source,
            moveFocusFrom: focusedSurface)
    }

    func performAction(_ action: String, on surfaceView: Tako.SurfaceView) {
        guard !action.isEmpty else { return }
        if !surfaceView.performBindingAction(action) {
            NSSound.beep()
        }
    }

    // MARK: Fullscreen

    /// Toggle fullscreen for the given mode.
    func toggleFullscreen(mode: FullscreenMode) {
        // We need a window to fullscreen
        guard let window = self.window else { return }

        // If we have a previous fullscreen style initialized, we want to check if
        // our mode changed. If it changed and we're in fullscreen, we exit so we can
        // toggle it next time. If it changed and we're not in fullscreen we can just
        // switch the handler.
        var newStyle = mode.style(for: window)
        newStyle?.delegate = self
        old: if let oldStyle = self.fullscreenStyle {
            // If we're not fullscreen, we can nil it out so we get the new style
            if !oldStyle.isFullscreen {
                self.fullscreenStyle = newStyle
                break old
            }

            assert(oldStyle.isFullscreen)

            // We consider our mode changed if the types change (obvious) but
            // also if its nil (not obvious) because nil means that the style has
            // likely changed but we don't support it.
            if newStyle == nil || type(of: newStyle!) != type(of: oldStyle) {
                // Our mode changed. Exit fullscreen (since we're toggling anyways)
                // and then set the new style for future use
                oldStyle.exit()
                self.fullscreenStyle = newStyle

                // We're done
                return
            }

            // Style is the same.
        } else {
            // We have no previous style
            self.fullscreenStyle = newStyle
        }
        guard let fullscreenStyle else { return }

        if fullscreenStyle.isFullscreen {
            fullscreenStyle.exit()
        } else {
            fullscreenStyle.enter()
        }
    }

    func fullscreenDidChange() {
        guard fullscreenStyle != nil else { return }

        // Always resync our appearance
        syncAppearance()
    }

    // MARK: Clipboard Confirmation

    @objc private func onConfirmClipboardRequest(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Tako.SurfaceView else { return }
        guard self.surfaceTree.contains(target) else { return }
        if target != self.focusedSurface {
            self.focusedSurface = target
            self.window?.makeFirstResponder(target)
        }

        // We need a window
        guard let window = self.window else { return }

        // Check whether we use non-native fullscreen
        guard let str = notification.userInfo?[Tako.Notification.ConfirmClipboardStrKey] as? String else { return }
        let state = notification.userInfo?[Tako.Notification.ConfirmClipboardStateKey] as? UnsafeMutableRawPointer?
        guard let request = notification.userInfo?[Tako.Notification.ConfirmClipboardRequestKey] as? Tako.ClipboardRequest else { return }

        // If we already have a clipboard confirmation view up, we ignore this request.
        // This shouldn't be possible...
        guard self.clipboardConfirmation == nil else {
            return
        }

        // Show our paste confirmation
        let cc = ClipboardConfirmationController(
            surfaceView: target,
            contents: str,
            request: request,
            state: state ?? nil,
            delegate: self
        )
        self.clipboardConfirmation = cc
        guard let ccWindow = cc.window else { return }
        window.beginSheet(ccWindow)
    }

    func clipboardConfirmationComplete(_ action: ClipboardConfirmationView.Action, _ request: Tako.ClipboardRequest) {
        // End our clipboard confirmation no matter what
        guard let cc = self.clipboardConfirmation else { return }
        self.clipboardConfirmation = nil

        // Close the sheet
        if let ccWindow = cc.window {
            window?.endSheet(ccWindow)
        }

        switch request {
        case let .osc_52_write(pasteboard):
            guard case .confirm = action else { break }
            let pb = pasteboard ?? NSPasteboard.general
            pb.declareTypes([.string], owner: nil)
            pb.setString(cc.contents, forType: .string)
        case .osc_52_read, .paste:
            switch action {
            case .cancel:
                // Cancel: dismiss without emitting characters to the PTY
                if let surface = cc.surface {
                    Tako.App.completeClipboardRequest(surface, data: "", state: cc.state, confirmed: false)
                }
            case .confirm:
                if let surfaceView = cc.surfaceView {
                    Tako.App.completeClipboardRequest(surfaceView, data: cc.contents, state: cc.state, confirmed: true)
                } else if let surface = cc.surface {
                    Tako.App.completeClipboardRequest(surface, data: cc.contents, state: cc.state, confirmed: true)
                }
            }
        }
    }

}
