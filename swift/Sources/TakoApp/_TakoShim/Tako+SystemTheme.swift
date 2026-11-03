// tako — Terminal emulator
// Copyright (c) 2026 Alexander Panasenko
//
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import Foundation

extension Tako.App {
    /// The compatibility C hook has no theme engine behind it. Route system
    /// changes through the same live config notification as an explicit reload.
    func updateSystemTheme(darkAppearance: Bool) {
        guard let selection = config.rawValue("theme"),
              TerminalTheme.themeName(for: selection, darkAppearance: darkAppearance) != selection else { return }
        reloadConfig(soft: true)
    }
}
