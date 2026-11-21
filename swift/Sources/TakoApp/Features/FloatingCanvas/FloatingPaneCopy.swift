/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// One wording for the actions on a terminal, shared by its header buttons,
/// its right-click menu, the sidebar and the main menu. The header's menu
/// drops the noun, as it already belongs to one terminal.
enum FloatingPaneCopy {
    static let minimize = "Minimize Terminal"
    static let close = "Close Terminal"

    static func maximize(_ mode: FloatingPaneMode) -> String {
        mode == .maximized ? "Restore Terminal" : "Maximize Terminal"
    }

    static func float(isTiled: Bool) -> String {
        isTiled ? "Float Terminal" : "Return to Grid"
    }

    /// The same action without its noun, for a menu opened on the terminal itself.
    static func short(_ title: String) -> String {
        title.hasSuffix(" Terminal") ? String(title.dropLast(" Terminal".count)) : title
    }
}
