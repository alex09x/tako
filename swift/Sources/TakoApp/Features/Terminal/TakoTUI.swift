import AppKit
import SwiftUI

/// The colours Tako's own terminal-style UI -- confirmations, the command
/// palette -- is drawn in: the TakoCore brand palette, not the terminal
/// theme's, so they look the same whatever theme a pane uses (see the
/// "TUI Dialogs" design: a frame from Rust to Ember, titles in Claw, the
/// selection in Ember on Ink).
enum TakoTUI {
    static let ink = NSColor(takoHex: 0x1A1512)
    static let deep = NSColor(takoHex: 0x14100E)
    static let field = NSColor(takoHex: 0x241C16)
    static let selection = NSColor(takoHex: 0x2A211B)
    static let ember = NSColor(takoHex: 0xF4581C)
    static let claw = NSColor(takoHex: 0xFF7A3D)
    static let rust = NSColor(takoHex: 0xC23E0E)
    static let text = NSColor(takoHex: 0xEDE6DF)
    static let bright = NSColor(takoHex: 0xFAF7F2)
    static let soft = NSColor(takoHex: 0xB7ACA1)
    static let muted = NSColor(takoHex: 0x8A7F76)
    static let dim = NSColor(takoHex: 0x6B6259)
    /// A destructive action: closing something with a process in it.
    static let danger = NSColor(takoHex: 0xD54E53)

    /// The terminal's font at its size, or a monospaced system font.
    static func font(_ theme: TerminalTheme?, bold: Bool = false) -> NSFont {
        let size = max(theme?.fontSize ?? 13, 11)
        let base = theme?.fontFamily.flatMap { NSFont(name: $0, size: size) }
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return bold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
    }
}

extension NSColor {
    convenience init(takoHex hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
