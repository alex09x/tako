import AppKit
import Foundation
import TakoKit
import SwiftUI
import OSLog
#if canImport(TakoCoreUI)
#endif

// OSColor is declared by TakoCoreUI, which compiles into this module.

extension Tako {
    /// Compatibility shim for upstream's configuration object.
    ///
    /// Upstream's macOS application layer (`Sources/TakoApp`) reads window styling,
    /// split configurations, quick terminal options, fullscreen settings, and clipboard policies
    /// through `Tako.Config`.
    ///
    /// We back this object using `TakoCoreUI.TerminalTheme` where our Rust core already parses
    /// config files (e.g. background color/opacity, blur radius, font family/size, themes).
    /// For properties not yet modeled in our Rust core, we return upstream's documented default
    /// values so app behavior remains stable and sane.
    // `open`, not upstream's plain `class`/our old `final`: upstream's own
    // test helpers (TemporaryConfig, TerminalViewContainerTests' MockConfig)
    // subclass this and override individual properties. Upstream gets that
    // for free from being one Xcode project; TakoTests is a separate SPM
    // module here (see TerminalViewContainer.swift's doc comment for the
    // same story), so subclassing needs `open`, not just non-final.
    open class Config: ObservableObject, @unchecked Sendable {
        /// The underlying terminal theme parsed from user configuration or default theme files.
        ///
        /// WHY: Our Rust core exposes configuration parsing through `TerminalTheme` in `TakoCoreUI`.
        /// By holding a `TerminalTheme` instance here, we bridge user configuration files directly to the UI.
        public private(set) var theme: TerminalTheme

        /// Upstream checks whether the configuration is loaded successfully.
        var loaded: Bool { config != nil }

        /// Upstream's opaque C config handle. Ours is real here (unlike the
        /// old stub) -- it's the `TakoConfigStorage` box that backs
        /// `errors`, `keyboardShortcut(for:)` overrides, and every property
        /// listed in `knownTakoConfigKeys`, reached through the same
        /// `tako_config_get`/diagnostics C surface upstream's real Config
        /// uses (see TakoKit.swift). Test helpers (TemporaryConfig) call
        /// `tako_config_get` on this directly, exactly like upstream.
        private(set) var config: tako_config_t?

        /// Diagnostic messages produced during configuration parsing.
        var errors: [String] {
            TakoKit.configStorage(config)?.errors ?? []
        }

        /// Per-action keybind overrides parsed from `keybind = ...` lines,
        /// consulted by `keyboardShortcut(for:)` before the hardcoded
        /// defaults below.
        private var keybindOverrides: [String: KeybindOverride] = [:]

        /// Initializes a configuration object, optionally parsing a config file at `path`.
        ///
        /// WHY: Upstream's AppDelegate and window controllers instantiate `Tako.Config(at: path)`.
        /// Passing a path loads and parses that specific file, while passing `nil` loads user defaults.
        convenience init(at path: String? = nil, finalize: Bool = true) {
            self.init(config: Self.loadConfig(at: path, finalize: finalize))
        }

        /// Initializer accepting the opaque config handle produced by `loadConfig`.
        ///
        /// WHY: Upstream passes `tako_config_t` handles around during initial app setup and in tests
        /// (`TemporaryConfig`, which subclasses this and loads a real temp file through it).
        init(config: tako_config_t? = nil) {
            self.config = config
            if let path = TakoKit.configStorage(config)?.loadedPath,
               let text = try? String(contentsOfFile: path, encoding: .utf8) {
                self.theme = TerminalTheme.parse(config: text, configPath: path)
            } else {
                self.theme = TerminalTheme.loadUserConfig()
            }
            if let storage = TakoKit.configStorage(config) {
                self.keybindOverrides = Self.parseKeybindOverrides(storage.keybindLines)
            }
        }

        /// Convenience clone initializer.
        ///
        /// WHY: Upstream clones configs when spawning new windows or tabs to inherit existing settings.
        convenience init(clone config: tako_config_t?) {
            self.init(config: tako_config_clone(config))
        }

        /// Updates the configuration pointer/state.
        ///
        /// WHY: Upstream calls `clone(config:)` on existing `Tako.Config` instances to reload settings.
        func clone(config: tako_config_t?) {
            self.config = config
            if let path = TakoKit.configStorage(config)?.loadedPath,
               let text = try? String(contentsOfFile: path, encoding: .utf8) {
                self.theme = TerminalTheme.parse(config: text, configPath: path)
            } else {
                self.theme = TerminalTheme.loadUserConfig()
            }
            self.keybindOverrides = TakoKit.configStorage(config).map { Self.parseKeybindOverrides($0.keybindLines) } ?? [:]
        }

        /// Loads a config from `path` (or the user's default files when `nil`), mirroring
        /// upstream's `tako_config_new` -> `_load_file`/`_load_default_files` -> `_finalize`
        /// pipeline against our line-oriented shim parser (see TakoKit.swift).
        static func loadConfig(at path: String?, finalize: Bool) -> tako_config_t? {
            guard let cfg = tako_config_new() else {
                logger.critical("tako_config_new failed")
                return nil
            }
            if let path {
                TakoKit.configStorage(cfg)?.loadedPath = path
                tako_config_load_file(cfg, path)
            } else {
                tako_config_load_default_files(cfg)
            }
            if finalize {
                tako_config_finalize(cfg)
            }
            return cfg
        }

