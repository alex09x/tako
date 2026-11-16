/*
 * tako — Settings keeps menu shortcuts away from the terminal under it
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

/// While Settings covers a terminal, a Command shortcut must not act on that
/// terminal: Cmd+D split it behind the open panel. The panel itself answers
/// first (performKeyEquivalent asks it before this), and a shortcut being
/// recorded never gets here: the recorder's local key monitor takes it
/// earlier. What is left:
///   - Cmd+W closes Settings only, as the in-terminal settings dialog did;
///   - text editing (Cmd+A/C/X/V/Z, Shift+Cmd+Z) and the app's own commands
///     (Cmd+Q, Cmd+H, Option+Cmd+H, Cmd+M, Cmd+,) go on to the menu;
///   - every other Command shortcut stops here;
///   - Control or Option without Command is not a menu shortcut and is left
///     to the focused field (text navigation).
extension DesktopSettingsOverlayView {
    /// True when the overlay takes `event`, so the menu never sees it.
    func containsKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command) else { return false }
        let key = Self.commandKey(event)
        if flags == .command && key == "w" {
            onClose?()
            return true
        }
        return !Self.reachesMenu(flags: flags, key: key)
    }

    /// The key as on a US layout, so editing keeps working with a Cyrillic
    /// input source (as TerminalDialogView does).
    static func commandKey(_ event: NSEvent) -> String? {
        let raw = event.charactersIgnoringModifiers?.lowercased()
        guard raw?.unicodeScalars.allSatisfy({ $0.isASCII }) == false else { return raw }
        return [UInt16(0): "a", 8: "c", 7: "x", 9: "v", 6: "z", 13: "w", 12: "q", 4: "h", 46: "m"][event.keyCode]
    }

    static func reachesMenu(flags: NSEvent.ModifierFlags, key: String?) -> Bool {
        switch (flags, key) {
        case (.command, "a"), (.command, "c"), (.command, "x"), (.command, "v"), (.command, "z"),
             ([.command, .shift], "z"), (.command, "q"), (.command, "h"), ([.command, .option], "h"),
             (.command, "m"), (.command, ","):
            return true
        default:
            return false
        }
    }
}
