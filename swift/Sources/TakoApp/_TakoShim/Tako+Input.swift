import AppKit
import Foundation
import TakoKit
import OSLog

/// The compatibility boundary between upstream's macOS application
/// layer (Sources/TakoApp, copied verbatim) and our pure-Rust terminal
/// core.
///
/// Upstream's app code talks to a Zig library through this exact namespace.
/// By providing the same shapes here, backed by `TakoCore`, upstream's
/// 21k lines of Features/App/Helpers run unmodified -- there is no reason to
/// rewrite Swift that already exists.
enum Tako {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "tako-core",
        category: "tako"
    )

    /// Build information the app shows to the user -- notably the debug
    /// build warning banner.
    static let info = Info(mode: TAKO_BUILD_MODE_RELEASE_FAST, version: "1.0.0")

    struct Info {
        let mode: tako_build_mode_e
        let version: String
    }

    // MARK: - Input

    /// Key and mouse vocabulary. Upstream's is generated from the Zig
    /// definitions; ours mirrors the same cases so their call sites compile,
    /// and converts into our core's encoder types.
    enum Input {
        struct Mods: OptionSet, Hashable {
            let rawValue: UInt32
            static let shift = Mods(rawValue: 1)
            static let ctrl = Mods(rawValue: 1 << 1)
            static let alt = Mods(rawValue: 1 << 2)
            static let `super` = Mods(rawValue: 1 << 3)
            static let capsLock = Mods(rawValue: 1 << 4)
            static let numLock = Mods(rawValue: 1 << 5)

            init(rawValue: UInt32) { self.rawValue = rawValue }

            init(nsFlags: NSEvent.ModifierFlags) {
                var result = Mods([])
                if nsFlags.contains(.shift) { result.insert(.shift) }
                if nsFlags.contains(.control) { result.insert(.ctrl) }
                if nsFlags.contains(.option) { result.insert(.alt) }
                if nsFlags.contains(.command) { result.insert(.super) }
                if nsFlags.contains(.capsLock) { result.insert(.capsLock) }
                self = result
            }

            var coreMods: FfiKeyEvent.Mods {
                (shift: contains(.shift), alt: contains(.alt),
                 ctrl: contains(.ctrl), superKey: contains(.super))
            }
        }

        enum Action: String, CaseIterable, Sendable, Equatable {
            case release
            case press
            case repeatKey

            var isPress: Bool { self != .release }
        }

        enum MouseButton: String, CaseIterable, Sendable, Equatable {
            case left, right, middle, unknown

            init(nsButtonNumber: Int) {
                switch nsButtonNumber {
                case 0: self = .left
                case 1: self = .right
                case 2: self = .middle
                default: self = .unknown
                }
            }
        }

        enum MouseState: String, CaseIterable, Sendable, Equatable { case press, release }

        enum Momentum: String, CaseIterable, Sendable, Equatable { case none, began, stationary, changed, ended, cancelled, mayBegin }

        struct MousePosEvent {
            var x: Double
            var y: Double
            var mods: Mods
        }

        struct MouseButtonEvent {
            var action: MouseState
            var button: MouseButton
            var mods: Mods
        }

        struct MouseScrollEvent {
            var x: Double
            var y: Double
            var mods: ScrollMods

            struct ScrollMods {
                var precision: Bool
                var momentum: Momentum
            }
        }

        /// A key event in upstream's vocabulary. `translate` turns it into
        /// the bytes our core's encoder produces.
        struct KeyEvent {
            var action: Action
            var key: Key
            var mods: Mods
            var consumedMods: Mods = Mods([])
            var text: String?
            var unshiftedCodepoint: UInt32 = 0
            var composing: Bool = false

            init(action: Action, key: Key, mods: Mods,
                 consumedMods: Mods = Mods([]), text: String? = nil,
                 unshiftedCodepoint: UInt32 = 0, composing: Bool = false) {
                self.action = action
                self.key = key
                self.mods = mods
                self.consumedMods = consumedMods
                self.text = text
                self.unshiftedCodepoint = unshiftedCodepoint
                self.composing = composing
            }

            /// Upstream's AppleScript path names the key first, since that is
            /// the argument a script actually supplies.
            init(key: Key, action: Action = .press, mods: Mods = Mods([]),
                 text: String? = nil) {
                self.init(action: action, key: key, mods: mods, text: text)
            }
        }

        /// The physical keys upstream names. Only the ones its app layer
        /// actually references need cases here; anything else arrives as
        /// `.unidentified` with the typed text carried alongside.
        enum Key: String, CaseIterable, Sendable, Equatable, Hashable {
            case unidentified
            case enter, tab, backspace, escape, space
            case up, down, left, right
            case home, end, pageUp, pageDown, insert, delete
            case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

            init(keyCode: UInt16) {
                switch keyCode {
                case 36: self = .enter
                case 48: self = .tab
                case 51: self = .backspace
                case 53: self = .escape
                case 49: self = .space
                case 126: self = .up
                case 125: self = .down
                case 123: self = .left
                case 124: self = .right
                case 115: self = .home
                case 119: self = .end
                case 116: self = .pageUp
                case 121: self = .pageDown
                case 114: self = .insert
                case 117: self = .delete
                case 122: self = .f1
                case 120: self = .f2
                case 99: self = .f3
                case 118: self = .f4
                case 96: self = .f5
                case 97: self = .f6
                case 98: self = .f7
                case 100: self = .f8
                case 101: self = .f9
                case 109: self = .f10
                case 103: self = .f11
                case 111: self = .f12
                default: self = .unidentified
                }
            }

            var ffiKey: FfiKey {
                switch self {
                case .enter: return .enter
                case .tab: return .tab
                case .backspace: return .backspace
                case .escape: return .escape
                case .space: return .space
                case .up: return .up
                case .down: return .down
                case .left: return .left
                case .right: return .right
                case .home: return .home
                case .end: return .end
                case .pageUp: return .pageUp
                case .pageDown: return .pageDown
                case .insert: return .insert
                case .delete: return .delete
                case .f1: return .f1
                case .f2: return .f2
                case .f3: return .f3
                case .f4: return .f4
                case .f5: return .f5
                case .f6: return .f6
                case .f7: return .f7
                case .f8: return .f8
                case .f9: return .f9
                case .f10: return .f10
                case .f11: return .f11
                case .f12: return .f12
                case .unidentified: return .character
                }
            }
        }
    }

    // MARK: - Split geometry

    enum SplitFocusDirection {
        case previous, next, up, down, left, right

        /// `previous`/`next` walk the tree in order; the rest navigate by
        /// where the split actually sits on screen.
        func toSplitTreeFocusDirection() -> SplitTree<Tako.SurfaceView>.FocusDirection {
            switch self {
            case .previous: return .previous
            case .next: return .next
            case .up: return .spatial(.up)
            case .down: return .spatial(.down)
            case .left: return .spatial(.left)
            case .right: return .spatial(.right)
            }
        }
    }

    enum SplitResizeDirection {
        case up, down, left, right
    }

    // MARK: - Clipboard

    /// Why the app is asking the user to confirm a clipboard operation.
    /// The case names are upstream's, taken from the OSC sequence numbers.
    enum ClipboardRequest {
        case paste
        case osc_52_read
        case osc_52_write(NSPasteboard?)

        /// The prompt shown above the contents in the confirmation dialog.
        func text() -> String {
            switch self {
            case .paste:
                return "Pasting this text to the terminal may be dangerous."
            case .osc_52_read:
                return "An application is attempting to read from the clipboard. " +
                       "The current clipboard contents are shown below."
            case .osc_52_write:
                return "An application is attempting to write to the clipboard. " +
                       "The text it wants to write is shown below."
            }
        }
    }
}

/// Convenience alias upstream uses for the modifier tuple our FFI takes.
extension FfiKeyEvent {
    typealias Mods = (shift: Bool, alt: Bool, ctrl: Bool, superKey: Bool)
}

extension Tako.Input.Key {
    /// The engine's key for each of ours, where one exists. Kept as a table
    /// rather than a switch: the switch was large enough that the type
    /// checker gave up on it.
    static let ffiKeys: [Tako.Input.Key: FfiKey] = [
        .enter: .enter, .tab: .tab, .backspace: .backspace, .escape: .escape,
        .up: .up, .down: .down, .left: .left, .right: .right,
        .home: .home, .end: .end, .pageUp: .pageUp, .pageDown: .pageDown,
        .insert: .insert, .delete: .delete,
        .f1: .f1, .f2: .f2, .f3: .f3, .f4: .f4, .f5: .f5, .f6: .f6,
        .f7: .f7, .f8: .f8, .f9: .f9, .f10: .f10, .f11: .f11, .f12: .f12,
    ]
}