        #if os(macOS)
        /// The shortcut for a named action: the config's `keybind` lines, then the
        /// defaults below. Menu items, tab labels and the command palette show it, and
        /// the menu is what makes it fire -- there is no other keybinding layer, so a
        /// `keybind` for an action with no menu item does nothing.
        func keyboardShortcut(for action: String) -> SwiftUI.KeyboardShortcut? {
            switch keybindOverrides[action] {
            case .shortcut(let s): return s
            case .unbound: return nil
            case nil: return Self.defaultKeyboardShortcuts[action]
            }
        }

        /// Upstream's defaults for the bindings its UI asks about. The tab
        /// ones matter most: the tab bar labels each tab with them.
        /// Mirrors the macOS-specific defaults upstream's `Keybinds.init`
        /// bakes into its builds. This table is
        /// only the *fallback* for actions with no keybind in the loaded
        /// config -- upstream gets these for free from its own config
        /// layer; this port doesn't have that layer, so leaving an action
        /// out of this table silently strips its menu shortcut down to
        /// nothing (`syncMenuShortcut` clears `keyEquivalent` when lookup
        /// fails). That's exactly what happened to Copy: `copy_to_clipboard`
        /// was missing here, so Cmd+C had no menu item to land on at all,
        /// on top of the separate `copy(_:)` responder-chain bug.
        static let defaultKeyboardShortcuts: [String: SwiftUI.KeyboardShortcut] = [
            "goto_tab:1": .init("1", modifiers: .command),
            "goto_tab:2": .init("2", modifiers: .command),
            "goto_tab:3": .init("3", modifiers: .command),
            "goto_tab:4": .init("4", modifiers: .command),
            "goto_tab:5": .init("5", modifiers: .command),
            "goto_tab:6": .init("6", modifiers: .command),
            "goto_tab:7": .init("7", modifiers: .command),
            "goto_tab:8": .init("8", modifiers: .command),
            "goto_tab:9": .init("9", modifiers: .command),
            "new_tab": .init("t", modifiers: .command),
            "new_window": .init("n", modifiers: .command),
            "new_split:right": .init("d", modifiers: .command),
            "new_split:down": .init("d", modifiers: [.command, .shift]),
            "close_surface": .init("w", modifiers: .command),
            "toggle_quick_terminal": .init("`", modifiers: [.command, .shift]),
            "reload_config": .init(",", modifiers: [.command, .shift]),
            "open_config": .init(",", modifiers: .command),
            "goto_split:next": .init("]", modifiers: .command),
            "quit": .init("q", modifiers: .command),
            "close_tab": .init("w", modifiers: [.command, .option]),
            "close_window": .init("w", modifiers: [.command, .shift]),
            "close_all_windows": .init("w", modifiers: [.command, .shift, .option]),
            "undo": .init("z", modifiers: .command),
            "redo": .init("z", modifiers: [.command, .shift]),
            "copy_to_clipboard": .init("c", modifiers: .command),
            "paste_from_clipboard": .init("v", modifiers: .command),
            "paste_from_selection": .init("v", modifiers: [.command, .shift]),
            "select_all": .init("a", modifiers: .command),
            "increase_font_size:1": .init("=", modifiers: .command),
            "decrease_font_size:1": .init("-", modifiers: .command),
            "reset_font_size": .init("0", modifiers: .command),
            "start_search": .init("f", modifiers: .command),
            "search_selection": .init("e", modifiers: .command),
            "scroll_to_selection": .init("j", modifiers: .command),
            "navigate_search:next": .init("g", modifiers: .command),
            "navigate_search:previous": .init("g", modifiers: [.command, .shift]),
        ]

        private enum KeybindOverride {
            case shortcut(SwiftUI.KeyboardShortcut)
            case unbound
        }

        /// Parses `keybind = <trigger>=<action>` lines (e.g. `cmd+L=goto_split:left`,
        /// `super+d=unbind`) into per-action overrides, in file order. `super` is Tako
        /// config's own name for Command. A trigger does one thing, so binding it takes it
        /// away from whichever action held it before -- a default or an earlier line --
        /// and `unbind` only takes it away. `keybind = clear` drops every binding,
        /// defaults included. A line whose trigger cannot be a menu shortcut (an unknown
        /// key or modifier, a `>` sequence) is skipped rather than bound to a guess.
        private static func parseKeybindOverrides(_ lines: [String]) -> [String: KeybindOverride] {
            var result: [String: KeybindOverride] = [:]
            func current(_ action: String) -> SwiftUI.KeyboardShortcut? {
                switch result[action] {
                case .shortcut(let s): return s
                case .unbound: return nil
                case nil: return defaultKeyboardShortcuts[action]
                }
            }

            for rawLine in lines {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line == "clear" {
                    result = defaultKeyboardShortcuts.mapValues { _ in KeybindOverride.unbound }
                    continue
                }
                guard let eq = triggerSeparator(in: line) else { continue }
                let action = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                guard !action.isEmpty, let shortcut = parseTrigger(line[..<eq]) else { continue }

                let holders = Set(defaultKeyboardShortcuts.keys).union(result.keys)
                for holder in holders where current(holder) == shortcut {
                    result[holder] = .unbound
                }
                if action != "unbind" {
                    result[action] = .shortcut(shortcut)
                }
            }
            return result
        }

        /// The `=` between trigger and action. An `=` right after a `+` (or at the very
        /// start) is the key itself, as in `cmd+==increase_font_size:1`.
        private static func triggerSeparator(in line: String) -> String.Index? {
            var index = line.startIndex
            while let eq = line[index...].firstIndex(of: "=") {
                if eq != line.startIndex, line[line.index(before: eq)] != "+" {
                    return eq
                }
                index = line.index(after: eq)
            }
            return nil
        }

