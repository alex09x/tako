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
import UserNotifications
import TakoKit

@MainActor
extension AppDelegate {
    // MARK: - NSApplicationDelegate

    func applicationWillFinishLaunching(_ notification: Notification) {
        Tako.registerTooltipDelay()
        // Before any window is restored: each terminal's shell is told where
        // the control socket is.
        ControlCommands.apply(mode: tako.config.remoteControl,
                              bundleID: Bundle.main.bundleIdentifier ?? "com.tako-core.terminal")
        #if DEBUG
        if
            let suite = UserDefaults.takoSuite,
            let clear = ProcessInfo.processInfo.environment["TAKO_CLEAR_USER_DEFAULTS"],
            (clear as NSString).boolValue {
            UserDefaults.tako.removePersistentDomain(forName: suite)
        }
        #endif
        UserDefaults.tako.register(defaults: [
            // Disable the automatic full screen menu item because we handle
            // it manually.
            "NSFullScreenMenuItemEverywhere": false,

            // On macOS 26 RC1, the autofill heuristic controller causes unusable levels
            // of slowdowns and CPU usage in the terminal window under certain [unknown]
            // conditions. We don't know exactly why/how. This disables the full heuristic
            // controller.
            //
            // Practically, this means things like SMS autofill don't work, but that is
            // a desirable behavior to NOT have happen for a terminal, so this is a win.
            // Manual autofill via the `Edit => AutoFill` menu item still work as expected.
            "NSAutoFillHeuristicControllerEnabled": false,
        ])
    }

    func sessionSaveSettings() -> SessionSnapshotSaver.Settings {
        .init(enabled: tako.config.windowSaveContent,
              limit: tako.config.windowSaveContentLimit,
              secureInput: SecureInput.shared.global)
    }

    /// The surfaces of the windows AppKit restores. The quick terminal is
    /// not one of them.
    static func restorableSurfaces() -> [Tako.SurfaceView] {
        TerminalController.all.flatMap { Array($0.surfaceTree) }
    }

