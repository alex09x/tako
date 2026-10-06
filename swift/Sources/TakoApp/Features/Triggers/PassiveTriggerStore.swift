/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation
import UserNotifications

/// Central registry and dispatcher for passive regex triggers (Track E7).
/// Strictly passive: rules can highlight text or trigger notifications when unfocused;
/// never injects keystrokes, commands, or automated input into the terminal.
@MainActor
public final class PassiveTriggerStore {
    public static let shared = PassiveTriggerStore()

    private var configTriggers: [TerminalRegexTrigger] = []
    private var dynamicTriggers: [TerminalRegexTrigger] = []

    /// Cooldown tracking to prevent notification storms from repetitive output matches:
    /// [Key(surfaceId:triggerId): lastNotificationTimestamp]
    private var lastNotificationTimes: [String: Date] = [:]
    private let notificationCooldownSeconds: TimeInterval = 3.0

    private init() {}

    /// All active triggers (config-defined + dynamic).
    public var allTriggers: [TerminalRegexTrigger] {
        configTriggers + dynamicTriggers
    }

    /// Sets triggers loaded from user configuration files.
    public func setConfigTriggers(_ triggers: [TerminalRegexTrigger]) {
        guard self.configTriggers != triggers else { return }
        self.configTriggers = triggers
        NotificationCenter.default.post(name: .passiveTriggersDidChange, object: nil)
    }

    /// Registers a dynamic trigger (e.g. via takoctl).
    public func addDynamicTrigger(_ trigger: TerminalRegexTrigger) {
        dynamicTriggers.append(trigger)
        NotificationCenter.default.post(name: .passiveTriggersDidChange, object: nil)
    }

    /// Removes a trigger by its unique ID.
    public func removeTrigger(id: UUID) {
        dynamicTriggers.removeAll { $0.id == id }
        configTriggers.removeAll { $0.id == id }
        NotificationCenter.default.post(name: .passiveTriggersDidChange, object: nil)
    }

    /// Clears all dynamically registered triggers.
    public func clearDynamicTriggers() {
        dynamicTriggers.removeAll()
        NotificationCenter.default.post(name: .passiveTriggersDidChange, object: nil)
    }

    /// Handles a matched trigger event emitted from terminal output.
    /// Posts a system notification if the trigger includes the notify action and unfocused conditions are met.
    public func handleMatch(
        surfaceId: UUID,
        paneTitle: String,
        pwd: String?,
        trigger: TerminalRegexTrigger,
        matchedText: String,
        isUnfocused: Bool,
        now: Date = Date()
    ) {
        guard trigger.action.notifies else { return }

        // Must respect unfocused requirement
        if trigger.onlyUnfocused && !isUnfocused {
            return
        }

        // Rate-limiting / deduplication per surface and trigger
        let cooldownKey = "\(surfaceId.uuidString.lowercased()):\(trigger.id.uuidString.lowercased())"
        if let lastTime = lastNotificationTimes[cooldownKey], now.timeIntervalSince(lastTime) < notificationCooldownSeconds {
            return
        }
        lastNotificationTimes[cooldownKey] = now

        let sanitizedText = Tako.sanitizeNotificationText(matchedText, maxLength: 200)
        guard !sanitizedText.isEmpty else { return }

        let title = trigger.notificationTitle ?? (trigger.pattern.isEmpty ? "Pattern matched" : "Trigger: \(trigger.pattern)")
        let project = Tako.projectFromWorkingDirectory(pwd, fallbackTitle: paneTitle)

        let content = UNMutableNotificationContent()
        content.title = Tako.sanitizeNotificationText(title, maxLength: 80)
        content.subtitle = project
        content.body = sanitizedText
        content.userInfo = [
            Tako.notificationSurfaceKey: surfaceId.uuidString,
            Tako.notificationPaneTitleKey: paneTitle,
            Tako.notificationProjectKey: project,
            "trigger_id": trigger.id.uuidString,
            "trigger_pattern": trigger.pattern
        ]

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        AppDelegate.notificationCenterProvider()?.add(request)
        Tako.onNotificationPosted?(request)

        // Also add to in-app NotificationCenter panel (Track B4)
        NotificationStore.shared.addNotification(
            id: UUID().uuidString,
            surfaceId: surfaceId,
            paneTitle: paneTitle,
            title: title,
            body: sanitizedText,
            time: now
        )
    }

    /// Reset all state (useful for tests).
    public func resetForTesting() {
        configTriggers.removeAll()
        dynamicTriggers.removeAll()
        lastNotificationTimes.removeAll()
    }
}
