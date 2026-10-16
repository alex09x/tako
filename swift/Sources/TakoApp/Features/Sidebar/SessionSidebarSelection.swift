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

/// Which row the sidebar's arrow-key cursor sits on when it follows the tab.
enum SessionSidebarSelection {
    static func activeIndex(in items: [SessionSidebarItem]) -> Int? {
        items.firstIndex(where: { $0.isSelected && !$0.isChild }) ?? items.firstIndex(where: { $0.isSelected })
    }
}
