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
    func closeWindowImmediately() {
        guard let window = window else { return }

        cancelPendingInitialPresentation()

        let tabGroup = Tako.CustomTabGroup.group(for: window)
        let windows: [NSWindow] = tabGroup.windows
        let controllers = windows.compactMap { $0.windowController as? TerminalController }

        // When closing the last window with quit-after-last-window-closed enabled,
        // closing the window means closing the application. Routing through NSApp.terminate
        // allows persistent sessions to be safely detached and window layout to be saved
        // so everything restores on next launch, while cleanly terminating the process.
        if controllers.count >= TerminalController.all.count && tako.config.shouldQuitAfterLastWindowClosed {
            NSApp.terminate(nil)
            return
        }

        registerUndoForCloseWindow()

        windows.forEach { window in
            if let controller = window.windowController as? TerminalController {
                controller.cancelPendingInitialPresentation()
                controller.undoManager?.removeAllActions(withTarget: controller)
            }
            window.close()
        }
    }

    /// Registers undo for closing window(s), handling both single windows and tab groups.
    func registerUndoForCloseWindow() {
        guard let undoManager, undoManager.isUndoRegistrationEnabled else { return }
        guard let window else { return }

        // If we don't have a tab group or we don't have multiple tabs, then
        // do a normal single window close.
        let tabGroup = Tako.CustomTabGroup.group(for: window)
        guard tabGroup.windows.count > 1 else {
            // No tabs, just save this window's state
            if let undoState {
                // Register undo action to restore the window
                undoManager.setActionName("Close Window")
                undoManager.registerUndo(
                    withTarget: tako,
                    expiresAfter: undoExpiration) { tako in
                        // Restore the undo state
                        let newController = TerminalController(tako, with: undoState)

                        // Register redo action
                        undoManager.registerUndo(
                            withTarget: newController,
                            expiresAfter: newController.undoExpiration) { target in
                                target.closeWindowImmediately()
                            }
                    }
            }

            return
        }

        // Multiple windows in tab group - collect all undo states in sorted order
        // by tab ordering. Also track which window was key.
        let undoStates = tabGroup.windows
            .compactMap { tabWindow -> UndoState? in
                guard let controller = tabWindow.windowController as? TerminalController,
                      var undoState = controller.undoState else { return nil }
                // Clear the tab group reference since it is unneeded. It should be
                // garbage collected but we want to be extra sure we don't try to
                // restore into it because we're going to recreate it.
                undoState.tabGroup = nil
                return undoState
            }
            .sorted { (lhs, rhs) in
                switch (lhs.tabIndex, rhs.tabIndex) {
                case let (l?, r?): return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return true
                }
            }

        // Find the index of the key window in our sorted states. This is a bit verbose
        // but we only need this for this style of undo so we don't want to add it to
        // UndoState.
        let keyWindowIndex: Int?
        if let keyWindow = tabGroup.windows.first(where: { $0.isKeyWindow }),
            let keyController = keyWindow.windowController as? TerminalController,
            let keyUndoState = keyController.undoState {
            keyWindowIndex = undoStates.firstIndex {
                $0.tabIndex == keyUndoState.tabIndex }
        } else {
            keyWindowIndex = nil
        }

        // Register undo action to restore all windows
        guard !undoStates.isEmpty else { return }

        undoManager.setActionName("Close Window")
        undoManager.registerUndo(
            withTarget: tako,
            expiresAfter: undoExpiration
        ) { tako in
            // Restore all windows in the tab group
            let controllers = undoStates.map { undoState in
                TerminalController(tako, with: undoState)
            }

            // The first controller becomes the parent window for all tabs.
            // If we don't have a first controller (shouldn't be possible?)
            // then we can't restore tabs.
            guard let firstController = controllers.first else { return }

            // Add all subsequent controllers as tabs to the first window.
            // Not selected yet -- the loop below picks the one real key
            // window, and selecting each as it's added would just mean
            // showing and immediately re-hiding every one but the last.
            for controller in controllers.dropFirst() {
                controller.showWindow(nil)
                if let firstWindow = firstController.window,
                   let newWindow = controller.window {
                    Tako.CustomTabGroup.join(newWindow, to: firstWindow, select: false)
                }
            }

            // Make the appropriate window key. If we had a key window, restore it.
            // Otherwise, make the last window key.
            if let firstWindow = firstController.window {
                let group = Tako.CustomTabGroup.group(for: firstWindow)
                if let keyWindowIndex, keyWindowIndex < controllers.count,
                   let keyWindow = controllers[keyWindowIndex].window {
                    group.select(keyWindow)
                } else if let lastWindow = controllers.last?.window {
                    group.select(lastWindow)
                }
            }

            // Register redo action on the first controller
            undoManager.registerUndo(
                withTarget: firstController,
                expiresAfter: firstController.undoExpiration
            ) { target in
                target.closeWindowImmediately()
            }
        }
    }

    /// Close all windows, asking for confirmation if necessary.
    static func closeAllWindows() {
        // The window we use for confirmations. Try to find the first window that
        // needs quit confirmation. This lets us attach the confirmation to something
        // that is running.
        guard let confirmWindow = all
            .first(where: { $0.surfaceTree.contains(where: { $0.needsConfirmClose }) })?
            .surfaceTree.first(where: { $0.needsConfirmClose })?
            .window
        else {
            closeAllWindowsImmediately()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Close All Windows?"
        alert.informativeText = "All terminal sessions will be terminated."
        alert.addButton(withTitle: "Close All Windows")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: confirmWindow, completionHandler: { response in
            if response == .alertFirstButtonReturn {
                // This is important so that we avoid losing focus when Stage
                // Manager is used.
                alert.window.orderOut(nil)
                closeAllWindowsImmediately()
            }
        })
    }

    static private func closeAllWindowsImmediately() {
        let undoManager = (NSApp.delegate as? AppDelegate)?.undoManager
        undoManager?.beginUndoGrouping()
        all.forEach { $0.closeWindowImmediately() }
        undoManager?.setActionName("Close All Windows")
        undoManager?.endUndoGrouping()
    }

    // MARK: Undo/Redo

    /// The state that we require to recreate a TerminalController from an undo.
    struct UndoState {
        let frame: NSRect
        let surfaceTree: SplitTree<Tako.SurfaceView>
        let focusedSurface: UUID?
        let tabIndex: Int?
        weak var tabGroup: Tako.CustomTabGroup?
        let tabColor: TerminalTabColor
    }

    convenience init(_ tako: Tako.App, with undoState: UndoState) {
        self.init(tako, withSurfaceTree: undoState.surfaceTree)
        Self.system.attachWindow(self)

        // Show the window and restore its frame
        showWindow(nil)
        if let window {
            window.setFrame(undoState.frame, display: true)
            if let terminalWindow = window as? TerminalWindow {
                terminalWindow.tabColor = undoState.tabColor
            }

            // If we have a tab group and index, restore the tab to its original position
            if let tabGroup = undoState.tabGroup,
               let tabIndex = undoState.tabIndex {
                if tabIndex < tabGroup.windows.count {
                    // Find the window that is currently at that index
                    let currentWindow = tabGroup.windows[tabIndex]
                    Tako.CustomTabGroup.insert(window, into: currentWindow, at: tabIndex, select: true)
                } else if let last = tabGroup.windows.last {
                    Tako.CustomTabGroup.join(window, to: last, select: true)
                }
            }

            // Restore focus to the previously focused surface
            if let focusedUUID = undoState.focusedSurface,
               let focusTarget = surfaceTree.first(where: { $0.id == focusedUUID }) {
                DispatchQueue.main.async {
                    Tako.moveFocus(to: focusTarget, from: nil)
                }
            } else if let focusedSurface = surfaceTree.first {
                // No prior focused surface or we can't find it, let's focus
                // the first.
                self.focusedSurface = focusedSurface
                DispatchQueue.main.async {
                    Tako.moveFocus(to: focusedSurface, from: nil)
                }
            }
        }
    }

    /// The current undo state for this controller
    var undoState: UndoState? {
        guard let window else { return nil }
        guard !surfaceTree.isEmpty else { return nil }
        let tabGroup = Tako.CustomTabGroup.group(for: window)
        return .init(
            frame: window.frame,
            surfaceTree: surfaceTree,
            focusedSurface: focusedSurface?.id,
            tabIndex: tabGroup.windows.firstIndex(of: window),
            tabGroup: tabGroup,
            tabColor: (window as? TerminalWindow)?.tabColor ?? .none)
    }

}