        /// Parses a single trigger like `cmd+L`, `super+shift+d` or
        /// `global:cmd+grave_accent` into a `KeyboardShortcut`. A letter is lowercased for
        /// the `KeyEquivalent` (upstream's trigger syntax is case-insensitive); no shift is
        /// implied by an uppercase letter here -- that inference belongs to
        /// `MenuShortcutKey`, which converts the result afterward.
        private static func parseTrigger(_ trigger: Substring) -> SwiftUI.KeyboardShortcut? {
            var trigger = trigger.trimmingCharacters(in: .whitespaces)[...]
            // Where the binding applies (everywhere, globally, ...) does not change which
            // key the menu item shows.
            while let prefix = triggerPrefixes.first(where: { trigger.hasPrefix($0) }) {
                trigger = trigger.dropFirst(prefix.count)
            }
            // A leader sequence (`ctrl+a>n`) has no single key a menu item can carry.
            guard !trigger.isEmpty, !trigger.contains(">") else { return nil }

            // `+` separates parts; the key `+` itself is spelled `plus`.
            let parts = trigger.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            guard let keyPart = parts.last, let key = keyEquivalent(named: keyPart) else { return nil }

            var modifiers: SwiftUI.EventModifiers = []
            for part in parts.dropLast() {
                switch part.trimmingCharacters(in: .whitespaces).lowercased() {
                case "cmd", "command", "super": modifiers.insert(.command)
                case "shift": modifiers.insert(.shift)
                case "ctrl", "control": modifiers.insert(.control)
                case "alt", "opt", "option": modifiers.insert(.option)
                default: return nil
                }
            }
            return SwiftUI.KeyboardShortcut(key, modifiers: modifiers)
        }

        private static let triggerPrefixes = ["all:", "global:", "unconsumed:", "performable:"]

        /// A single character is that key; anything longer must be one of upstream's key
        /// names (both its current W3C-style names and the older ones configs still use).
        private static func keyEquivalent(named name: String) -> SwiftUI.KeyEquivalent? {
            let name = name.trimmingCharacters(in: .whitespaces)
            if name.count == 1, let char = name.lowercased().first {
                return SwiftUI.KeyEquivalent(char)
            }
            let lower = name.lowercased()
            if let named = namedKeys[lower] {
                return named
            }
            if lower.hasPrefix("key_"), lower.count == 5, let char = lower.last, char.isLetter {
                return SwiftUI.KeyEquivalent(char)
            }
            if lower.hasPrefix("digit_"), lower.count == 7, let char = lower.last, char.isNumber {
                return SwiftUI.KeyEquivalent(char)
            }
            if lower.hasPrefix("f"), let n = Int(lower.dropFirst()), (1...35).contains(n),
               let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) {
                return SwiftUI.KeyEquivalent(Character(scalar))
            }
            return nil
        }

