// tako — Terminal emulator
// Copyright (c) 2026 Alexander Panasenko
//
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import Foundation

/// Configs are also parsed on worker threads. Only the AppKit observer reads
/// effectiveAppearance; parsing consumes its synchronized value.
enum TakoSystemAppearance {
    private static let lock = NSLock()
    private static var value = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"

    static var isDark: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    @discardableResult
    static func update(_ isDark: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = value != isDark
        value = isDark
        return changed
    }
}

extension Tako.App {
    /// The compatibility C hook has no theme engine behind it. Route system
    /// changes through the same live config notification as an explicit reload.
    func updateSystemTheme(darkAppearance: Bool) {
        guard TakoSystemAppearance.update(darkAppearance), let selection = config.rawValue("theme"),
              TerminalTheme.themeName(for: selection, darkAppearance: darkAppearance) != selection else { return }
        reloadConfig(soft: true)
    }
}
