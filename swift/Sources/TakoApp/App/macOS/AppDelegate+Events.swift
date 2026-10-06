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

extension AppDelegate {
    // MARK: Notifications and Events

    /// This handles events from the NSEvent.addLocalEventMonitor. We use this so we can get
    /// events without any terminal windows open.
    // Widened from `private` so tests can drive it directly: the only real
    // caller is the local NSEvent monitor `applicationDidFinishLaunching`
    // installs, and that registration is never removed (it's discarded via
    // `_ =`, matching upstream), so calling it more than once across the
    // test suite isn't an option to reach it indirectly and repeatably.
    func localEventHandler(_ event: NSEvent) -> NSEvent? {
        return switch event.type {
        case .keyDown:
            localEventKeyDown(event)

        default:
            event
        }
    }

    func localEventKeyDown(_ event: NSEvent) -> NSEvent? {
        // If the tab overview is visible and escape is pressed, close it.
        // This can't POSSIBLY be right and is probably a FirstResponder problem
        // that we should handle elsewhere in our program. But this works and it
        // is guarded by the tab overview currently showing.
        if event.keyCode == 0x35, // Escape key
           let window = NSApp.keyWindow,
           let tabGroup = window.tabGroup,
           tabGroup.isOverviewVisible {
            window.toggleTabOverview(nil)
            return nil
        }

        // If we have a main window then we don't process any of the keys
        // because we let it capture and propagate.
        guard NSApp.mainWindow == nil else { return event }

        // If this event as-is would result in a key binding then we send it.
        if let app = tako.app, let config = tako.config.config {
            var takoEvent = event.takoKeyEvent(TAKO_ACTION_PRESS)
            let match = (event.characters ?? "").withCString { ptr in
                takoEvent.text = ptr
                if !tako_config_key_is_binding(config, takoEvent) {
                    return false
                }

                return tako_app_key(app, takoEvent)
            }

            // If the key was handled by Tako we stop the event chain. If
            // the key wasn't handled then we let it fall through and continue
            // processing. This is important because some bindings may have no
            // affect at this scope.
            if match {
                return nil
            }
        }

        // If this event would be handled by our menu then we do nothing.
        if let mainMenu = NSApp.mainMenu,
           mainMenu.performKeyEquivalent(with: event) {
            return nil
        }

        // If we reach this point then we try to process the key event
        // through the Tako key mechanism.

        // Tako must be loaded
        guard let tako = self.tako.app else { return event }

        // Build our event input and call tako
        if tako_app_key(tako, event.takoKeyEvent(TAKO_ACTION_PRESS)) {
            // The key was used so we want to stop it from going to our Mac app
            Tako.logger.debug("local key event handled event=\(event, privacy: .public)")
            return nil
        }

        return event
    }

    @objc func windowDidBecomeKey(_ notification: Notification) {
        syncFloatOnTopMenu(notification.object as? NSWindow)
    }

    @objc func quickTerminalDidChangeVisibility(_ notification: Notification) {
        guard let quickController = notification.object as? QuickTerminalController else { return }
        self.menuQuickTerminal?.state = if quickController.visible { .on } else { .off }
    }

    @objc func takoConfigDidChange(_ notification: Notification) {
        // We only care if the configuration is a global configuration, not a surface one.
        guard notification.object == nil else { return }

        // Get our managed configuration object out
        guard let config = notification.userInfo?[
            Notification.Name.TakoConfigChangeKey
        ] as? Tako.Config else { return }

        takoConfigDidChange(config: config)
    }

