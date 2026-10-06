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

enum QuickTerminalScreen {
    case main
    case mouse
    case menuBar

    init?(fromTakoConfig string: String) {
        switch string {
        case "main":
            self = .main

        case "mouse":
            self = .mouse

        case "macos-menu-bar":
            self = .menuBar

        default:
            return nil
        }
    }

    var screen: NSScreen? {
        switch self {
        case .main:
            return NSScreen.main

        case .mouse:
            let mouseLoc = NSEvent.mouseLocation
            return NSScreen.screens.first(where: { $0.frame.contains(mouseLoc) })

        case .menuBar:
            return NSScreen.screens.first
        }
    }
}
