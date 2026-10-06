import AppKit
import Foundation
import TakoKit
import SwiftUI

// The tail of the shim contract: the members upstream's app layer reaches
// for that the larger pieces (Input, Config, App, Notification) don't own.

extension Tako {
    /// Upstream's implementation, verbatim -- ours previously always
    /// backslash-escaped a hand-picked character set for `escape` (missing
    /// `~`/`\t` handling upstream has, and using the wrong escape set) and
    /// always single-quoted for `quote` (upstream leaves shell-safe strings
    /// unquoted and uses the standard POSIX `'"'"'` trick for embedded
    /// quotes, not a bare backslash -- which is a no-op inside single
    /// quotes). ShellTests.swift's `quote` cases caught both.
    enum Shell {
        // Characters to escape in the shell.
        private static let escapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

        /// Escape shell-sensitive characters in a string by prefixing each with a
        /// backslash. Suitable for inserting paths/URLs into a live terminal buffer.
        static func escape(_ str: String) -> String {
            var result = str
            for char in escapeCharacters {
                result = result.replacingOccurrences(
                    of: String(char),
                    with: "\\\(char)"
                )
            }

            return result
        }

        // Upstream expresses this as the bare regex literal `/[^\w@%+=:,.\/-]/`
        // (Swift Regex's `\w`), matched via `str.contains(regex)`. SwiftPM's
        // bare-slash-regex-literal parsing turned out not to trigger for
        // this target (the compiler read the leading `/` as division, not a
        // literal), so this is the same safe-character set expressed as a
        // `CharacterSet` instead -- same shlex.quote-style contract, no
        // regex-literal dependency.
        private static let quoteSafe: CharacterSet = {
            var set = CharacterSet.alphanumerics
            set.insert(charactersIn: "_@%+=:,./-")
            return set
        }()

        /// Returns a shell-quoted version of the string, like Python's shlex.quote.
        /// Suitable for building shell command lines that will be executed.
        static func quote(_ str: String) -> String {
            let needsQuoting = str.isEmpty || str.unicodeScalars.contains { !Self.quoteSafe.contains($0) }
            guard needsQuoting else { return str }
            return "'" + str.replacingOccurrences(of: "'", with: #"'"'"'"#) + "'"
        }
    }

    /// How the app was started. Upstream distinguishes these to decide
    /// whether to restore state or open a fresh window.
    enum LaunchSource: String {
        case app
        case cli
        /// Upstream's name for a launch from its Zig CLI entry point.
        case zig_run
    }

    static var launchSource: LaunchSource {
        // A CLI launch inherits a terminal on stdin; the app launcher does not.
        isatty(STDIN_FILENO) == 1 ? .cli : .app
    }

    /// Upstream's implementation, verbatim (moved out of the app-layer copy
    /// only because it needs `Tako.Config.keyboardShortcut(for:)`, which
    /// lives in this shim's Config -- not because the logic itself differs
    /// from upstream). It's pure AppKit/SwiftUI normalization with no C
    /// dependency, so it needed no adaptation, and the macOS-app build still
    /// gets the real behavior instead of the no-op stub this replaced.
    @MainActor
    class MenuShortcutManager {
        /// Tako menu items indexed by their normalized shortcut. This avoids traversing
        /// the entire menu tree on every key equivalent event.
        ///
        /// We store a weak reference so this cache can never be the owner of menu items.
        /// If multiple items map to the same shortcut, the most recent one wins.
        private var menuItemsByShortcut: [MenuShortcutKey: Weak<NSMenuItem>] = [:]

        /// Reset our shortcut index since we're about to rebuild all menu bindings.
        func reset() {
            menuItemsByShortcut.removeAll(keepingCapacity: true)
        }

        /// Syncs a single menu shortcut for the given action. The action string is the same
        /// action string used for the Tako configuration.
        func syncMenuShortcut(_ config: Tako.Config, action: String?, menuItem: NSMenuItem?) {
            guard let menu = menuItem else { return }

            if !updateMenuShortcut(config, action: action, menuItem: menu) {
                menu.keyEquivalent = ""
                menu.keyEquivalentModifierMask = []
            }
        }

        /// Attempts to perform a menu key equivalent only for menu items that represent
        /// Tako keybind actions. This is important because it lets our surface dispatch
        /// bindings through the menu so they flash but also lets our surface override macOS built-ins
        /// like Cmd+H.
        func performTakoBindingMenuKeyEquivalent(with event: NSEvent) -> Bool {
            // Convert this event into the same normalized lookup key we use when
            // syncing menu shortcuts from configuration.
            guard let key = MenuShortcutKey(event: event) else {
                return false
            }

            // If we don't have an entry for this key combo, no Tako-owned
            // menu shortcut exists for this event.
            guard let weakItem = menuItemsByShortcut[key] else {
                return false
            }

            // Weak references can be nil if a menu item was deallocated after sync.
            guard let item = weakItem.value else {
                menuItemsByShortcut.removeValue(forKey: key)
                return false
            }

            guard let parentMenu = item.menu else {
                return false
            }

            // Keep enablement state fresh in case menu validation hasn't run yet.
            parentMenu.update()
            guard item.isEnabled else {
                return false
            }

            let index = parentMenu.index(of: item)
            guard index >= 0 else {
                return false
            }

            parentMenu.performActionForItem(at: index)
            return true
        }
    }