    @objc func takoBellDidRing(_ notification: Notification) {
        if tako.config.bellFeatures.contains(.system) {
            NSSound.beep()
        }

        if tako.config.bellFeatures.contains(.audio) {
            if let configPath = tako.config.bellAudioPath,
               let sound = NSSound(contentsOfFile: configPath.path, byReference: false) {
                sound.volume = tako.config.bellAudioVolume
                sound.play()
            }
        }

        if tako.config.bellFeatures.contains(.attention) {
            // Bounce the dock icon if we're not focused.
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    @objc func terminalWindowHasBell(_ notification: Notification) {
        guard notification.object is BaseTerminalController else { return }
        syncDockBadge()
    }

    func requestBadgeAuthorizationAndSet(_ center: UNUserNotificationCenter) {
        center.requestAuthorization(options: [.badge]) { granted, error in
            if let error = error {
                Self.logger.warning("Error requesting badge authorization: \(error, privacy: .public)")
                return
            }

            // Permission granted, set the badge
            if granted {
                DispatchQueue.main.async {
                    self.setDockBadge()
                }
            }
        }
    }

    /// What to do about the Dock badge given the notification settings.
    enum DockBadgeStep: Equatable {
        /// Set it.
        case set
        /// Ask for badge permission, then set it if granted.
        case requestAuthorization
        /// Leave it alone.
        case none
    }

    /// Authorized with badges on: set it. Authorized but badges "not
    /// supported" (a sandbox may say so) or not asked yet: ask, then set.
    /// Denied, provisional, ephemeral or unknown: leave it.
    static func dockBadgeStep(
        status: UNAuthorizationStatus, badgeSetting: UNNotificationSetting
    ) -> DockBadgeStep {
        switch status {
        case .authorized:
            switch badgeSetting {
            case .enabled: return .set
            case .notSupported: return .requestAuthorization
            default: return .none
            }
        case .notDetermined:
            return .requestAuthorization
        default:
            return .none
        }
    }

    func syncDockBadge() {
        guard let center = Self.notificationCenterProvider() else { return }
        center.getNotificationSettings { settings in
            switch Self.dockBadgeStep(status: settings.authorizationStatus, badgeSetting: settings.badgeSetting) {
            case .set:
                DispatchQueue.main.async { self.setDockBadge() }
            case .requestAuthorization:
                self.requestBadgeAuthorizationAndSet(center)
            case .none:
                break
            }
        }
    }

    @objc func takoNewWindow(_ notification: Notification) {
        let configAny = notification.userInfo?[Tako.Notification.NewSurfaceConfigKey]
        let config = configAny as? Tako.SurfaceConfiguration
        _ = TerminalController.newWindow(tako, withBaseConfig: config)
    }

    @objc func takoNewTab(_ notification: Notification) {
        guard let surfaceView = notification.object as? Tako.SurfaceView else { return }
        guard let window = surfaceView.window else { return }

        // We only want to listen to new tabs if the focused parent is
        // a regular terminal controller.
        guard window.windowController is TerminalController else { return }

        let configAny = notification.userInfo?[Tako.Notification.NewSurfaceConfigKey]
        let config = configAny as? Tako.SurfaceConfiguration

        _ = TerminalController.newTab(tako, from: window, withBaseConfig: config)
    }

    @MainActor
    func setDockBadge() {
        guard let app = NSApp else { return }
        let unreadCount = NotificationStore.shared.totalUnreadCount()
        var label: String? = unreadCount > 0 ? (unreadCount > 99 ? "99+" : String(unreadCount)) : nil

        if label == nil {
            let bellCount = app.windows
                .compactMap { $0.windowController as? BaseTerminalController }
                .reduce(0) { $0 + ($1.bell ? 1 : 0) }
            let wantsBadge = tako.config.bellFeatures.contains(.attention) && bellCount > 0
            label = wantsBadge ? (bellCount > 99 ? "99+" : String(bellCount)) : nil
        }
        if label == nil, tako.config.progressStyle.showsInDock {
            let allSurfaces = ControlCommands.panes().map { $0.surface }
            if let agg = Tako.CrabTabBinding.aggregateProgress(for: allSurfaces) {
                switch agg.state {
                case .none: break
                case .normal:
                    if let p = agg.progress { label = "\(p)%" }
                case .error:
                    label = agg.progress.map { "\($0)%!" } ?? "!"
                case .paused:
                    label = agg.progress.map { "\($0)%||" } ?? "||"
                case .indeterminate:
                    label = "..."
                }
            }
        }
        app.dockTile.badgeLabel = label
        app.dockTile.display()
    }

    func takoConfigDidChange(config: Tako.Config) {
        // remote-control takes effect at once: off stops serving, on/local
        // changes who is answered, without a restart.
        let remoteControl = config.remoteControl
        DispatchQueue.main.async { ControlCommands.apply(mode: remoteControl) }
        // Update the config we need to store
        self.derivedConfig = DerivedConfig(config)

        // Depending on the "window-save-state" setting we have to set the NSQuitAlwaysKeepsWindows
        // configuration. This is the only way to carefully control whether macOS invokes the
        // state restoration system.
        switch config.windowSaveState {
        case "never": UserDefaults.tako.setValue(false, forKey: "NSQuitAlwaysKeepsWindows")
        case "always": UserDefaults.tako.setValue(true, forKey: "NSQuitAlwaysKeepsWindows")
        case "default": fallthrough
        default: UserDefaults.tako.removeObject(forKey: "NSQuitAlwaysKeepsWindows")
        }

        // Config could change keybindings, so update everything that depends on that
        DispatchQueue.main.async {
            self.syncMenuShortcuts(config)
        }
        TerminalController.all.forEach { $0.relabelTabs() }

        // Update our badge since config can change what we show.
        syncDockBadge()

        // Config could change window appearance. We wrap this in an async queue because when
        // this is called as part of application launch it can deadlock with an internal
        // AppKit mutex on the appearance.
        DispatchQueue.main.async { self.syncAppearance(config: config) }

        // Decide whether to hide/unhide app from dock and app switcher
        switch config.macosHidden {
        case .never:
            NSApp.setActivationPolicy(.regular)

        case .always:
            NSApp.setActivationPolicy(.accessory)
        }

        // If we have configuration errors, we need to show them.
        let c = ConfigurationErrorsController.sharedInstance
        c.errors = config.errors
        if c.errors.count > 0 {
            if c.window == nil || !c.window!.isVisible {
                c.showWindow(self)
            }
        }

        // We need to handle our global event tap depending on if there are global
        // events that we care about in Tako.
        if tako_app_has_global_keybinds(tako.app!) {
            if timeSinceLaunch > 5 {
                // If the process has been running for awhile we enable right away
                // because no windows are likely to pop up.
                GlobalEventTap.shared.enable()
            } else {
                // If the process just started, we wait a couple seconds to allow
                // the initial windows and so on to load so our permissions dialog
                // doesn't get buried.
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) {
                    GlobalEventTap.shared.enable()
                }
            }
        } else {
            GlobalEventTap.shared.disable()
        }

        updateAppIcon(from: config)
    }

    /// Sync the appearance of our app with the theme specified in the config.
    func syncAppearance(config: Tako.Config) {
        NSApplication.shared.appearance = .init(takoConfig: config)
    }

    func updateAppIcon(from config: Tako.Config) {
        Task.detached {
            await self.appIconUpdater.update(icon: AppIcon(config: config))
        }
    }

}
