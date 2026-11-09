/*
 * tako — Application presentation preferences independent of terminal themes
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// Global presentation policy. Hiding an indicator never changes the underlying
/// terminal status, unread ledger, notification authorization, or running process.
struct DesktopPreferences: Equatable {
    enum Appearance: String, CaseIterable {
        case system, light, dark

        func usesDarkColors(systemIsDark: Bool) -> Bool {
            switch self {
            case .system: systemIsDark
            case .light: false
            case .dark: true
            }
        }
    }

    let appearance: Appearance
    let showsStatus: Bool
    let animatesStatus: Bool
    let countsWaiting: Bool
    let countsErrors: Bool
    let countsDone: Bool

    init(value: (String) -> String?) {
        appearance = value("app-appearance").flatMap(Appearance.init(rawValue:)) ?? .system
        func enabled(_ key: String) -> Bool {
            switch value(key)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "false": false
            case "true": true
            default: true
            }
        }
        showsStatus = enabled("status-show")
        animatesStatus = enabled("status-animate")
        countsWaiting = enabled("sidebar-count-waiting")
        countsErrors = enabled("sidebar-count-error")
        countsDone = enabled("sidebar-count-done")
    }

    func shouldAnimateStatus(reduceMotion: Bool, isVisible: Bool) -> Bool {
        showsStatus && animatesStatus && !reduceMotion && isVisible
    }
}

extension Tako.Config {
    var desktopPreferences: DesktopPreferences {
        DesktopPreferences(value: rawValue)
    }
}
