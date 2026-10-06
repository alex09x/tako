/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Cocoa
import SwiftUI
import TakoKit

/// Controller for the "quick" terminal.
class QuickTerminalController: BaseTerminalController {
    override var windowNibName: NSNib.Name? { "QuickTerminal" }

    /// The position for the quick terminal.
    let position: QuickTerminalPosition

    /// The current state of the quick terminal
    var visible: Bool = false

    /// The previously running application when the terminal is shown. This is NEVER Tako.
    /// If this is set then when the quick terminal is animated out then we will restore this
    /// application to the front.
    var previousApp: NSRunningApplication?

    // The active space when the quick terminal was last shown.
    var previousActiveSpace: CGSSpace?

    /// Cache for per-screen window state.
    let screenStateCache: QuickTerminalScreenStateCache

    /// Non-nil if we have hidden dock state.
    var hiddenDock: HiddenDock?

    /// The configuration derived from the Tako config so we don't need to rely on references.
    var derivedConfig: DerivedConfig

    /// Tracks if we're currently handling a manual resize to prevent recursion
    private var isHandlingResize: Bool = false

    /// This is set to false by init if the window managed by this controller should not be restorable.
    /// For example, terminals executing custom scripts are not restorable.
    let restorable: Bool
    var restorationState: QuickTerminalRestorableState?

    init(_ tako: Tako.App,
         position: QuickTerminalPosition = .top,
         baseConfig base: Tako.SurfaceConfiguration? = nil,
         restorationState: QuickTerminalRestorableState? = nil,
    ) {
        self.position = position
        self.derivedConfig = DerivedConfig(tako.config)
        // The window we manage is not restorable if we've specified a command
        // to execute. We do this because the restored window is meaningless at the
        // time of writing this: it'd just restore to a shell in the same directory
        // as the script. We may want to revisit this behavior when we have scrollback
        // restoration.
        restorable = (base?.command ?? "") == ""
        self.restorationState = restorationState
        self.screenStateCache = QuickTerminalScreenStateCache(stateByDisplay: restorationState?.screenStateEntries ?? [:])
        // Important detail here: we initialize with an empty surface tree so
        // that we don't start a terminal process. This gets started when the
        // first terminal is shown in `animateIn`.
        super.init(tako, baseConfig: base, surfaceTree: .init())

        // Setup our notifications for behaviors
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(applicationWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onToggleFullscreen(notification:)),
            name: Tako.Notification.takoToggleFullscreen,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(takoConfigDidChange(_:)),
            name: .takoConfigDidChange,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(closeWindow(_:)),
            name: .takoCloseWindow,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onNewTab),
            name: Tako.Notification.takoNewTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        // Remove all of our notificationcenter subscriptions
        let center = NotificationCenter.default
        center.removeObserver(self)

