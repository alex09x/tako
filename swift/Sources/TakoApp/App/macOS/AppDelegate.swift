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
import OSLog
import UserNotifications
import TakoKit

class AppDelegate: NSObject,
                    ObservableObject,
                    NSApplicationDelegate,
                    UNUserNotificationCenterDelegate,
                    TakoAppDelegate {
    // The application logger. We should probably move this at some point to a dedicated
    // class/struct but for now it lives here! 🤷‍♂️
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.tako-core.terminal",
        category: String(describing: AppDelegate.self)
    )

    /// Various menu items so that we can programmatically sync the keyboard shortcut with the Tako config
    @IBOutlet var menuAbout: NSMenuItem?
    @IBOutlet var menuServices: NSMenu?
    @IBOutlet var menuOpenConfig: NSMenuItem?
    @IBOutlet var menuReloadConfig: NSMenuItem?
    @IBOutlet var menuSecureInput: NSMenuItem?
    @IBOutlet var menuQuit: NSMenuItem?

    @IBOutlet var menuNewWindow: NSMenuItem?
    @IBOutlet var menuNewTab: NSMenuItem?
    @IBOutlet var menuSplitRight: NSMenuItem?
    @IBOutlet var menuSplitLeft: NSMenuItem?
    @IBOutlet var menuSplitDown: NSMenuItem?
    @IBOutlet var menuSplitUp: NSMenuItem?
    @IBOutlet var menuClose: NSMenuItem?
    @IBOutlet var menuCloseTab: NSMenuItem?
    @IBOutlet var menuCloseWindow: NSMenuItem?
    @IBOutlet var menuCloseAllWindows: NSMenuItem?

    @IBOutlet var menuUndo: NSMenuItem?
    @IBOutlet var menuRedo: NSMenuItem?
    @IBOutlet var menuCopy: NSMenuItem?
    @IBOutlet var menuPaste: NSMenuItem?
    @IBOutlet var menuPasteSelection: NSMenuItem?
    @IBOutlet var menuSelectAll: NSMenuItem?
    @IBOutlet var menuSelectCommandOutput: NSMenuItem?
    @IBOutlet var menuJumpToPreviousPrompt: NSMenuItem?
    @IBOutlet var menuJumpToNextPrompt: NSMenuItem?
    @IBOutlet var menuFindParent: NSMenuItem?
    @IBOutlet var menuFind: NSMenuItem?
    @IBOutlet var menuSelectionForFind: NSMenuItem?
    @IBOutlet var menuScrollToSelection: NSMenuItem?
    @IBOutlet var menuFindNext: NSMenuItem?
    @IBOutlet var menuFindPrevious: NSMenuItem?
    @IBOutlet var menuHideFindBar: NSMenuItem?

    @IBOutlet var menuToggleVisibility: NSMenuItem?
    @IBOutlet var menuToggleFullScreen: NSMenuItem?
    @IBOutlet var menuBringAllToFront: NSMenuItem?
    @IBOutlet var menuZoomSplit: NSMenuItem?
    @IBOutlet var menuPreviousSplit: NSMenuItem?
    @IBOutlet var menuNextSplit: NSMenuItem?
    @IBOutlet var menuSelectSplitAbove: NSMenuItem?
    @IBOutlet var menuSelectSplitBelow: NSMenuItem?
    @IBOutlet var menuSelectSplitLeft: NSMenuItem?
    @IBOutlet var menuSelectSplitRight: NSMenuItem?
    @IBOutlet var menuReturnToDefaultSize: NSMenuItem?
    @IBOutlet var menuFloatOnTop: NSMenuItem?
    @IBOutlet var menuUseAsDefault: NSMenuItem?
    @IBOutlet var menuSetAsDefaultTerminal: NSMenuItem?

    @IBOutlet var menuIncreaseFontSize: NSMenuItem?
    @IBOutlet var menuDecreaseFontSize: NSMenuItem?
    @IBOutlet var menuResetFontSize: NSMenuItem?
    @IBOutlet var menuChangeTitle: NSMenuItem?
    @IBOutlet var menuChangeTabTitle: NSMenuItem?
    @IBOutlet var menuReadonly: NSMenuItem?
    @IBOutlet var menuQuickTerminal: NSMenuItem?
    @IBOutlet var menuTerminalInspector: NSMenuItem?
    @IBOutlet var menuCommandPalette: NSMenuItem?
    @IBOutlet var menuFindAll: NSMenuItem?

    @IBOutlet var menuEqualizeSplits: NSMenuItem?
    @IBOutlet var menuMoveSplitDividerUp: NSMenuItem?
    @IBOutlet var menuMoveSplitDividerDown: NSMenuItem?
    @IBOutlet var menuMoveSplitDividerLeft: NSMenuItem?
    @IBOutlet var menuMoveSplitDividerRight: NSMenuItem?

    var menuPreviousTab: NSMenuItem?
    var menuNextTab: NSMenuItem?
    var menuMoveTabLeft: NSMenuItem?
    var menuMoveTabRight: NSMenuItem?
    var menuGotoTabs: [NSMenuItem] = []

    /// The dock menu
    var dockMenu: NSMenu = NSMenu()

    /// This is only true before application has become active.
    var applicationHasBecomeActive: Bool = false

    /// This is set in applicationDidFinishLaunching with the system uptime so we can determine the
    /// seconds since the process was launched.
    var applicationLaunchTime: TimeInterval = 0

    /// This is the current configuration from the Tako configuration that we need.
    var derivedConfig: DerivedConfig = DerivedConfig()

    /// The tako global state. Only one per process.
    let tako: Tako.App

    /// The global undo manager for app-level state such as window restoration.
    lazy var undoManager = ExpiringUndoManager()

    /// The current state of the quick terminal.
    var quickTerminalControllerState: QuickTerminalState = .uninitialized

    /// Whether the quick terminal has already been initialized.
    var quickControllerInitialized: Bool {
        if case .initialized = quickTerminalControllerState {
            return true
        }
        return false
    }

    /// Our quick terminal. This starts out uninitialized and only initializes if used.
    var quickController: QuickTerminalController {
        switch quickTerminalControllerState {
        case .initialized(let controller):
            return controller

        case .pendingRestore(let state):
            let controller = QuickTerminalController(
                tako,
                position: derivedConfig.quickTerminalPosition,
                baseConfig: state.baseConfig,
                restorationState: state
            )
            quickTerminalControllerState = .initialized(controller)
            return controller

        case .uninitialized:
            let controller = QuickTerminalController(
                tako,
                position: derivedConfig.quickTerminalPosition,
                restorationState: nil
            )
            quickTerminalControllerState = .initialized(controller)
            return controller
        }
    }

    /// The elapsed time since the process was started
    var timeSinceLaunch: TimeInterval {
        return ProcessInfo.processInfo.systemUptime - applicationLaunchTime
    }

    /// Tracks the windows that we hid for toggleVisibility.
    internal(set) var hiddenState: ToggleVisibilityState?

    /// The observer for the app appearance.
    var appearanceObserver: NSKeyValueObservation?

    /// Signals
    var signals: [DispatchSourceSignal] = []

    let appIconUpdater = AppIconUpdater()
    let sessionSaver = SessionSnapshotSaver()

    @MainActor lazy var menuShortcutManager = Tako.MenuShortcutManager()

    /// Seam over `UNUserNotificationCenter.current()`. A bare `swift test`
    /// host has no bundle proxy for its process, and `.current()` crashes
    /// outright (`NSInternalInconsistencyException:
    /// bundleProxyForCurrentProcess is nil`) rather than merely behaving
    /// oddly -- so tests substitute `{ nil }` here to skip notification-center
    /// work entirely instead of touching the real singleton.
    /// Shows a modal alert and returns the button chosen. Tests answer
    /// instead: a modal alert never returns in a test host.
    var runModalAlert: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }

    /// Answers a `.terminateLater`. Tests record the answer: a real yes
    /// ends the process.
    var replyToTermination: @MainActor (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }

    static var notificationCenterProvider: () -> UNUserNotificationCenter? = {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    override init() {
        // TAKO_CONFIG_PATH names the one config file to read, in every build:
        // the README promises it, and a release build that quietly ignored it
        // is what a test driving the shipped app found.
        tako = Tako.App(configPath: ProcessInfo.processInfo.environment["TAKO_CONFIG_PATH"])
        super.init()
        // Decided here, as the delegate is created -- before NSApplication
        // finishes launching and before any window is restored: whether
        // windows come from AppKit or, after a crash, from the journal.
        MainActor.assumeIsolated {
            LayoutRecorder.begin(
                bundleID: Bundle.main.bundleIdentifier ?? "com.tako-core.terminal",
                enabled: tako.config.windowSaveState != "never"
                    && !CommandLine.arguments.contains(where: { $0.hasPrefix("--selftest") })
                    // A test host's delegates are not the app: never the
                    // user's journal, read or written.
                    && NSClassFromString("XCTestCase") == nil,
                // As AppKit would decide: the setting, else macOS's "Close
                // windows when quitting an application" (unset: it closes).
                keepsWindows: tako.config.windowSaveState == "always"
                    || (tako.config.windowSaveState != "never"
                        && UserDefaults.standard.bool(forKey: "NSQuitAlwaysKeepsWindows")))
        }

        tako.delegate = self
    }

}
