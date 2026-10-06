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
    struct SavedFrame {
        let window: NSRect
        let screen: NSRect
    }
    override var undoManager: ExpiringUndoManager? {
        // This should be set via the delegate method windowWillReturnUndoManager
        if let result = window?.undoManager as? ExpiringUndoManager {
            return result
        }

        // If the window one isn't set, we fallback to our global one.
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            return appDelegate.undoManager
        }

        return nil
    }
    func windowFrameDidChange() {
        // We need to update our saved frame information in case of monitor
        // changes (see didChangeScreenParameters notification).
        savedFrame = nil
        guard let window, let screen = window.screen else { return }
        savedFrame = .init(window: window.frame, screen: screen.visibleFrame)
    }

    // MARK: Local Events

    // Not `private`: tests call this directly with synthetic `NSEvent`s --
    // the real path only fires through a local event monitor, which
    // requires an actual hardware key event to reach a test host.
    func localEventHandler(_ event: NSEvent) -> NSEvent? {
        return switch event.type {
        case .flagsChanged:
            localEventFlagsChanged(event)

        default:
            event
        }
    }

    func localEventFlagsChanged(_ event: NSEvent) -> NSEvent? {
        var surfaces: [Tako.SurfaceView] = surfaceTree.map { $0 }

        // If we're the main window receiving key input, then we want to avoid
        // calling this on our focused surface because that'll trigger a double
        // flagsChanged call.
        if NSApp.mainWindow == window {
            surfaces = surfaces.filter { $0 != focusedSurface }
        }

        for surface in surfaces {
            surface.flagsChanged(with: event)
        }

        return event
    }

    // MARK: NSWindowController

    override func windowDidLoad() {
        super.windowDidLoad()

        // Setup our undo manager.

        // Everything beyond here is setting up the window
        guard let window else { return }

        // We always initialize our fullscreen style to native if we can because
        // initialization sets up some state (i.e. observers). If its set already
        // somehow we don't do this.
        if fullscreenStyle == nil {
            fullscreenStyle = NativeFullscreen(window)
            fullscreenStyle?.delegate = self
        }
    }

    // MARK: NSWindowDelegate

    /// Check whether window should be closed without showing an alert
    /// `quitting`: the app is quitting, which with persistent sessions ends
    /// nothing; closing a window ends what runs in it.
    func windowCanBeClosedWithoutConfirmation(quitting: Bool = false) -> Bool {
        // We must have a window. Is it even possible not to?
        guard let window = self.window else { return true }

        // If we have no surfaces, close.
        if surfaceTree.isEmpty { return true }

        // If we already have an alert, continue with it
        guard alert == nil else { return false }

        // If our surfaces don't require confirmation, close.
        if !surfaceTree.contains(where: { quitting ? $0.needsConfirmQuit : $0.needsConfirmClose }) { return true }

        return false
    }

    // This is called when performClose is called on a window (NOT when close()
    // is called directly). performClose is called primarily when UI elements such
    // as the "red X" are pressed.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !windowCanBeClosedWithoutConfirmation() else {
            return true
        }
        // We require confirmation, so show an alert as long as we aren't already.
        confirmClose(
            messageText: "Close Terminal?",
            informativeText: "The terminal still has a running process. If you close the terminal the process will be killed."
        ) { [weak self] in
            self?.window?.close()
        }

        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window else { return }

        // Emit a final bell-state transition so any observers can clear state
        // without separately tracking NSWindow lifecycle events.
        if bell {
            bell = false
            NotificationCenter.default.post(
                name: .terminalWindowBellDidChangeNotification,
                object: self,
                userInfo: [Notification.Name.terminalWindowHasBellKey: false]
            )
        }

        // I don't know if this is required anymore. We previously had a ref cycle between
        // the view and the window so we had to nil this out to break it but I think this
        // may now be resolved. We should verify that no memory leaks and we can remove this.
        window.contentView = nil

        // Make sure we clean up all our undos
        window.undoManager?.removeAllActions(withTarget: self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // If when we become key our first responder is the window itself, then we
        // want to move focus to our focused terminal surface. This works around
        // various weirdness with moving surfaces around.
        if let window, window.firstResponder == window, let focusedSurface {
            DispatchQueue.main.async {
                Tako.moveFocus(to: focusedSurface)
            }
        }

        // Becoming key can race with responder updates when activating a window.
        // Sync on the next runloop so split focus has settled first.
        DispatchQueue.main.async {
            self.syncFocusToSurfaceTree()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Becoming/losing key means we have to notify our surface(s) that we have focus
        // so things like cursors blink, pty events are sent, etc.
        self.syncFocusToSurfaceTree()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        syncSurfaceTreeOcclusionState()
    }

    func syncSurfaceTreeOcclusionState() {
        let visible = self.window?.occlusionState.contains(.visible) ?? false
        for view in surfaceTree {
            if let surface = view.surface, view.isWindowVisible != visible {
                tako_surface_set_occlusion(surface, visible)
                view.isWindowVisible = visible
            }
        }
    }

    func windowDidResize(_ notification: Notification) {
        windowFrameDidChange()
    }

    func windowDidMove(_ notification: Notification) {
        windowFrameDidChange()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return nil }
        return appDelegate.undoManager
    }

}
