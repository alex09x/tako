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

extension Tako {
    /// The keys that stop an agent mid-turn: Escape, or a bare Ctrl-C. Claude
    /// Code and Antigravity fire no hook when the user stops them that way,
    /// so the key itself is what ends a status their hooks left at working.
    enum InterruptKeystroke {
        static let escapeKeyCode: UInt16 = 53
        /// Where C sits on the keyboard (kVK_ANSI_C), whatever the layout.
        static let cKeyCode: UInt16 = 8

        /// Escape under any modifiers; Ctrl-C with control alone, so Ctrl-Shift-C
        /// or Cmd-C (copy) never counts. `character` is the layout's letter for
        /// the key: "c" on Latin layouts, Dvorak included; on Cyrillic or Greek
        /// the C key gives no Latin letter, and its position decides -- but not
        /// on a Latin layout that puts another letter there (Dvorak's Ctrl-J).
        static func isInterrupt(keyCode: UInt16, character: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
            if keyCode == escapeKeyCode { return true }
            let mods = modifiers.intersection([.command, .control, .option, .shift])
            guard mods == [.control] else { return false }
            let base = character?.lowercased()
            if base == "c" { return true }
            return keyCode == cKeyCode && !isLatinLetter(base)
        }

        private static func isLatinLetter(_ base: String?) -> Bool {
            guard let base, base.count == 1, let scalar = base.unicodeScalars.first else { return false }
            return (0x61...0x7A).contains(scalar.value)
        }
    }
}