        private static let namedKeys: [String: SwiftUI.KeyEquivalent] = {
            var keys: [String: SwiftUI.KeyEquivalent] = [
                "grave_accent": "`", "backquote": "`",
                "minus": "-", "equal": "=",
                "bracket_left": "[", "left_bracket": "[",
                "bracket_right": "]", "right_bracket": "]",
                "backslash": "\\", "semicolon": ";",
                "quote": "'", "apostrophe": "'",
                "comma": ",", "period": ".", "slash": "/",
                "plus": "+",
                "space": .space, "enter": .return, "return": .return, "tab": .tab,
                "escape": .escape, "backspace": .delete, "delete": .deleteForward,
                "arrow_up": .upArrow, "up": .upArrow,
                "arrow_down": .downArrow, "down": .downArrow,
                "arrow_left": .leftArrow, "left": .leftArrow,
                "arrow_right": .rightArrow, "right": .rightArrow,
                "home": .home, "end": .end,
                "page_up": .pageUp, "page_down": .pageDown,
            ]
            for (digit, word) in ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"].enumerated() {
                keys[word] = SwiftUI.KeyEquivalent(Character(String(digit)))
            }
            return keys
        }()
        #endif

        /// Raw string for `key`, if the loaded config set it -- see
        /// `knownTakoConfigKeys` in TakoKit.swift for the keys this can return.
        private func rawValue(_ key: String) -> String? {
            TakoKit.configStorage(config)?.values[key]
        }

        private func rawBool(_ key: String, default def: Bool) -> Bool {
            switch rawValue(key) {
            case "true": return true
            case "false": return false
            default: return def
            }
        }

        /// Parsed `Double` for `key`, if set and numeric.
        private func rawDouble(_ key: String) -> Double? {
            rawValue(key).flatMap(Double.init)
        }

        // MARK: - Configuration Properties Backed by TerminalTheme or Upstream Defaults

        /// Features enabled for terminal bell alerts.
        ///
        /// WHY: Bell alerts are handled natively by macOS system beeps in our core; default to empty set.
        var bellFeatures: BellFeatures { .init() }

        /// Custom audio file path for bell sounds.
        ///
        /// WHY: Custom audio file loading for bell is not yet supported in Rust core; return nil for system default.
        var bellAudioPath: ConfigPath? { nil }

        /// Volume level for bell audio playback (0.0 to 1.0).
        ///
        /// WHY: Upstream default audio volume is 0.5.
        var bellAudioVolume: Float { 0.5 }

        /// Policy for OS notifications when long-running commands complete.
        ///
        /// WHY: Desktop notifications are managed by OS shell integrations; default to `.never`.
        var notifyOnCommandFinish: NotifyOnCommandFinish { .never }

        /// Action performed when command finish notification triggers.
        ///
        /// WHY: Default upstream action is `.bell`.
        var notifyOnCommandFinishAction: NotifyOnCommandFinishAction { .bell }

        /// Minimum command execution duration before triggering completion notification.
        ///
        /// WHY: Upstream default threshold is 5 seconds.
        var notifyOnCommandFinishAfter: Duration { .seconds(5) }

        /// Preserved zoom state when splitting panes.
        ///
        /// WHY: Pane zoom preservation is managed by our layout tree in Swift/Rust core; return empty options.
        var splitPreserveZoom: SplitPreserveZoom { .init() }

        /// Whether an initial terminal window should open on launch.
        ///
        /// WHY: Tako opens a main window upon launch unless configured headless; default to true.
        var initialWindow: Bool { rawBool("initial-window", default: true) }

        /// Whether the application should terminate after the last window closes.
        ///
        /// WHY: Standard macOS multi-window app behavior keeps app running when last window closes; default to false.
        var shouldQuitAfterLastWindowClosed: Bool { rawBool("quit-after-last-window-closed", default: false) }

        /// Custom title string override for the terminal window.
        ///
        /// WHY: Window titles are dynamically emitted by shell escape sequences in Rust core unless overridden.
        var title: String? { rawValue("title") }

        /// Whether windows come back after a restart.
        ///
        /// "always", not the system default: the system default depends on
        /// the "Close windows when quitting" checkbox in System Settings,
        /// and losing your window layout on every restart is not something
        /// a terminal should leave to a global preference.
        var windowSaveState: String { "always" }

        /// Initial X coordinate position for new windows.
        ///
        /// WHY: Window positioning is left to macOS window manager auto-placement.
        var windowPositionX: Int16? { rawValue("window-position-x").flatMap(Int16.init) }

        /// Initial Y coordinate position for new windows.
        ///
        /// WHY: Window positioning is left to macOS window manager auto-placement.
        var windowPositionY: Int16? { rawValue("window-position-y").flatMap(Int16.init) }

        /// Target tab position when creating new tabs ("current" or "end").
        ///
        /// Reads `window-new-tab-position`. `TerminalController.newTab`'s
        /// consuming switch treats anything but "end" as "current", so an
        /// unset or unrecognised value is passed through unchanged rather
        /// than normalized.
        var windowNewTabPosition: String {
            switch rawValue("window-new-tab-position") {
            case "end": return "end"
            case "current": return "current"
            default: return ""
            }
        }

        /// New window terminal size in columns x rows, from `window-width`
        /// and `window-height`. Both are required -- upstream ignores
        /// either alone -- and each is clamped to upstream's minimum (10
        /// columns, 4 rows). Sizes only a brand-new window's terminal area;
        /// never a tab or a split.
        var windowSizeInCells: (columns: Int, rows: Int)? {
            guard let width = rawValue("window-width").flatMap(Int.init),
                  let height = rawValue("window-height").flatMap(Int.init) else { return nil }
            return (max(width, 10), max(height, 4))
        }

        /// Where the app's very first terminal starts, from `working-directory`.
        enum WorkingDirectory: Equatable {
            /// A fixed path.
            case path(String)
            /// The user's home directory.
            case home
            /// Wherever the app process itself was launched with.
            case inherit
        }

        /// Reads `working-directory`. An unset value defaults to `.inherit`
        /// when the app was launched from a shell (which sets `TERM` before
        /// exec'ing it) and `.home` when launched from Finder or the Dock
        /// (which does not).
        var workingDirectory: WorkingDirectory {
            switch rawValue("working-directory") {
            case "home": return .home
            case "inherit": return .inherit
            case let path? where !path.isEmpty: return .path(path)
            default: return ProcessInfo.processInfo.environment["TERM"] != nil ? .inherit : .home
            }
        }

        /// Whether a new window, tab or split starts in the focused
        /// terminal's directory instead of `working-directory`.
        ///
        /// Reads `window-inherit-working-directory`, default true.
        var windowInheritWorkingDirectory: Bool {
            rawBool("window-inherit-working-directory", default: true)
        }

        /// Whether a new window, tab or split starts at the focused
        /// terminal's current (possibly zoomed) font size instead of the
        /// configured one.
        ///
        /// Reads `window-inherit-font-size`, default true.
        var windowInheritFontSize: Bool {
            rawBool("window-inherit-font-size", default: true)
        }

        /// Which bundled shell-integration script, if any, is injected into
        /// a new shell.
        enum ShellIntegration: String {
            /// Inject nothing.
            case none
            /// Detect from the login shell -- today's behavior.
            case detect
            case bash, elvish, fish, zsh
        }

        /// Reads `shell-integration`, default `.detect`.
        var shellIntegration: ShellIntegration {
            rawValue("shell-integration").flatMap(ShellIntegration.init(rawValue:)) ?? .detect
        }

        /// Raw comma list from `shell-integration-features`, applied over
        /// Tako's own defaults (`sudo`, `prompt`, `highlight`) by
        /// `PTY.shellFeatures`: a bare name enables it, `no-<name>` disables
        /// it. `nil` when unset, so the defaults are used unmodified.
        var shellIntegrationFeatures: String? {
            rawValue("shell-integration-features")
        }

        /// Whether standard window decorations (titlebar and borders) are visible.
        ///
        /// WHY: Tako windows show standard titlebar decorations by default; `window-decoration
        /// = none` (upstream's only value this shim distinguishes) turns them off.
        var windowDecorations: Bool { rawValue("window-decoration") != "none" }

        /// Custom window theme override (e.g. "light" or "dark").
        ///
        /// WHY: Terminal theme colors automatically dictate appearance mode; return nil for automatic.
        var windowTheme: String? { nil }

        /// Whether window resize snaps to character cell grid steps.
        ///
        /// WHY: Upstream default allows smooth continuous window resizing.
        var windowStepResize: Bool { rawBool("window-step-resize", default: false) }

        /// Current active fullscreen display mode, or nil if not fullscreen.
        ///
        /// WHY: Window controllers toggle fullscreen mode dynamically at runtime; initial default is nil.
        #if canImport(AppKit)
        var windowFullscreen: FullscreenMode? { nil }
        #else
        var windowFullscreen: Bool { false }
        #endif

        /// Preferred fullscreen style for toggle actions (native vs non-native borderless).
        ///
        /// WHY: Native macOS space fullscreen is upstream's default behavior.
        #if canImport(AppKit)
        var windowFullscreenMode: FullscreenMode { .native }
        #endif

        /// Custom font family specified for titlebar text.
        ///
        /// WHY: `window-title-font-family` is a distinct key from `font-family` (which backs
        /// `theme.fontFamily`), so it's read from the raw config directly rather than the theme.
        var windowTitleFontFamily: String? { rawValue("window-title-font-family") }

        /// Visibility of window control buttons (close, minimize, zoom).
        ///
        /// WHY: Upstream default keeps window buttons visible.
        var macosWindowButtons: Tako.MacOSWindowButtons {
            rawValue("macos-window-buttons").flatMap(Tako.MacOSWindowButtons.init(rawValue:)) ?? .visible
        }

        /// Titlebar style for macOS windows (transparent, tabs, native, hidden).
        ///
        /// WHY: the design puts the tabs in the titlebar, coloured by the
        /// terminal itself. Upstream already implements exactly that under
        /// the `tabs` style -- there is no reason to draw a tab bar by hand.
        /// This is a deliberate product default, not upstream's own
        /// (upstream defaults to `.transparent`) -- an explicit
        /// `macos-titlebar-style` config line still overrides it either way.
        var macosTitlebarStyle: MacOSTitlebarStyle {
            rawValue("macos-titlebar-style").flatMap(MacOSTitlebarStyle.init(rawValue:)) ?? .tabs
        }

        /// Visibility of the file/folder proxy icon in the window titlebar.
        ///
        /// Reads `macos-titlebar-proxy-icon`, default `.visible`.
        var macosTitlebarProxyIcon: Tako.MacOSTitlebarProxyIcon {
            rawValue("macos-titlebar-proxy-icon").flatMap(Tako.MacOSTitlebarProxyIcon.init(rawValue:)) ?? .visible
        }

        /// Drag-and-drop file behavior on dock icon (new tab vs new window).
        ///
        /// WHY: Opening dropped files in a new tab matches upstream default.
        var macosDockDropBehavior: MacDockDropBehavior { .new_tab }

        /// Whether windows drop a standard macOS shadow effect.
        ///
        /// WHY: Standard macOS windows render system shadows.
        var macosWindowShadow: Bool { rawBool("macos-window-shadow", default: true) }

        /// Selected app icon variant.
        ///
        /// WHY: Default to official Tako branding.
        var macosIcon: Tako.MacOSIcon {
            rawValue("macos-icon").flatMap(Tako.MacOSIcon.init(rawValue:)) ?? .official
        }

        /// Path to custom `.icns` file if `macosIcon == .custom`.
        ///
        /// WHY: Returns empty path when no custom icon is specified.
        var macosCustomIcon: String { "" }

        /// Frame material around custom app icons.
        ///
        /// WHY: Upstream default icon frame material is aluminum.
        var macosIconFrame: Tako.MacOSIconFrame {
            rawValue("macos-icon-frame").flatMap(Tako.MacOSIconFrame.init(rawValue:)) ?? .aluminum
        }

        /// Custom tint color for the "custom-style" app icon's mark.
        ///
        /// Parsed from `macos-icon-ghost-color`, upstream's color syntax.
        /// Upstream tints its own trademarked ghost graphic with this; here
        /// it colours Tako's own mark instead (see `CustomStyleIcon.swift`).
        /// `nil` when unset or unparsable, in which case `AppIcon` falls
        /// back to the brand default.
        var macosIconGhostColor: OSColor? {
            rawValue("macos-icon-ghost-color").flatMap(TerminalTheme.parseColor).flatMap(OSColor.init(cgColor:))
        }

        /// Custom background colors for the "custom-style" app icon's screen
        /// gradient, in `macos-icon-screen-color`'s comma-separated order.
        ///
        /// `nil` when unset or every entry is unparsable, in which case
        /// `AppIcon` falls back to the brand default gradient.
        var macosIconScreenColor: [OSColor]? {
            guard let raw = rawValue("macos-icon-screen-color") else { return nil }
            let colors = raw.split(separator: ",")
                .compactMap { TerminalTheme.parseColor($0.trimmingCharacters(in: .whitespaces)) }
                .compactMap { OSColor(cgColor: $0) }
            return colors.isEmpty ? nil : colors
        }

        /// Application visibility in dock and app switcher (always hidden, never hidden, etc.).
        ///
        /// Reads `macos-hidden`, default `.never`.
        var macosHidden: MacHidden {
            rawValue("macos-hidden").flatMap(MacHidden.init(rawValue:)) ?? .never
        }

        /// Which Option key, if any, acts as Alt (sends ESC + base key)
        /// instead of composing characters.
        ///
        /// Reads `macos-option-as-alt`, default `.off` (today's behaviour).
        var macosOptionAsAlt: OptionAsAlt {
            rawValue("macos-option-as-alt").flatMap(OptionAsAlt.init(rawValue:)) ?? .off
        }

        /// Reads `scrollback-limit`, upstream's byte budget for history. Tako
        /// keeps one line of history per 1,000 bytes of it, so upstream's
        /// default of 10 MB is Tako's default of 10,000 lines.
        var scrollbackLimitLines: UInt32 {
            guard let bytes = rawValue("scrollback-limit").flatMap(UInt64.init) else { return 10_000 }
            return UInt32(min(bytes / 1000, UInt64(UInt32.max)))
        }

        /// Reads `mouse-hide-while-typing`, default false.
        var mouseHideWhileTyping: Bool {
            rawBool("mouse-hide-while-typing", default: false)
        }

        /// Reads `mouse-shift-capture`, default `false`: Shift selects unless
        /// the program asks for it.
        var mouseShiftCapture: MouseShiftCapture {
            rawValue("mouse-shift-capture").flatMap(MouseShiftCapture.init(rawValue:)) ?? .off
        }

        /// Reads `cursor-click-to-move`, default true.
        var cursorClickToMove: Bool {
            rawBool("cursor-click-to-move", default: true)
        }

        /// Reads `link-url`, default true.
        var linkURL: Bool {
            rawBool("link-url", default: true)
        }

        /// Where a finished selection is copied.
        enum CopyOnSelect: String {
            /// Nowhere.
            case off = "false"
            /// The selection pasteboard, which `paste_from_selection` reads.
            case selection = "true"
            /// The selection pasteboard and the general clipboard.
            case clipboard
        }

        /// Reads `copy-on-select`, default true (the selection pasteboard).
        var copyOnSelect: CopyOnSelect {
            rawValue("copy-on-select").flatMap(CopyOnSelect.init(rawValue:)) ?? .selection
        }

        /// When closing a terminal, or quitting, asks first.
        enum ConfirmCloseSurface: String {
            /// Never.
            case never = "false"
            /// While a program other than the shell is running in it.
            case whenBusy = "true"
            /// Always, while the terminal is alive.
            case always
        }

        /// Reads `confirm-close-surface`, default true.
        var confirmCloseSurface: ConfirmCloseSurface {
            rawValue("confirm-close-surface").flatMap(ConfirmCloseSurface.init(rawValue:)) ?? .whenBusy
        }

        /// Focus follows mouse hover in multi-pane splits.
        ///
        /// WHY: Click-to-focus is standard macOS window behavior; default focusFollowsMouse to false.
        var focusFollowsMouse: Bool { rawBool("focus-follows-mouse", default: false) }

        /// Main background color for terminal surfaces.
        ///
        /// WHY: Backed directly by `theme.background` parsed from user's Tako config / active theme.
        var backgroundColor: Color {
            Color(NSColor(cgColor: theme.background) ?? .windowBackgroundColor)
        }

        /// Transparency ratio for window background (0.0 translucent to 1.0 opaque).
        ///
        /// WHY: Backed directly by `theme.backgroundOpacity` parsed from user config.
        var backgroundOpacity: Double {
            theme.backgroundOpacity
        }

        /// Background blur effect applied behind translucent windows.
        ///
        /// WHY: Backed directly by `theme.backgroundBlur` parsed from user config (radius in points or disabled).
        var backgroundBlur: BackgroundBlur {
            theme.backgroundBlur > 0 ? .radius(theme.backgroundBlur) : .disabled
        }

        /// Dimming opacity applied to non-focused split panes.
        ///
        /// Reads `unfocused-split-opacity`, clamped to 0.15...1, default 0.15.
        /// The value stored here is the dimming amount, `1 - opacity`.
        var unfocusedSplitOpacity: Double {
            guard let raw = rawDouble("unfocused-split-opacity") else { return 0.15 }
            return 1 - min(max(raw, 0.15), 1)
        }

        /// Fill color for unfocused split pane overlay.
        ///
        /// Reads `unfocused-split-fill`, default white.
        var unfocusedSplitFill: Color {
            guard let raw = rawValue("unfocused-split-fill"),
                  let color = TerminalTheme.parseColor(raw) else {
                return .white
            }
            return Color(NSColor(cgColor: color) ?? .windowBackgroundColor)
        }

        /// Color of divider lines between split terminal panes.
        ///
        /// It has to differ from the background or the panes run together --
        /// painting the gap in the background colour is the same as having
        /// no divider at all.
        var splitDividerColor: Color {
            Color(red: 0x2A / 255, green: 0x21 / 255, blue: 0x1B / 255)
        }

        /// Screen edge placement for Quick Terminal popup window (top, bottom, left, right).
        ///
        /// Reads `quick-terminal-position`, default `.top`.
        #if canImport(AppKit)
        var quickTerminalPosition: QuickTerminalPosition {
            rawValue("quick-terminal-position").flatMap(QuickTerminalPosition.init(rawValue:)) ?? .top
        }

        /// Target display monitor for Quick Terminal (main, mouse screen, focused screen).
        ///
        /// Reads `quick-terminal-screen`, default `.main`.
        var quickTerminalScreen: QuickTerminalScreen {
            rawValue("quick-terminal-screen").flatMap(QuickTerminalScreen.init(fromTakoConfig:)) ?? .main
        }

        /// Slide animation duration in seconds for Quick Terminal popup.
        ///
        /// Reads `quick-terminal-animation-duration`, default 0.2.
        var quickTerminalAnimationDuration: Double {
            rawDouble("quick-terminal-animation-duration") ?? 0.2
        }

        /// Automatically hide Quick Terminal when losing focus.
        ///
        /// Reads `quick-terminal-autohide`, default true.
        var quickTerminalAutoHide: Bool {
            rawBool("quick-terminal-autohide", default: true)
        }

        /// Behavior of Quick Terminal across macOS Spaces (move to active space vs switch space).
        ///
        /// Reads `quick-terminal-space-behavior`, default `.move`.
        var quickTerminalSpaceBehavior: QuickTerminalSpaceBehavior {
            rawValue("quick-terminal-space-behavior").flatMap(QuickTerminalSpaceBehavior.init(fromTakoConfig:)) ?? .move
        }

        /// Size configuration for Quick Terminal window.
        ///
        /// WHY: Default initializer uses standard half-screen popup dimensions.
        var quickTerminalSize: QuickTerminalSize { QuickTerminalSize() }
        #endif

        /// Trigger condition for pane resize overlay indicator.
        ///
        /// WHY: Upstream shows resize overlay after first resize event.
        var resizeOverlay: ResizeOverlay {
            rawValue("resize-overlay").flatMap(ResizeOverlay.init(rawValue:)) ?? .after_first
        }

        /// Screen alignment position for pane resize overlay.
        ///
        /// WHY: Center of terminal pane is upstream's default overlay position.
        var resizeOverlayPosition: ResizeOverlayPosition {
            rawValue("resize-overlay-position").flatMap(ResizeOverlayPosition.init(rawValue:)) ?? .center
        }

        /// Display duration in milliseconds for pane resize overlay.
        ///
        /// WHY: Upstream displays overlay for 1000ms (1 second).
        var resizeOverlayDuration: UInt { 1000 }

        /// Grace period duration for undoing closed tabs or windows.
        ///
        /// WHY: Upstream default undo timeout is 5 seconds.
        var undoTimeout: Duration { .seconds(5) }

        /// Release channel for automatic software updates (stable vs tip).
        ///
        /// WHY: Default to stable release updates.
        var autoUpdateChannel: AutoUpdateChannel { .stable }

        /// Automatic activation of macOS Secure Input during password prompts.
        ///
        /// Reads `macos-auto-secure-input`, default true.
        var autoSecureInput: Bool {
            rawBool("macos-auto-secure-input", default: true)
        }

        /// Visual indicator in titlebar/menu when Secure Input is active.
        ///
        /// Reads `macos-secure-input-indication`, default true.
        var secureInputIndication: Bool {
            rawBool("macos-secure-input-indication", default: true)
        }

        /// AppleScript / Automation support on macOS.
        ///
        /// WHY: macOS automation interfaces are enabled by default.
        var macosAppleScript: Bool { true }

        /// Whether double-clicking titlebar maximizes window height/width.
        ///
        /// WHY: Upstream's real default is `false` (confirmed by
        /// ConfigTests.maximizeDefaultsToFalse when this shim's config-key
        /// parsing was added) -- this used to hardcode `true`, which was
        /// simply wrong, not a deliberate divergence like macosTitlebarStyle's.
        var maximize: Bool { rawBool("maximize", default: false) }

        /// Minimum runtime duration required before command exit is considered abnormal.
        ///
        /// WHY: Upstream sets 250ms threshold to detect instant shell crash loops.
        var abnormalCommandExitRuntime: Duration { .milliseconds(250) }

        /// Scrollbar display policy (system default vs never).
        ///
        /// WHY: Respect macOS system scrollbar visibility settings by default.
        var scrollbar: Scrollbar {
            rawValue("scrollbar").flatMap(Scrollbar.init(rawValue:)) ?? .system
        }

        /// Custom entries displayed in command palette popup.
        ///
        /// WHY: Command palette dynamically populates from available actions; default to empty list.
        var commandPaletteEntries: [Tako.Command] { [] }

        /// Terminal command progress indicator style (dock icon / tab progress bar).
        ///
        /// WHY: Progress indicators are enabled by default.
        var progressStyle: Bool { true }
    }
}

