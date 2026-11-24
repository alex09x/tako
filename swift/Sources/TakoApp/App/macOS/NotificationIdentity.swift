/*
 * tako — Which Tako builds register with macOS Notification Center
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// macOS keeps one row in System Settings › Notifications for every bundle
/// id that ever touched Notification Center, and never removes it. Test,
/// demo and preview builds use their own ids -- some a new one per run -- so
/// each left another «Tako» row behind. Only Tako itself
/// (`com.tako-core.terminal`) registers; any other build stays out of
/// Notification Center unless started with `TAKO_NOTIFICATIONS=1`.
enum NotificationIdentity {
    static let production = "com.tako-core.terminal"
    static let optIn = "TAKO_NOTIFICATIONS"

    static func registers(bundleID: String?, environment: [String: String]) -> Bool {
        guard let bundleID else { return false }
        return bundleID == production || environment[optIn] == "1"
    }
}
