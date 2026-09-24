import Foundation

/// Which named key a macOS key code is, when it is one.
///
/// A key the engine encodes as a key rather than as text has to arrive as
/// that key: `ctrl+space` is NUL, and a space that arrives as the character
/// " " can only ever be a space.
enum NamedKey {
    static let byKeyCode: [UInt16: FfiKey] = [
        36: .enter, 48: .tab, 49: .space, 51: .backspace, 53: .escape,
        126: .up, 125: .down, 124: .right, 123: .left,
        115: .home, 119: .end, 116: .pageUp, 121: .pageDown,
        114: .insert, 117: .delete,
        122: .f1, 120: .f2, 99: .f3, 118: .f4, 96: .f5, 97: .f6,
        98: .f7, 100: .f8, 101: .f9, 109: .f10, 103: .f11, 111: .f12,
        76: .keypadEnter, 69: .keypadPlus, 78: .keypadMinus,
        67: .keypadMultiply, 75: .keypadDivide,
    ]
}

/// What the space bar sends, given what the keyboard layout committed.
///
/// Option+Space commits a no-break space (U+00A0, or the narrow U+202F on
/// some layouts). It looks like a space and a shell treats it as part of a
/// word, so on layouts where `|`, `~` or `@` need Option, typing `ls | grep`
/// before letting go of Option runs ` grep`, which is not found. Nobody types
/// one into a terminal on purpose. Anything else an input method commits on
/// the space bar -- a conversion, a full-width space -- is what was asked for
/// and goes through unchanged.
enum SpaceBar {
    static func text(forCommitted committed: String) -> String {
        committed == "\u{00A0}" || committed == "\u{202F}" ? " " : committed
    }
}

/// The character a key types on a US layout, by macOS key code.
///
/// A Cyrillic layout's `c` key types U+0441, and its unmodified form is
/// U+0441 too, so nothing in the event says which key it physically is --
/// and `ctrl+c` has to be 0x03 on any layout. This is that missing piece.
/// Upstream calls it the logical key.
enum PhysicalKey {
    static let usLayout: [UInt16: Character] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
        8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
        16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l",
        38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "n", 46: "m", 47: ".", 50: "`",
    ]

    static func character(for keyCode: UInt16) -> String {
        usLayout[keyCode].map(String.init) ?? ""
    }
}
