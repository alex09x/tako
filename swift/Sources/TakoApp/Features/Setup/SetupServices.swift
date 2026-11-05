/*
 * tako — Setup capability checks and explicit actions
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import UserNotifications

struct SetupCLIStatus: Equatable {
    var installed: Bool
    var detail: String
    var failure: String?
}

struct SetupNotificationStatus: Equatable, Sendable {
    enum Access: Equatable, Sendable { case notAsked, denied, allowed, unavailable }
    var access: Access
    var alerts = false
    var sounds = false
    var badges = false
    var failure: String?
    var title: String {
        switch access {
        case .notAsked: "Not enabled"
        case .denied: "Off in macOS"
        case .allowed: alerts && sounds && badges ? "Enabled" : "Partly enabled"
        case .unavailable: "Unavailable"
        }
    }
}

@MainActor
struct SetupServices {
    var checkCLI: () -> SetupCLIStatus
    var installCLI: () -> SetupCLIStatus
    var checkAgents: () async -> [SetupAgentService.Status]
    var connectAgents: ([String]) async -> [SetupAgentService.Status]
    var checkNotifications: () async -> SetupNotificationStatus
    var enableNotifications: () async -> SetupNotificationStatus
    var openNotificationSettings: () -> Void
    var sendTestNotification: () async -> String? = { "Test notifications are unavailable." }

    static func live(defaults: UserDefaults = .tako) -> Self {
        Self(checkCLI: cliStatus, installCLI: {
            guard let bundled = CommandLineTool.bundled else {
                return SetupCLIStatus(installed: false, detail: "The app's takoctl could not be found.", failure: "Reinstall the complete Tako app, then try again.")
            }
            guard let path = CommandLineTool.install(bundled: bundled) else {
                return SetupCLIStatus(installed: false, detail: "takoctl wasn't installed.",
                    failure: "No safe, writable installation location was found. Check the existing takoctl file or your bin directory permissions, then try again.")
            }
            var result = cliStatus()
            result.detail = path
            return result
        }, checkAgents: {
            await SetupAgentService.statuses()
        }, connectAgents: { ids in
            await SetupAgentService.connect(ids: ids)
        }, checkNotifications: notificationStatus, enableNotifications: {
            defaults.set(true, forKey: SetupProgressStore.notificationOptInKey)
            guard let center = AppDelegate.notificationCenterProvider() else {
                return SetupNotificationStatus(access: .unavailable)
            }
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                return await notificationStatus()
            } catch {
                var result = await notificationStatus()
                result.failure = error.localizedDescription
                return result
            }
        }, openNotificationSettings: {
            guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
            NSWorkspace.shared.open(url)
        }, sendTestNotification: {
            guard let center = AppDelegate.notificationCenterProvider() else { return "Notification service is unavailable." }
            do {
                try await center.add(testNotificationRequest())
                return nil
            } catch { return error.localizedDescription }
        })
    }

    static func testNotificationRequest() -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Tako test notification"
        content.body = "Your notification test is ready. Tako can let you know when work needs attention."
        content.sound = .default
        // This is an explicit user-requested test, including while setup is in front.
        content.userInfo = [Tako.notificationFromControlKey: true]
        return UNNotificationRequest(identifier: "tako-setup-test-\(UUID().uuidString)", content: content, trigger: nil)
    }

    private static func cliStatus() -> SetupCLIStatus {
        guard let bundled = CommandLineTool.bundled else {
            return SetupCLIStatus(installed: false, detail: "The app's takoctl could not be found.", failure: nil)
        }
        let installed = CommandLineTool.isInstalled(bundled: bundled)
        return SetupCLIStatus(installed: installed,
                              detail: installed ? "Linked to this copy of Tako." : "Available inside Tako; optional installation makes it available to other terminal apps.")
    }

    private static func notificationStatus() async -> SetupNotificationStatus {
        guard let center = AppDelegate.notificationCenterProvider() else {
            return SetupNotificationStatus(access: .unavailable)
        }
        return await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                let access: SetupNotificationStatus.Access
                switch settings.authorizationStatus {
                case .notDetermined: access = .notAsked
                case .denied: access = .denied
                case .authorized, .provisional: access = .allowed
                @unknown default: access = .unavailable
                }
                continuation.resume(returning: SetupNotificationStatus(access: access,
                    alerts: settings.alertSetting == .enabled,
                    sounds: settings.soundSetting == .enabled,
                    badges: settings.badgeSetting == .enabled))
            }
        }
    }
}
