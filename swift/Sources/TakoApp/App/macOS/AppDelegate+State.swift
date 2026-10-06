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
import UserNotifications
import TakoKit

    // MARK: - Restorable State

    /// We support NSSecureCoding for restorable state. Required as of macOS Sonoma (14) but a good idea anyways.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func application(_ app: NSApplication, willEncodeRestorableState coder: NSCoder) {
        guard tako.config.windowSaveState != "never" else { return }

        // Encode our quick terminal state if we have it.
        switch quickTerminalControllerState {
        case .initialized(let controller) where controller.restorable:
            let data = QuickTerminalRestorableState(from: controller)
            data.encode(with: coder)

        case .pendingRestore(let state):
            state.encode(with: coder)

        default:
            break
        }
    }

    func application(_ app: NSApplication, didDecodeRestorableState coder: NSCoder) {
        Self.logger.debug("application will restore window state")

        // Decode our quick terminal state.
        if tako.config.windowSaveState != "never",
            let state = QuickTerminalRestorableState(coder: coder) {
            quickTerminalControllerState = .pendingRestore(state)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive: UNNotificationResponse,
        withCompletionHandler: () -> Void
    ) {
        tako.handleUserNotification(response: didReceive)
        withCompletionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent: UNNotification,
        withCompletionHandler: (UNNotificationPresentationOptions) -> Void
    ) {
        let shouldPresent = tako.shouldPresentNotification(notification: willPresent)
        let options: UNNotificationPresentationOptions = shouldPresent ? [.banner, .sound] : []
        withCompletionHandler(options)
    }

    // MARK: - TakoAppDelegate

    func findSurface(forUUID uuid: UUID) -> Tako.SurfaceView? {
        for c in TerminalController.all {
            for view in c.surfaceTree where view.id == uuid {
                return view
            }
        }

        return nil
    }

    // MARK: - Global State

    func setSecureInput(_ mode: Tako.SetSecureInput) {
        let input = SecureInput.shared
        switch mode {
        case .on:
            input.global = true

        case .off:
            input.global = false

        case .toggle:
            input.global.toggle()
        }
        self.menuSecureInput?.state = if input.global { .on } else { .off }
        UserDefaults.tako.set(input.global, forKey: "SecureInput")
    }

