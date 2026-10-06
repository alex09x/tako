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
import Combine
import TakoKit

struct DerivedConfig {
        let macosTitlebarProxyIcon: Tako.MacOSTitlebarProxyIcon
        let windowStepResize: Bool
        let focusFollowsMouse: Bool
        let splitPreserveZoom: Tako.Config.SplitPreserveZoom
        /// A title fixed in the configuration. When set, the terminal cannot
        /// change the window title.
        let title: String?

        init() {
            self.macosTitlebarProxyIcon = .visible
            self.windowStepResize = false
            self.focusFollowsMouse = false
            self.splitPreserveZoom = .init()
            self.title = nil
        }

        init(_ config: Tako.Config) {
            self.macosTitlebarProxyIcon = config.macosTitlebarProxyIcon
            self.windowStepResize = config.windowStepResize
            self.focusFollowsMouse = config.focusFollowsMouse
            self.splitPreserveZoom = config.splitPreserveZoom
            self.title = config.title
        }
}
}

extension BaseTerminalController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(find(_:)), #selector(findNext(_:)), #selector(findPrevious(_:)),
             #selector(findHide(_:)), #selector(selectionForFind(_:)), #selector(scrollToSelection(_:)):
            // The same answer the surface gives when it is first responder;
            // the controller only sees these while the find bar has the keys.
            return focusedSurface?.validateFindItem(item.action) ?? false

        case #selector(increaseFontSize(_:)), #selector(decreaseFontSize(_:)),
             #selector(resetFontSize(_:)), #selector(resetTerminal(_:)):
            return focusedSurface != nil

        case #selector(toggleTerminalInspector(_:)):
            // Unsupported: there is no inspector to show.
            return false

        case #selector(toggleNotificationCenter(_:)):
            return true

        case #selector(toggleSessionSidebar(_:)):
            if let menu = item as? NSMenuItem {
                menu.state = sessionSidebarIsShowing ? .on : .off
            }
            return true

        case #selector(togglePaneOverview(_:)):
            if let menu = item as? NSMenuItem {
                menu.state = paneOverviewIsShowing ? .on : .off
            }
            return true

        case #selector(jumpToLatestUnread(_:)):
            return NotificationStore.shared.latestUnread() != nil

        case #selector(markFocusedPaneRead(_:)):
            guard let focused = focusedSurface else { return false }
            return NotificationStore.shared.unreadCount(for: focused.id) > 0

        case #selector(markAllRead(_:)):
            return NotificationStore.shared.totalUnreadCount() > 0

        case #selector(jumpToNextAttention(_:)),
             #selector(jumpToPreviousAttention(_:)):
            return AttentionManager.shared.hasAnyUnseenAttention()

        case #selector(goBackToPreviousPane(_:)):
            return AttentionManager.shared.canGoBack

        case #selector(toggleAttentionMute(_:)):
            guard let surface = focusedSurface else { return false }
            item.title = surface.isAttentionMuted ? "Unmute Attention" : "Mute Attention"
            item.state = surface.isAttentionMuted ? .on : .off
            return true

        default:
            return true
        }
    }

    // MARK: - Surface Color Scheme

    /// Update the surface tree's color scheme only when it actually changes.
    ///
    /// Calling ``tako_surface_set_color_scheme`` triggers
    /// ``syncAppearance(_:)`` via notification,
    /// so we avoid redundant calls.
    func updateColorSchemeForSurfaceTree() {
        /// Derive the target scheme from `window-theme` or system appearance.
        /// We set the scheme on surfaces so they pick the correct theme
        /// and let ``syncAppearance(_:)`` update the window accordingly.
        ///
        /// Using App's effectiveAppearance here to prevent incorrect updates.
        let themeAppearance = NSApplication.shared.effectiveAppearance
        let scheme: tako_color_scheme_e
        if themeAppearance.isDark {
            scheme = TAKO_COLOR_SCHEME_DARK
        } else {
            scheme = TAKO_COLOR_SCHEME_LIGHT
        }
        guard scheme != appliedColorScheme else {
            return
        }
        for surfaceView in surfaceTree {
            if let surface = surfaceView.surface {
                tako_surface_set_color_scheme(surface, scheme)
            }
        }
        appliedColorScheme = scheme
    }
}

// MARK: Combine Methods

extension BaseTerminalController {
    /// Publishes an app-wide notification whenever this terminal window's aggregate
    /// bell state changes.
    func setupBellNotificationPublisher() {
        bellStateCancellable = surfaceValuesPublisher(valueKeyPath: \.bell, publisherKeyPath: \.$bell)
            .map { $0.values.contains(true) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasBell in
                guard let self else { return }
                bell = hasBell
                NotificationCenter.default.post(
                    name: .terminalWindowBellDidChangeNotification,
                    object: self,
                    userInfo: [Notification.Name.terminalWindowHasBellKey: hasBell]
                )
            }
    }

    /// Subscribes to the shared SessionSidebarStore.isShowing publisher so all controllers
    /// and tabs remain in sync when sidebar visibility is toggled (B5).
    func setupSidebarStatePublisher() {
        sidebarStateCancellable = SessionSidebarStore.shared.$isShowing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] showing in
                guard let self, self.sessionSidebarIsShowing != showing else { return }
                self.sessionSidebarIsShowing = showing
            }
    }

    /// Creates a publisher for values on all surfaces in this controller's tree.
    ///
    /// The publisher emits a dictionary of surface IDs to values whenever the tree changes
    /// or any surface publishes a new value for the key path.
    func surfaceValuesPublisher<Value>(
        valueKeyPath: KeyPath<Tako.SurfaceView, Value>,
        publisherKeyPath: KeyPath<Tako.SurfaceView, Published<Value>.Publisher>
    ) -> AnyPublisher<[Tako.SurfaceView.ID: Value], Never> {
        // `surfaceTree` can be replaced entirely when splits are added/removed/closed.
        // For each tree snapshot we build a fresh publisher that watches all surfaces
        // in that snapshot.
        $surfaceTree
            .map { tree in
                tree.valuesPublisher(
                    valueKeyPath: valueKeyPath,
                    publisherKeyPath: publisherKeyPath
                )
            }
            // Keep only the latest tree publisher active. This automatically cancels
            // subscriptions for old/removed surfaces when the tree changes.
            .switchToLatest()
            .eraseToAnyPublisher()
    }
}

// MARK: Notifications

extension Notification.Name {
    /// Terminal window aggregate bell state changed.
    static let terminalWindowBellDidChangeNotification = Notification.Name("com.tako-core.terminal.terminalWindowBellDidChange")
    static let terminalWindowHasBellKey = terminalWindowBellDidChangeNotification.rawValue + ".hasBell"
}