        // Make sure we restore our hidden dock
        hiddenDock = nil
    }

    // MARK: NSWindowController

    override func windowDidLoad() {
        super.windowDidLoad()
        guard let window = self.window else { return }

        // The controller is the window delegate so we can detect events such as
        // window close so we can animate out.
        window.delegate = self

        // The quick window is restored by `screenStateCache`.
        // We disable this for better control
        window.isRestorable = false

        // Setup our configured appearance that we support.
        syncAppearance()

        // Setup our initial size based on our configured position
        position.setLoaded(window, size: derivedConfig.quickTerminalSize)

        // Upon first adding this Window to its host view, older SwiftUI
        // seems to have a "hiccup" and corrupts the frameRect,
        // sometimes setting the size to zero, sometimes corrupting it.
        // We pass the actual window's frame as "initial" frame directly
        // to the window, so it can use that instead of the frameworks
        // "interpretation"
        if let qtWindow = window as? QuickTerminalWindow {
            qtWindow.initialFrame = window.frame
        }

        // Setup our content
        window.contentView = TerminalViewContainer {
            TerminalView(tako: tako, viewModel: self, delegate: self)
        }

        // Clear out our frame at this point, the fixup from above is complete.
        if let qtWindow = window as? QuickTerminalWindow {
            qtWindow.initialFrame = nil
        }

        // Animate the window in
        animateIn()
    }

    // MARK: NSWindowDelegate

    override func windowDidBecomeKey(_ notification: Notification) {
        super.windowDidBecomeKey(notification)

        // If we're not visible we don't care to run the logic below. It only
        // applies if we can be seen.
        guard visible else { return }

        terminalViewContainer?.updateGlassTintOverlay(isKeyWindow: true)

        // Re-hide the dock if we were hiding it before.
        hiddenDock?.hide()
    }

    override func windowDidResignKey(_ notification: Notification) {
        super.windowDidResignKey(notification)

        // If we're not visible then we don't want to run any of the logic below
        // because things like resetting our previous app assume we're visible.
        // windowDidResignKey will also get called after animateOut so this
        // ensures we don't run logic twice.
        guard visible else { return }

        terminalViewContainer?.updateGlassTintOverlay(isKeyWindow: false)

        // We don't animate out if there is a modal sheet being shown currently.
        // This lets us show alerts without causing the window to disappear.
        guard window?.attachedSheet == nil else { return }

        // If our app is still active, then it means that we're switching
        // to another window within our app, so we remove the previous app
        // so we don't restore it.
        if NSApp.isActive {
            self.previousApp = nil
        }

        // Regardless of autohide, we always want to bring the dock back
        // when we lose focus.
        hiddenDock?.restore()

        if derivedConfig.quickTerminalAutoHide {
            switch derivedConfig.quickTerminalSpaceBehavior {
            case .remain:
                // If we lose focus on the active space, then we can animate out
                animateOut()

            case .move:
                let currentActiveSpace = CGSSpace.active()
                if previousActiveSpace == currentActiveSpace {
                    // We haven't moved spaces. We lost focus to another app on the
                    // current space. Animate out.
                    animateOut()
                } else {
                    // We've moved to a different space.

                    // If we're fullscreen, we need to exit fullscreen because the visible
                    // bounds may have changed causing a new behavior.
                    if let fullscreenStyle, fullscreenStyle.isFullscreen {
                        fullscreenStyle.exit()
                        DispatchQueue.main.async {
                            self.onToggleFullscreen()
                        }
                    }

                    // Make the window visible again on this space
                    DispatchQueue.main.async {
                        self.window?.makeKeyAndOrderFront(nil)
                    }

                    self.previousActiveSpace = currentActiveSpace
                }
            }
        }
    }

    override func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == self.window,
              visible,
              !isHandlingResize else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }

        // Prevent recursive loops
        isHandlingResize = true
        defer { isHandlingResize = false }

        switch position {
        case .top, .bottom, .center:
            // For centered positions (top, bottom, center), we need to recenter the window
            // when it's manually resized to maintain proper positioning
            let newOrigin = position.centeredOrigin(for: window, on: screen)
            window.setFrameOrigin(newOrigin)
        case .left, .right:
            // For side positions, we may need to adjust vertical centering
            let newOrigin = position.verticallyCenteredOrigin(for: window, on: screen)
            window.setFrameOrigin(newOrigin)
        }
    }

    // MARK: Base Controller Overrides

    override func focusSurface(_ view: Tako.SurfaceView) {
        if visible {
            // If we're visible, we just focus the surface as normal.
            super.focusSurface(view)
            return
        }
        // Check if target surface belongs to this quick terminal
        guard surfaceTree.contains(view) else { return }
        // Set the target surface as focused
        DispatchQueue.main.async {
            Tako.moveFocus(to: view)
        }
        // Animation completion handler will handle window/app activation
        animateIn()
    }

    override func surfaceTreeDidChange(from: SplitTree<Tako.SurfaceView>, to: SplitTree<Tako.SurfaceView>) {
        super.surfaceTreeDidChange(from: from, to: to)

        // If our surface tree is nil then we animate the window out. We
        // defer reinitializing the tree to save some memory here.
        if to.isEmpty {
            animateOut()
            return
        }

        // If we're not empty (e.g. this isn't the first set) and we're
        // not visible, then we animate in. This allows us to show the quick
        // terminal when things such as undo/redo are done.
        if !from.isEmpty && !visible {
            animateIn()
            return
        }
    }

    override func closeSurface(
        _ node: SplitTree<Tako.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        // If this isn't the root then we're dealing with a split closure.
        if surfaceTree.root != node {
            super.closeSurface(node, withConfirmation: withConfirmation)
            return
        }

        // If this isn't a final leaf then we're dealing with a split closure
        guard case .leaf(let surface) = node else {
            super.closeSurface(node, withConfirmation: withConfirmation)
            return
        }

        // If its the root, we check if the process exited. If it did,
        // then we do empty the tree.
        if surface.processExited {
            surfaceTree = .init()
            return
        }

        // If its the root then we just animate out. We never actually allow
        // the surface to fully close.
        animateOut()
    }

    /// Every quick terminal surface -- the first and every split -- is
    /// marked as one, and kept out of session persistence: the quick
    /// terminal is not restored on relaunch, so a session kept for it would
    /// outlive Tako with nothing to come back to.
    static func surfaceConfiguration(_ base: Tako.SurfaceConfiguration?) -> Tako.SurfaceConfiguration {
        var config = base ?? Tako.SurfaceConfiguration()
        config.environmentVariables["TAKO_QUICK_TERMINAL"] = "1"
        config.allowsSessionPersistence = false
        return config
    }

    override func newSplit(
        at oldView: Tako.SurfaceView,
        direction: SplitTree<Tako.SurfaceView>.NewDirection,
        baseConfig config: Tako.SurfaceConfiguration? = nil
    ) -> Tako.SurfaceView? {
        return super.newSplit(at: oldView, direction: direction, baseConfig: Self.surfaceConfiguration(config))
    }


    override func syncAppearance() {
        guard let window else { return }

        defer { updateColorSchemeForSurfaceTree() }
        // Change the collection behavior of the window depending on the configuration.
        window.collectionBehavior = derivedConfig.quickTerminalSpaceBehavior.collectionBehavior

        // If our window is not visible, then no need to sync the appearance yet.
        // Some APIs such as window blur have no effect unless the window is visible.
        guard window.isVisible else { return }

        // If we have window transparency then set it transparent. Otherwise set it opaque.
        // Also check if the user has overridden transparency to be fully opaque.
        if !isBackgroundOpaque && (self.derivedConfig.backgroundOpacity < 1 || derivedConfig.backgroundBlur.isGlassStyle) {
            window.isOpaque = false

            // This is weird, but we don't use ".clear" because this creates a look that
            // matches Terminal.app much more closer. This lets users transition from
            // Terminal.app more easily.
            window.backgroundColor = .white.withAlphaComponent(0.001)

            if !derivedConfig.backgroundBlur.isGlassStyle {
                tako_set_window_background_blur(tako.app, Unmanaged.passUnretained(window).toOpaque())
            }
        } else {
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
        }

        terminalViewContainer?.takoConfigDidChange(tako.config, preferredBackgroundColor: nil)
    }


    @IBAction override func closeWindow(_ sender: Any) {
        // Instead of closing the window, we animate it out.
        animateOut()
    }

}