    /// All surfaces that are currently alive and owned by the UI.
    func allLiveSurfaces() -> [Tako.SurfaceView] {
        var surfaces = Self.restorableSurfaces()
        if case .initialized(let qc) = quickTerminalControllerState {
            surfaces.append(contentsOf: qc.surfaceTree)
        }
        return surfaces
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Restore privacy before capturing layout or starting snapshot saves.
        if UserDefaults.tako.bool(forKey: "SecureInput") != SecureInput.shared.global {
            toggleSecureInput(self)
        }
        LayoutRecorder.finishLaunching(app: tako)
        NotificationCenter.default.addObserver(self, selector: #selector(workspacePersistenceFailed(_:)),
                                               name: .takoWorkspacePersistenceFailed, object: WorkspaceStore.shared)
        NotificationCenter.default.addObserver(self, selector: #selector(layoutPersistenceFailed(_:)),
                                               name: .takoLayoutPersistenceFailed, object: nil)
        // A partial restore is not proof that absent tabs were closed. Keep
        // their workspace associations so their sessions can be recovered.
        if !SessionPlaces.isSelfTest {
            sessionSaver.onSaveFailure = { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    guard let window = AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows)
                            ?? TerminalController.preferredParent?.window else { return }
                    _ = await TerminalDialogView.choose(in: window, title: "Saved Screens Not Updating",
                        lines: TUIText.plain("Tako could not preserve or write a saved screen. Recent output may not be saved; check storage before quitting.", width: 56),
                        choices: [.init(title: "OK", kind: .normal)], cancelIndex: 0, theme: self.tako.config.theme)
                }
            }
            sessionSaver.start(
                settings: { [unowned self] in self.sessionSaveSettings() },
                surfaces: { Self.restorableSurfaces() })
        }
        // A live session absent from the restored layout is recoverable,
        // not evidence that the user closed it.
        if !SessionPlaces.isSelfTest,
           tako.config.sessionPersistence || !WorkspaceStore.shared.persistenceAvailable || !LayoutRecorder.persistenceAvailable {
            DispatchQueue.main.async {
                SessionRecoveryPresentation.scanAndPresent(
                    app: self.tako, openIDs: SessionRecoveryPresentation.protectedSurfaceIDs(Self.restorableSurfaces()))
            }
        }
        // Never kill unclaimed runtimes at launch: a missing or incomplete
        // layout can leave still-running sessions without a restored surface.
        // System settings overrides
        UserDefaults.tako.register(defaults: [
            // Disable this so that repeated key events make it through to our terminal views.
            "ApplePressAndHoldEnabled": false,
        ])

        // Store our start time
        applicationLaunchTime = ProcessInfo.processInfo.systemUptime

        // Initial config loading
        takoConfigDidChange(config: tako.config)

        // Register our service provider. This must happen after everything is initialized.
        NSApp.servicesProvider = ServiceProvider()

        // Configure terminal dialog handlers to route all alerts and link confirmations through TerminalDialogView
        Self.configureTerminalDialogHandlers()

        // This registers the Tako => Services menu to exist.
        NSApp.servicesMenu = menuServices

        // Setup a local event monitor for app-level keyboard shortcuts. See
        // localEventHandler for more info why.
        _ = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown],
            handler: localEventHandler)

        // Notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(quickTerminalDidChangeVisibility),
            name: .quickTerminalDidChangeVisibility,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(takoConfigDidChange(_:)),
            name: .takoConfigDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(takoBellDidRing(_:)),
            name: .takoBellDidRing,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(terminalWindowHasBell(_:)),
            name: .terminalWindowBellDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(takoNewWindow(_:)),
            name: Tako.Notification.takoNewWindow,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(takoNewTab(_:)),
            name: Tako.Notification.takoNewTab,
            object: nil)
        NotificationCenter.default.addObserver(
            forName: .takoWorkspaceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setupWorkspaceTopLevelMenu()
            }
        }

        // Configure user notifications
        let actions = [
            UNNotificationAction(identifier: Tako.userNotificationActionShow, title: "Show")
        ]

        if let center = Self.notificationCenterProvider() {
            center.setNotificationCategories([
                UNNotificationCategory(
                    identifier: Tako.userNotificationCategory,
                    actions: actions,
                    intentIdentifiers: [],
                    options: [.customDismissAction]
                )
            ])
            center.delegate = self
        }

        // Observe our appearance so we can report the correct value to libtako.
        self.appearanceObserver = NSApplication.shared.observe(
            \.effectiveAppearance,
             options: [.new, .initial]
        ) { _, change in
            guard let appearance = change.newValue else { return }
            guard let app = self.tako.app else { return }
            let scheme: tako_color_scheme_e
            if appearance.isDark {
                scheme = TAKO_COLOR_SCHEME_DARK
            } else {
                scheme = TAKO_COLOR_SCHEME_LIGHT
            }

            tako_app_set_color_scheme(app, scheme)
        }

        // Setup our menu
        setupMenuImages()
        setupWhatsNewMenuItem()
        setupUpdateMenuItem()
        setupCommandLineToolMenuItem()
        setupAgentHooksMenuItem()
        setupPromptNavigationMenuItems()
        setupNotificationMenuItems()
        setupSidebarMenuItem()
        setupPaneOverviewMenuItem()
        setupAttentionMenuItems()
        setupWorkspaceTopLevelMenu()
        NotificationCenter.default.addObserver(
            forName: .takoWorkspaceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setupWorkspaceTopLevelMenu()
            }
        }
        setupDiagnosticsMenuItem()
        setDockBadge()
        WhatsNewNotice.offerAtLaunch(theme: tako.config.theme)
        CommandLineTool.offerAtLaunch(theme: tako.config.theme)
        AgentHooksTool.offerAtLaunch(theme: tako.config.theme)

        // Setup signal handlers
        setupSignals()

        // Check for updates in the background, unless this launch should not.
        if AppUpdater.checksAtLaunch(
            arguments: CommandLine.arguments,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            enabled: tako.config.autoUpdateEnabled
        ) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                AppUpdater.shared.checkForUpdates(silent: true)
                Task { @MainActor in
                    AppUpdater.shared.startPeriodicChecks()
                }
            }
        }

        switch Tako.launchSource {
        case .app:
            if CommandLine.arguments.contains(where: { $0.hasPrefix("--selftest") }) {
                applicationDidBecomeActive(.init(name: NSApplication.didBecomeActiveNotification))
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }

        case .zig_run, .cli:
            // Part of launch services (clicking an app, using `open`, etc.) activates
            // the application and brings it to the front. When using the CLI we don't
            // get this behavior, so we have to do it manually.

            // This never gets called until we click the dock icon. This forces it
            // activate immediately.
            applicationDidBecomeActive(.init(name: NSApplication.didBecomeActiveNotification))

            // We run in the background, this forces us to the front.
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                NSApp.unhide(nil)
                NSApp.arrangeInFront(nil)
            }
        }
    }

    @objc private func workspacePersistenceFailed(_ notification: Notification) {
        Task { @MainActor in
            guard let window = AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows)
                    ?? TerminalController.preferredParent?.window else { return }
            _ = await TerminalDialogView.choose(in: window, title: "Workspaces Not Saved",
                lines: TUIText.plain("Tako could not save workspace changes. Check storage before quitting; an earlier copy was kept when possible.", width: 56),
                choices: [.init(title: "OK", kind: .normal)], cancelIndex: 0, theme: tako.config.theme)
        }
    }

    @objc private func layoutPersistenceFailed(_ notification: Notification) {
        Task { @MainActor in
            guard let window = AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows)
                    ?? TerminalController.preferredParent?.window else { return }
            _ = await TerminalDialogView.choose(in: window, title: "Window Layout Not Saved",
                lines: TUIText.plain("Tako could not save the current window layout. Check storage before quitting; an earlier copy was kept when possible.", width: 56),
                choices: [.init(title: "OK", kind: .normal)], cancelIndex: 0, theme: tako.config.theme)
        }
    }

    func applicationDidHide(_ notification: Notification) {
        // Keep track of our hidden state to restore properly
        self.hiddenState = .init()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // If we're back manually then clear the hidden state because macOS handles it.
        self.hiddenState = nil

        // First launch stuff
        if !applicationHasBecomeActive {
            applicationHasBecomeActive = true

            // Let's launch our first window. We only do this if we have no other windows. It
            // is possible to have other windows in a few scenarios:
            //   - if we're opening a URL since `application(_:openFile:)` is called before this.
            //   - if we're restoring from persisted state
            if TerminalController.all.isEmpty && derivedConfig.initialWindow {
                undoManager.disableUndoRegistration()
                _ = TerminalController.newWindow(tako)
                undoManager.enableUndoRegistration()
            }
        }
    }
}
