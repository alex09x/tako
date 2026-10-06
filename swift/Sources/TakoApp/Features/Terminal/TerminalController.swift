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
import Combine
import TakoKit

/// A classic, tabbed terminal experience.
class TerminalController: BaseTerminalController, TabGroupCloseCoordinator.Controller {
    override var windowNibName: NSNib.Name? {
        let defaultValue = "Terminal"

        guard let appDelegate = NSApp.delegate as? AppDelegate else { return defaultValue }
        let config = appDelegate.tako.config

        // If we have no window decorations, there's no reason to do anything but
        // the default titlebar (because there will be no titlebar).
        if !config.windowDecorations {
            return defaultValue
        }

        let nib = switch config.macosTitlebarStyle {
        case .native: "Terminal"
        case .hidden: "TerminalHiddenTitlebar"
        case .transparent: "TerminalTransparentTitlebar"
        case .tabs:
#if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                "TerminalTabsTitlebarTahoe"
            } else {
                "TerminalTabsTitlebarVentura"
            }
#else
            "TerminalTabsTitlebarVentura"
#endif
        }

        return nib
    }

    /// This is set to true when we care about frame changes. This is a small optimization since
    /// this controller registers a listener for ALL frame change notifications and this lets us bail
    /// early if we don't care.
    var tabListenForFrame: Bool = false

    /// This is the hash value of the last tabGroup.windows array. We use this to detect order
    /// changes in the list.
    var tabWindowsHash: Int = 0

    /// The initial window presentation is deferred by one runloop turn in a few places so
    /// AppKit can settle tab/window state first. Close actions must cancel it to avoid
    /// re-showing a tab that was already closed.
    var pendingInitialPresentation: DispatchWorkItem?

    /// This is set to false by init if the window managed by this controller should not be restorable.
    /// For example, terminals executing custom scripts are not restorable.
    var restorable: Bool = true

    /// The configuration derived from the Tako config so we don't need to rely on references.
    var derivedConfig: DerivedConfig

    /// Whether `window-width`/`window-height` size this window's terminal
    /// area. True for a genuinely new window; false for a new tab, which
    /// takes the size of the window group it joins instead -- upstream's
    /// `window-width`/`window-height` apply only to a new window, never a
    /// tab or a split.
    var appliesConfiguredWindowSize: Bool = true

    /// TabGroupCloseCoordinator.Controller
    lazy private(set) var tabGroupCloseCoordinator = TabGroupCloseCoordinator()

    /// The notification cancellable for focused surface property changes.
    var surfaceAppearanceCancellables: Set<AnyCancellable> = []

    /// How a freshly created controller gets its window attached before code
    /// that requires `.window` to be non-nil runs (`newWindow`, `newTab`, and
    /// undo/redo's `init(_:with:)`). Production leaves this a no-op: `.window`
    /// lazily loads the real nib on first access. `Terminal.xib` is excluded
    /// from the SwiftPM test target, so tests substitute a hook that attaches
    /// a manually built `TerminalWindow` up front, the same way
    /// `TerminalTestSupport.makeController` does, unblocking the window-
    /// dependent code paths below that would otherwise be permanently
    /// unreachable from a test host.
    struct System {
        var attachWindow: (TerminalController) -> Void = { _ in }
    }

    static var system = System()

    init(_ tako: Tako.App,
         withBaseConfig base: Tako.SurfaceConfiguration? = nil,
         withSurfaceTree tree: SplitTree<Tako.SurfaceView>? = nil,
         parent: NSWindow? = nil
    ) {
        // The window we manage is not restorable if we've specified a command
        // to execute. We do this because the restored window is meaningless at the
        // time of writing this: it'd just restore to a shell in the same directory
        // as the script. We may want to revisit this behavior when we have scrollback
        // restoration.
        self.restorable = (base?.command ?? "") == ""

        // Setup our initial derived config based on the current app config
        self.derivedConfig = DerivedConfig(tako.config)

        super.init(tako, baseConfig: base, surfaceTree: tree)

        setupTerminalNotificationObservers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        // Remove all of our notificationcenter subscriptions
        let center = NotificationCenter.default
        center.removeObserver(self)
    }

    func cancelPendingInitialPresentation() {
        pendingInitialPresentation?.cancel()
        pendingInitialPresentation = nil
    }

    func scheduleInitialPresentation(_ block: @escaping () -> Void) {
        cancelPendingInitialPresentation()

        var scheduledWorkItem: DispatchWorkItem?
        scheduledWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            defer { self.pendingInitialPresentation = nil }
            guard pendingInitialPresentation?.isCancelled == false else { return }
            block()
        }

        let workItem = scheduledWorkItem!
        pendingInitialPresentation = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    // MARK: Base Controller Overrides

    override func surfaceTreeDidChange(from: SplitTree<Tako.SurfaceView>, to: SplitTree<Tako.SurfaceView>) {
        super.surfaceTreeDidChange(from: from, to: to)

        // Whenever our surface tree changes in any way (new split, close split, etc.)
        // we want to invalidate our state.
        invalidateRestorableState()

        // Update our zoom state
        if let window = window as? TerminalWindow {
            window.surfaceIsZoomed = to.zoomed != nil
        }

        // If our surface tree is now nil then we close our window.
        if to.isEmpty {
            self.window?.close()
        }
    }

    override func replaceSurfaceTree(
        _ newTree: SplitTree<Tako.SurfaceView>,
        moveFocusTo newView: Tako.SurfaceView? = nil,
        moveFocusFrom oldView: Tako.SurfaceView? = nil,
        undoAction: String? = nil
    ) {
        // We have a special case if our tree is empty to close our tab immediately.
        // This makes it so that undo is handled properly.
        if newTree.isEmpty {
            closeTabImmediately()
            return
        }

        super.replaceSurfaceTree(
            newTree,
            moveFocusTo: newView,
            moveFocusFrom: oldView,
            undoAction: undoAction)
    }

    override func focusedSurfaceDidChange(to: Tako.SurfaceView?) {
        super.focusedSurfaceDidChange(to: to)

        // We always cancel our event listener
        surfaceAppearanceCancellables.removeAll()

        // When our focus changes, we update our window appearance based on the
        // currently focused surface.
        guard let focusedSurface else { return }
        syncAppearance(focusedSurface.derivedConfig)

        // We also want to get notified of certain changes to update our appearance.
        focusedSurface.$derivedConfig
            .dropFirst()
            .sink { [weak self, weak focusedSurface] _ in self?.syncAppearanceOnPropertyChange(focusedSurface) }
            .store(in: &surfaceAppearanceCancellables)
        focusedSurface.$backgroundColor
            .dropFirst()
            .sink { [weak self, weak focusedSurface] _ in self?.syncAppearanceOnPropertyChange(focusedSurface) }
            .store(in: &surfaceAppearanceCancellables)
    }

    private func syncAppearanceOnPropertyChange(_ surface: Tako.SurfaceView?) {
        guard let surface else { return }
        DispatchQueue.main.async { [weak self, weak surface] in
            guard let surface else { return }
            guard let self else { return }
            guard self.focusedSurface == surface else { return }
            self.syncAppearance(surface.derivedConfig)
        }
    }

    override func syncAppearance() {
        // When our focus changes, we update our window appearance based on the
        // currently focused surface.
        guard let focusedSurface else { return }
        syncAppearance(focusedSurface.derivedConfig)
    }

    /// This is called anytime a node in the surface tree is being removed.
    override func closeSurface(
        _ node: SplitTree<Tako.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        // If this isn't the root then we're dealing with a split closure.
        if surfaceTree.root != node {
            super.closeSurface(node, withConfirmation: withConfirmation)
            return
        }

        // More than 1 window means we have tabs and we're closing a tab
        if let window, Tako.CustomTabGroup.group(for: window).windows.count > 1 {
            if withConfirmation {
                closeTab(nil)
            } else {
                closeTabImmediately()
            }
            return
        }

        // Default implementation handles standard window closing
        super.closeSurface(node, withConfirmation: withConfirmation)
    }

    // MARK: - NSMenuItemValidation

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(closeTabsOnTheRight):
            guard let window else { return false }
            let tabGroup = Tako.CustomTabGroup.group(for: window)
            guard let currentIndex = tabGroup.windows.firstIndex(of: window) else { return false }
            return tabGroup.windows.indices.contains { $0 > currentIndex }

        case #selector(returnToDefaultSize):
            guard let window else { return false }

            // Native fullscreen windows can't revert to default size.
            if window.styleMask.contains(.fullScreen) {
                return false
            }

            // If we're fullscreen at all then we can't change size
            if fullscreenStyle?.isFullscreen ?? false {
                return false
            }

            // If our window is already the default size or we don't have a
            // default size, then disable.
            return defaultSize?.isChanged(for: window) ?? false

        default:
            return super.validateMenuItem(item)
        }
    }

    struct DerivedConfig {
        let backgroundColor: Color
        let macosWindowButtons: Tako.MacOSWindowButtons
        let macosTitlebarStyle: Tako.Config.MacOSTitlebarStyle
        let maximize: Bool
        let windowPositionX: Int16?
        let windowPositionY: Int16?

        init() {
            self.backgroundColor = Color(NSColor.windowBackgroundColor)
            self.macosWindowButtons = .visible
            self.macosTitlebarStyle = .default
            self.maximize = false
            self.windowPositionX = nil
            self.windowPositionY = nil
        }

        init(_ config: Tako.Config) {
            self.backgroundColor = config.backgroundColor
            self.macosWindowButtons = config.macosWindowButtons
            self.macosTitlebarStyle = config.macosTitlebarStyle
            self.maximize = config.maximize
            self.windowPositionX = config.windowPositionX
            self.windowPositionY = config.windowPositionY
        }
    }
}