// MARK: - Nested Configuration Types (Upstream Compatibility)

extension Tako.Config {
    /// Window titlebar style options for macOS windows.
    enum MacOSTitlebarStyle: String, Sendable, CaseIterable {
        static let `default` = MacOSTitlebarStyle.transparent
        case native, transparent, tabs, hidden
    }

    /// Background blur configuration mapping from C/Rust blur parameters.
    enum BackgroundBlur: Equatable, Sendable {
        case disabled
        case radius(Int)
        case macosGlassRegular
        case macosGlassClear

        init(fromCValue value: Int16) {
            switch value {
            case 0:
                self = .disabled
            case -1:
                if #available(macOS 26.0, *) {
                    self = .macosGlassRegular
                } else {
                    self = .disabled
                }
            case -2:
                if #available(macOS 26.0, *) {
                    self = .macosGlassClear
                } else {
                    self = .disabled
                }
            default:
                self = .radius(Int(value))
            }
        }

        var isEnabled: Bool {
            switch self {
            case .disabled:
                return false
            default:
                return true
            }
        }

        var isGlassStyle: Bool {
            switch self {
            case .macosGlassRegular, .macosGlassClear:
                return true
            default:
                return false
            }
        }

        var radius: Int? {
            switch self {
            case .disabled:
                return nil
            case .radius(let r):
                return r
            case .macosGlassRegular, .macosGlassClear:
                return nil
            }
        }
    }

    /// Options for preserving pane zoom levels during navigation.
    struct SplitPreserveZoom: OptionSet, Sendable {
        let rawValue: CUnsignedInt
        static let navigation = SplitPreserveZoom(rawValue: 1 << 0)

        init(rawValue: CUnsignedInt = 0) {
            self.rawValue = rawValue
        }
    }

    /// Terminal bell notification options.
    struct BellFeatures: OptionSet, Sendable {
        let rawValue: CUnsignedInt

        static let system = BellFeatures(rawValue: 1 << 0)
        static let audio = BellFeatures(rawValue: 1 << 1)
        static let attention = BellFeatures(rawValue: 1 << 2)
        static let title = BellFeatures(rawValue: 1 << 3)
        static let border = BellFeatures(rawValue: 1 << 4)

        init(rawValue: CUnsignedInt = 0) {
            self.rawValue = rawValue
        }
    }

    /// File drop action for macOS dock icon.
    enum MacDockDropBehavior: String, Sendable {
        case new_tab = "new-tab"
        case new_window = "new-window"
    }

    /// Dock visibility setting for macOS app.
    enum MacHidden: String, Sendable {
        case never
        case always
    }

    /// Scrollbar visibility policy.
    enum Scrollbar: String, Sendable {
        case system
        case never
    }

    /// Trigger rule for pane resize dimensions overlay.
    enum ResizeOverlay: String, Sendable {
        case always
        case never
        case after_first = "after-first"
    }

    /// Screen position alignment for resize overlay.
    enum ResizeOverlayPosition: String, Sendable {
        case center
        case top_left = "top-left"
        case top_center = "top-center"
        case top_right = "top-right"
        case bottom_left = "bottom-left"
        case bottom_center = "bottom-center"
        case bottom_right = "bottom-right"

        func top() -> Bool {
            switch self {
            case .top_left, .top_center, .top_right: return true
            default: return false
            }
        }

        func bottom() -> Bool {
            switch self {
            case .bottom_left, .bottom_center, .bottom_right: return true
            default: return false
            }
        }

        func left() -> Bool {
            switch self {
            case .top_left, .bottom_left: return true
            default: return false
            }
        }

        func right() -> Bool {
            switch self {
            case .top_right, .bottom_right: return true
            default: return false
            }
        }
    }

    /// Window decoration mode.
    enum WindowDecoration: String, Sendable {
        case none
        case client
        case server
        case auto

        func enabled() -> Bool {
            switch self {
            case .client, .server, .auto: return true
            case .none: return false
            }
        }
    }

    /// Notification trigger policy upon command completion.
    enum NotifyOnCommandFinish: String, Sendable {
        case never
        case unfocused
        case always
    }

    /// Action performed when command finish notification triggers.
    struct NotifyOnCommandFinishAction: OptionSet, Sendable {
        let rawValue: CUnsignedInt

        static let bell = NotifyOnCommandFinishAction(rawValue: 1 << 0)
        static let notify = NotifyOnCommandFinishAction(rawValue: 1 << 1)

        init(rawValue: CUnsignedInt = 1) {
            self.rawValue = rawValue
        }
    }
}

