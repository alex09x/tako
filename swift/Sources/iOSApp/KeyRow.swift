import Foundation

/// What the key row above the keyboard sends, apart from the view that draws
/// it.
///
/// A phone keyboard has no escape, no tab, no arrows and no control, so this
/// row is the only way to reach half of what a terminal expects. The part
/// worth separating is the sticky ⌃: pressing it sends nothing and arms the
/// next character, which is then folded into a control byte. That fold is
/// easy to get wrong -- and invisible when it is, because the wrong byte
/// still looks like a keypress -- so it lives here, where it can be driven
/// without a finger and checked against what the far end says it received.
@MainActor
final class KeyRow: ObservableObject {
    /// The glyphs the row draws, in order.
    static let keys = ["esc", "\u{2303}", "\u{21E5}", "-", "|", "\u{2191}", "\u{2193}", "paste"]

    static let control = "\u{2303}"
    static let tab = "\u{21E5}"
    static let up = "\u{2191}"
    static let down = "\u{2193}"
    static let paste = "paste"

    /// A sayable name for a key drawn as a glyph, for accessibility and for
    /// the UI tests that press them.
    static func name(of key: String) -> String {
        switch key {
        case control: return "ctrl"
        case tab: return "tab"
        case up: return "up"
        case down: return "down"
        case "-": return "dash"
        case "|": return "pipe"
        default: return key
        }
    }

    /// True while ⌃ is armed. Published so the key lights up.
    @Published private(set) var controlArmed = false

    /// The bytes a press sends, or nil when it sends nothing: ⌃ only arms,
    /// and paste needs the pasteboard and the engine's own encoding, so the
    /// view keeps that one.
    func bytes(for key: String) -> [UInt8]? {
        switch key {
        case "esc": return folding([0x1B])
        case Self.tab: return folding([0x09])
        case Self.control:
            controlArmed.toggle()
            return nil
        case Self.up: return Array("\u{1b}[A".utf8)
        case Self.down: return Array("\u{1b}[B".utf8)
        case Self.paste: return nil
        default: return folding(Array(key.utf8))
        }
    }

    /// Applies the sticky control modifier to bytes emitted by the software
    /// keyboard. Those bytes enter through ``TakoTerminalView`` rather than
    /// `bytes(for:)`, but to a person the next key after tapping ⌃ is still
    /// the next key and must consume the modifier.
    func applyingControl(to data: Data) -> Data {
        Data(folding(Array(data)))
    }

    /// Applies an armed ⌃ the way a terminal does: ctrl+letter is the letter
    /// with the top three bits cleared, which is what turns `c` into 0x03.
    ///
    /// Only for a single byte in the range that has a control form; ⌃ before
    /// anything else disarms without changing what is sent, rather than
    /// silently mangling it.
    private func folding(_ bytes: [UInt8]) -> [UInt8] {
        guard controlArmed else { return bytes }
        controlArmed = false
        guard bytes.count == 1, let byte = bytes.first else { return bytes }
        let upper = byte & ~0x20
        guard (0x40...0x5F).contains(upper) else { return bytes }
        return [upper & 0x1F]
    }
}
