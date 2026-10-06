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
import Cocoa

enum QuickTerminalSpaceBehavior {
    case remain
    case move

    init?(fromTakoConfig string: String) {
        switch string {
        case "move":
            self = .move

        case "remain":
            self = .remain

        default:
            return nil
        }
    }

    var collectionBehavior: NSWindow.CollectionBehavior {
        let commonBehavior: [NSWindow.CollectionBehavior] = [
            .ignoresCycle,
            .fullScreenAuxiliary
        ]

        switch self {
        case .move:
            // We want this to move the window to the active space.
            return NSWindow.CollectionBehavior([.canJoinAllSpaces] + commonBehavior)
        case .remain:
            // We want this to remain the window in the current space.
            return NSWindow.CollectionBehavior([.moveToActiveSpace] + commonBehavior)
        }
    }
}