    /// Upstream's secure-input toggle vocabulary.
    enum SetSecureInput: UInt32 {
        case on = 1
        case off = 0
        case toggle = 2
    }

    /// User-notification identifiers upstream registers for OSC 9 / 777
    /// desktop notifications.
    static let userNotificationCategory = "com.tako.notification"
    static let userNotificationActionShow = "com.tako.notification.show"
}

// MARK: - Undo

// Upstream's ExpiringUndoManager subclasses Foundation's UndoManager
// directly; there is nothing to shim.

// NamedKey and PhysicalKey moved into the package, as TakoCoreUI's
// TerminalKeyCodes.swift: the public AppKit view needs the same key-code
// tables, and a package cannot reach into the application that embeds it.
// This target flattens the package sources, so the single declaration
// there is the one both use -- keeping a copy here made them a
// redeclaration rather than a shared table.

extension NSEvent {
    /// Upstream converts an AppKit event into its own key event; ours maps
    /// onto the shim's Input types, which the core's encoder consumes.
    var takoKeyEvent: Tako.Input.KeyEvent {
        Tako.Input.KeyEvent(
            action: type == .keyUp ? .release : (isARepeat ? .repeatKey : .press),
            key: Tako.Input.Key(keyCode: keyCode),
            mods: Tako.Input.Mods(nsFlags: modifierFlags),
            text: type == .keyUp ? nil : characters
        )
    }

    func takoKeyEvent(_ action: tako_input_action_e,
                         translationMods: NSEvent.ModifierFlags? = nil) -> tako_input_key_s {
        tako_input_key_s(
            action: action,
            keycode: UInt32(keyCode),
            mods: UInt32((translationMods ?? modifierFlags).rawValue),
            text: nil,
            composing: false
        )
    }

    func takoKeyEvent(_ action: Tako.Input.Action) -> Tako.Input.KeyEvent {
        var event = takoKeyEvent
        event.action = action
        return event
    }
}

private extension Tako.MenuShortcutManager {
    /// Syncs a single menu shortcut for the given action. The action string is the same
    /// action string used for the Tako configuration.
    ///
    /// - Returns: Whether the menu item is updated and saved in ``menuItemsByShortcut``
    func updateMenuShortcut(_ config: Tako.Config, action: String?, menuItem menu: NSMenuItem) -> Bool {
        guard
            let action,
            let shortcut = config.keyboardShortcut(for: action),
            // Build a direct lookup for key-equivalent dispatch so we don't need to
            // linearly walk the full menu hierarchy at event time.
            let key = MenuShortcutKey(shortcut)
        else {
            return false
        }

        menu.keyEquivalent = key.keyEquivalent
        menu.keyEquivalentModifierMask = key.modifierFlags

        // Later registrations intentionally override earlier ones for the same key.
        menuItemsByShortcut[key] = .init(menu)
        return true
    }
}

extension Tako.MenuShortcutManager {
    /// Hashable key for a menu shortcut match, normalized for quick lookup.
    struct MenuShortcutKey: Hashable {
        private static let shortcutModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

        let keyEquivalent: String
        // Make it Hashable
        private let modifiersRawValue: UInt

        var modifierFlags: NSEvent.ModifierFlags {
            NSEvent.ModifierFlags(rawValue: modifiersRawValue)
        }

        init?(keyEquivalent: String, modifiers: NSEvent.ModifierFlags) {
            let normalized = keyEquivalent.lowercased()
            guard !normalized.isEmpty else { return nil }
            var mods = modifiers.intersection(Self.shortcutModifiers)
            if
                keyEquivalent.lowercased() != keyEquivalent.uppercased(),
                normalized.uppercased() == keyEquivalent {
                // If key equivalent is case sensitive and
                // it's originally uppercased, then we need to add `shift` to the modifiers
                mods.insert(.shift)
            }
            self.keyEquivalent = normalized
            self.modifiersRawValue = mods.rawValue
        }

        init?(event: NSEvent) {
            guard let keyEquivalent = event.charactersIgnoringModifiers else { return nil }
            self.init(keyEquivalent: keyEquivalent, modifiers: event.modifierFlags)
        }

        /// Create from a `NSMenuItem`
        ///
        /// - Important: This will check whether the `keyEquivalent` is uppercased by `.shift` modifier.
        init?(_ menuItem: NSMenuItem) {
            self.init(
                keyEquivalent: menuItem.keyEquivalent,
                modifiers: menuItem.keyEquivalentModifierMask,
            )
        }

        /// Create from a swiftUI `KeyboardShortcut`
        init?(_ shortcut: KeyboardShortcut) {
            // Configured shortcuts arrive lowercased from
            // `Tako.Config.keyboardShortcut(for:)`.
            let keyEquivalent = shortcut.key.character.description
            let modifierMask = NSEvent.ModifierFlags(swiftUIFlags: shortcut.modifiers)
            self.init(keyEquivalent: keyEquivalent, modifiers: modifierMask)
        }

        var swiftUIShortcut: KeyboardShortcut? {
            guard let character = keyEquivalent.first else { return nil }
            return KeyboardShortcut(
                KeyEquivalent(character),
                modifiers: .init(nsFlags: modifierFlags)
            )
        }
    }
}