// MARK: - Supporting Types for Tako Namespace

extension Tako {
    /// Config path descriptor.
    struct ConfigPath: Sendable {
        let path: String
        let optional: Bool
    }

    /// Icon choices for the macOS app.
    ///
    /// Upstream's eight artwork variants and its "custom-style" colorized
    /// ghost (upstream's own trademarked mark) are not offered here.
    /// `custom-style` remains as a key, but draws Tako's own mark instead
    /// (see `CustomStyleIcon.swift`). An unrecognised value falls back to
    /// `official`.
    enum MacOSIcon: String, Sendable {
        case official
        case custom
        case customStyle = "custom-style"

        /// No variant ships an asset of its own any more; the app icon comes
        /// from the bundle, `.custom` from the user's own file, and
        /// `.customStyle` is drawn at runtime.
        var assetName: String? { nil }
    }

    /// Icon frame material for custom app icons.
    enum MacOSIconFrame: String, Codable, Sendable {
        case aluminum
        case beige
        case plastic
        case chrome
    }

    /// Window titlebar button visibility.
    enum MacOSWindowButtons: String, Sendable {
        case visible
        case hidden
    }

    /// Proxy icon visibility in window titlebar.
    enum MacOSTitlebarProxyIcon: String, Sendable {
        case visible
        case hidden
    }

    /// Update channel preference.
    enum AutoUpdateChannel: String, Sendable {
        case stable
        case tip
    }

    // FullscreenMode is declared by the app layer (Helpers/Fullscreen.swift).

    // QuickTerminalScreen, QuickTerminalSpaceBehavior and QuickTerminalSize
    // are declared by the app layer; a second copy here only made the
    // config's values incompatible with the properties they feed.

    /// Command palette entry descriptor.
    struct Command: Sendable, Equatable {
        let title: String
        let description: String
        let action: String
        let actionKey: String

        /// Only actions this port can carry out are offered; see
        /// `Tako.SurfaceView.performBindingAction`.
        var isSupported: Bool {
            !Self.unsupportedActionKeys.contains(actionKey)
                && Tako.SurfaceView.isBindingActionSupported(action)
        }

        static let unsupportedActionKeys: [String] = [
            "toggle_tab_overview",
            "toggle_window_decorations",
            "show_gtk_inspector",
        ]

        init(title: String = "", description: String = "", action: String = "", actionKey: String = "") {
            self.title = title
            self.description = description
            self.action = action
            self.actionKey = actionKey
        }
    }
}
