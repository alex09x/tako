import Foundation

// TakoKit: the C surface upstream's app layer imports directly, backed by
// our Rust core instead of the Zig library.
//
// Measured against the copied application layer, only 19 C symbols are
// actually referenced from 19 files -- everything else goes through the
// `Tako.*` Swift shim. These are those symbols, with upstream's exact
// names and shapes so `import TakoKit` compiles unmodified.

// MARK: - Opaque handles

/// Upstream treats these as opaque pointers; the app layer only stores and
/// passes them, so an opaque box is a faithful stand-in.
public struct tako_app_t: Hashable {
    public let raw: UnsafeMutableRawPointer?
    public init(raw: UnsafeMutableRawPointer? = nil) { self.raw = raw }
}

public struct tako_surface_t: Hashable {
    public let raw: UnsafeMutableRawPointer?
    public init(raw: UnsafeMutableRawPointer? = nil) { self.raw = raw }
}

/// Upstream's `tako_app` is the handle type name used in signatures.
public typealias tako_app = tako_app_t

// MARK: - Enums

public enum tako_color_scheme_e: UInt32 {
    case TAKO_COLOR_SCHEME_LIGHT = 0
    case TAKO_COLOR_SCHEME_DARK = 1
}

public struct tako_config_t: Hashable {
    public let raw: UnsafeMutableRawPointer?
    public init(raw: UnsafeMutableRawPointer? = nil) { self.raw = raw }
}

public enum tako_clipboard_e: UInt32 {
    case TAKO_CLIPBOARD_STANDARD = 0
    case TAKO_CLIPBOARD_SELECTION = 1
}

public enum tako_action_goto_tab_e: Int32 {
    case TAKO_GOTO_TAB_PREVIOUS = -1
    case TAKO_GOTO_TAB_NEXT = -2
    case TAKO_GOTO_TAB_LAST = -3
}

public enum tako_action_split_direction_e: UInt32 {
    case TAKO_SPLIT_DIRECTION_RIGHT = 0
    case TAKO_SPLIT_DIRECTION_DOWN = 1
    case TAKO_SPLIT_DIRECTION_LEFT = 2
    case TAKO_SPLIT_DIRECTION_UP = 3
}

public enum tako_build_mode_e: UInt32 {
    case TAKO_BUILD_MODE_DEBUG = 0
    case TAKO_BUILD_MODE_RELEASE_SAFE = 1
    case TAKO_BUILD_MODE_RELEASE_FAST = 2
    case TAKO_BUILD_MODE_RELEASE_SMALL = 3
}

public let TAKO_BUILD_MODE_DEBUG = tako_build_mode_e.TAKO_BUILD_MODE_DEBUG
public let TAKO_BUILD_MODE_RELEASE_SAFE = tako_build_mode_e.TAKO_BUILD_MODE_RELEASE_SAFE
public let TAKO_BUILD_MODE_RELEASE_FAST = tako_build_mode_e.TAKO_BUILD_MODE_RELEASE_FAST
public let TAKO_BUILD_MODE_RELEASE_SMALL = tako_build_mode_e.TAKO_BUILD_MODE_RELEASE_SMALL

public enum tako_input_action_e: UInt32 {
    case TAKO_ACTION_RELEASE = 0
    case TAKO_ACTION_PRESS = 1
    case TAKO_ACTION_REPEAT = 2
}

/// Upstream imports these as bare C constants, not as enum members.
/// Upstream's success code for `tako_init`.
public let TAKO_SUCCESS: Int32 = 0

public let TAKO_ACTION_RELEASE = tako_input_action_e.TAKO_ACTION_RELEASE
public let TAKO_ACTION_PRESS = tako_input_action_e.TAKO_ACTION_PRESS
public let TAKO_ACTION_REPEAT = tako_input_action_e.TAKO_ACTION_REPEAT
public let TAKO_GOTO_TAB_PREVIOUS = tako_action_goto_tab_e.TAKO_GOTO_TAB_PREVIOUS
public let TAKO_GOTO_TAB_NEXT = tako_action_goto_tab_e.TAKO_GOTO_TAB_NEXT
public let TAKO_GOTO_TAB_LAST = tako_action_goto_tab_e.TAKO_GOTO_TAB_LAST
public let TAKO_CLIPBOARD_STANDARD = tako_clipboard_e.TAKO_CLIPBOARD_STANDARD
public let TAKO_CLIPBOARD_SELECTION = tako_clipboard_e.TAKO_CLIPBOARD_SELECTION
public let TAKO_SPLIT_DIRECTION_RIGHT = tako_action_split_direction_e.TAKO_SPLIT_DIRECTION_RIGHT
public let TAKO_SPLIT_DIRECTION_DOWN = tako_action_split_direction_e.TAKO_SPLIT_DIRECTION_DOWN
public let TAKO_SPLIT_DIRECTION_LEFT = tako_action_split_direction_e.TAKO_SPLIT_DIRECTION_LEFT
public let TAKO_SPLIT_DIRECTION_UP = tako_action_split_direction_e.TAKO_SPLIT_DIRECTION_UP
public let TAKO_COLOR_SCHEME_LIGHT = tako_color_scheme_e.TAKO_COLOR_SCHEME_LIGHT
public let TAKO_COLOR_SCHEME_DARK = tako_color_scheme_e.TAKO_COLOR_SCHEME_DARK

// MARK: - Structs

public struct tako_action_start_search_s {
    public var needle: UnsafePointer<CChar>?
    public init(needle: UnsafePointer<CChar>? = nil) {
        self.needle = needle
    }
}

/// The C key event. Call sites mutate `text` in place with a borrowed C
/// string, so it stays a raw pointer rather than a Swift `String`.
public struct tako_input_key_s {
    public var action: tako_input_action_e
    public var keycode: UInt32
    public var mods: UInt32
    public var text: UnsafePointer<CChar>?
    public var composing: Bool

    public init(action: tako_input_action_e = .TAKO_ACTION_PRESS,
                keycode: UInt32 = 0,
                mods: UInt32 = 0,
                text: UnsafePointer<CChar>? = nil,
                composing: Bool = false) {
        self.action = action
        self.keycode = keycode
        self.mods = mods
        self.text = text
        self.composing = composing
    }
}

public struct tako_config_color_s {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public init(r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0) {
        self.r = r; self.g = g; self.b = b
    }
}

public enum tako_quick_terminal_size_tag_e: UInt32 {
    case TAKO_QUICK_TERMINAL_SIZE_NONE = 0
    case TAKO_QUICK_TERMINAL_SIZE_PERCENTAGE = 1
    case TAKO_QUICK_TERMINAL_SIZE_PIXELS = 2
}

public let TAKO_QUICK_TERMINAL_SIZE_NONE =
    tako_quick_terminal_size_tag_e.TAKO_QUICK_TERMINAL_SIZE_NONE
public let TAKO_QUICK_TERMINAL_SIZE_PERCENTAGE =
    tako_quick_terminal_size_tag_e.TAKO_QUICK_TERMINAL_SIZE_PERCENTAGE
public let TAKO_QUICK_TERMINAL_SIZE_PIXELS =
    tako_quick_terminal_size_tag_e.TAKO_QUICK_TERMINAL_SIZE_PIXELS

/// One axis of the quick terminal's size: a tagged union of a percentage of
/// the screen or an absolute pixel count.
public struct tako_quick_terminal_size_s {
    public struct Value {
        public var percentage: Float
        public var pixels: UInt32
        public init(percentage: Float = 0, pixels: UInt32 = 0) {
            self.percentage = percentage; self.pixels = pixels
        }
    }

    public var tag: tako_quick_terminal_size_tag_e
    public var value: Value

    public init(tag: tako_quick_terminal_size_tag_e = .TAKO_QUICK_TERMINAL_SIZE_NONE,
                value: Value = Value()) {
        self.tag = tag
        self.value = value
    }
}

public struct tako_config_quick_terminal_size_s {
    public var primary: tako_quick_terminal_size_s
    public var secondary: tako_quick_terminal_size_s
    public init(primary: tako_quick_terminal_size_s = .init(),
                secondary: tako_quick_terminal_size_s = .init()) {
        self.primary = primary
        self.secondary = secondary
    }
}

// MARK: - Functions

/// Library init. Our core needs no global setup, so this succeeds; the
/// return value is upstream's success code.
@discardableResult
public func tako_init(_ argc: UInt, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    0
}

/// CLI actions (`tako +list-themes` and friends) are a Zig-side feature;
/// there is nothing to dispatch to, so report "not an action" and let the
/// app continue booting normally.
public func tako_cli_try_action() {}

public func tako_app_set_color_scheme(_ app: tako_app_t?, _ scheme: tako_color_scheme_e) {}

public func tako_surface_set_color_scheme(_ surface: tako_surface_t?, _ scheme: tako_color_scheme_e) {}

/// Occlusion drives upstream's render throttling; ours redraws from damage,
/// so the hint is accepted and ignored.
public func tako_surface_set_occlusion(_ surface: tako_surface_t?, _ visible: Bool) {}

/// Whether a key event maps to a configured binding. Without a binding
/// engine we answer "no", which makes the app treat the key as ordinary
/// input rather than swallowing it. Configured bindings reach the app as
/// menu key equivalents instead (see `Tako.Config.keyboardShortcut(for:)`),
/// and named actions go to `Tako.SurfaceView.performBindingAction`.
public func tako_config_key_is_binding(_ config: tako_config_t?, _ key: tako_input_key_s) -> Bool { false }

/// No global (system-wide) keybinds exist, so the event tap stays off.
public func tako_app_has_global_keybinds(_ app: tako_app_t?) -> Bool { false }

/// "Not handled": the key continues to the menu and the focused surface.
public func tako_app_key(_ app: tako_app_t?, _ event: tako_input_key_s) -> Bool { false }

/// There is no C surface to act on, so this reports failure. The app does
/// not call it; binding actions go through `Tako.SurfaceView`.
public func tako_surface_binding_action(
    _ surface: tako_surface_t?,
    _ action: UnsafePointer<CChar>?,
    _ len: UInt
) -> Bool { false }

/// Window background blur is applied by our own window styling code (see
/// TerminalTheme.backgroundBlur), so this hook is a no-op rather than a
/// second, conflicting implementation.
public func tako_set_window_background_blur(_ app: tako_app_t?, _ window: UnsafeMutableRawPointer?) {}

// MARK: - Remaining app and surface entry points

public func tako_app_free(_ app: tako_app_t?) {}
public func tako_app_needs_confirm_quit(_ app: tako_app_t?) -> Bool { false }
public func tako_app_tick(_ app: tako_app_t?) {}
public func tako_app_update_config(_ app: tako_app_t?, _ config: tako_config_t?) {}

public func tako_surface_update_config(_ surface: tako_surface_t?, _ config: tako_config_t?) {}
public func tako_surface_request_close(_ surface: tako_surface_t?) {}
public func tako_surface_free(_ surface: tako_surface_t?) {}
public func tako_surface_text(_ surface: tako_surface_t?, _ text: UnsafePointer<CChar>?, _ len: UInt) {}
public func tako_surface_key(_ surface: tako_surface_t?, _ event: tako_input_key_s) {}
public func tako_surface_complete_clipboard_request(_ surface: tako_surface_t?,
                                                       _ str: UnsafePointer<CChar>?,
                                                       _ state: UnsafeMutableRawPointer?,
                                                       _ confirmed: Bool) {}
public func tako_surface_needs_confirm_quit(_ surface: tako_surface_t?) -> Bool { false }
public func tako_surface_process_exited(_ surface: tako_surface_t?) -> Bool { false }

// MARK: - Config

// Added for TakoTests (Tako/ConfigTests.swift, Helpers/TemporaryConfig.swift):
// upstream's real Config backs every property by asking Zig's config parser
// through this C surface. Our shim's Config (Tako+Config.swift) mostly
// hardcodes defaults instead, but the test helpers construct it exactly the
// way the real app would -- through `tako_config_new`/`_load_file`/
// `_finalize`/`_get`/diagnostics -- so those entry points need to exist and
// do something real, not just typecheck. This is a line-oriented `key =
// value` parser, not Zig's actual schema-validated one: it knows only the
// keys Tako+Config.swift's properties actually read (see
// `knownTakoConfigKeys` there), which is also why "unknown key" errors
// are approximate rather than matching Zig's exhaustive diagnostics.
public final class TakoConfigStorage {
    public var values: [String: String] = [:]
    public var keybindLines: [String] = []
    public var errors: [String] = []
    /// The file `tako_config_load_file` last read, if any -- Config.init
    /// re-reads it to also feed `TakoCoreUI.TerminalTheme.parse`, since
    /// that's a separate parser from this file's line-oriented one.
    public var loadedPath: String?
    private var cachedCStrings: [String: UnsafeMutablePointer<CChar>] = [:]

    public init() {}

    func cString(for key: String, value: String) -> UnsafePointer<CChar> {
        if let existing = cachedCStrings[key] { return UnsafePointer(existing) }
        let copy = strdup(value)!
        cachedCStrings[key] = copy
        return UnsafePointer(copy)
    }

    deinit {
        for ptr in cachedCStrings.values { free(ptr) }
    }
}

/// Exposed (not `private`) so Tako+Config.swift can read the same
/// storage this file's C-shaped functions operate on, for the properties
/// that need typed access rather than the raw-string `tako_config_get`.
public func configStorage(_ config: tako_config_t?) -> TakoConfigStorage? {
    guard let raw = config?.raw else { return nil }
    return Unmanaged<TakoConfigStorage>.fromOpaque(raw).takeUnretainedValue()
}

public func tako_config_new() -> tako_config_t? {
    tako_config_t(raw: Unmanaged.passRetained(TakoConfigStorage()).toOpaque())
}

public func tako_config_free(_ config: tako_config_t?) {
    guard let raw = config?.raw else { return }
    Unmanaged<TakoConfigStorage>.fromOpaque(raw).release()
}

public func tako_config_clone(_ config: tako_config_t?) -> tako_config_t? {
    guard let storage = configStorage(config) else { return nil }
    let clone = TakoConfigStorage()
    clone.values = storage.values
    clone.keybindLines = storage.keybindLines
    clone.errors = storage.errors
    return tako_config_t(raw: Unmanaged.passRetained(clone).toOpaque())
}

public func tako_config_load_file(_ config: tako_config_t?, _ path: UnsafePointer<CChar>?) {
    guard let storage = configStorage(config), let path else { return }
    guard let text = try? String(contentsOfFile: String(cString: path), encoding: .utf8) else { return }
    parseTakoConfigText(text, into: storage)
}

public func tako_config_load_default_files(_ config: tako_config_t?) {
    guard let storage = configStorage(config) else { return }
    let candidatePaths = [
        "~/.config/tako-core/config",
        "~/.config/tako/config",
    ].map { ($0 as NSString).expandingTildeInPath }

    for path in candidatePaths {
        if FileManager.default.fileExists(atPath: path),
           let text = try? String(contentsOfFile: path, encoding: .utf8) {
            storage.loadedPath = path
            parseTakoConfigText(text, into: storage)
        }
    }
}
public func tako_config_load_cli_args(_ config: tako_config_t?) {}
public func tako_config_load_recursive_files(_ config: tako_config_t?) {}

/// Populates defaults for keys the loaded config didn't set, mirroring
/// upstream's "finalize populates defaults" contract closely enough for
/// `Config.loaded`/`optionalAutoUpdateChannel` to behave the same either way.
public func tako_config_finalize(_ config: tako_config_t?) {
    guard let storage = configStorage(config) else { return }
    if storage.values["auto-update-channel"] == nil {
        storage.values["auto-update-channel"] = "tip"
    }
}

public func tako_config_diagnostics_count(_ config: tako_config_t?) -> UInt32 {
    UInt32(configStorage(config)?.errors.count ?? 0)
}

public struct tako_diagnostic_s {
    public var message: UnsafePointer<CChar>
    public init(message: UnsafePointer<CChar>) { self.message = message }
}

public func tako_config_get_diagnostic(_ config: tako_config_t?, _ i: UInt32) -> tako_diagnostic_s {
    guard let storage = configStorage(config), Int(i) < storage.errors.count else {
        return tako_diagnostic_s(message: UnsafePointer(strdup("")!))
    }
    let message = storage.errors[Int(i)]
    return tako_diagnostic_s(message: storage.cString(for: "diagnostic:\(i)", value: message))
}

public func tako_config_get(
    _ config: tako_config_t?,
    _ v: UnsafeMutablePointer<UnsafePointer<CChar>?>?,
    _ key: UnsafePointer<CChar>?,
    _ len: UInt
) -> Bool {
    guard let storage = configStorage(config), let key, let v else { return false }
    let keyStr = String(cString: key)
    guard let value = storage.values[keyStr] else { return false }
    v.pointee = storage.cString(for: keyStr, value: value)
    return true
}

/// Keys `Tako.Config`'s properties actually read. Anything else in a
/// loaded config is reported as a diagnostic error, approximating (not
/// replicating) Zig's real schema validation -- see the doc comment above
/// `TakoConfigStorage`.
let knownTakoConfigKeys: Set<String> = [
    "initial-window", "quit-after-last-window-closed", "window-step-resize",
    "focus-follows-mouse", "window-decoration", "macos-window-shadow",
    "maximize", "title", "window-title-font-family", "macos-titlebar-style",
    "macos-titlebar-proxy-icon", "macos-option-as-alt", "macos-auto-secure-input",
    "macos-secure-input-indication", "resize-overlay", "resize-overlay-position",
    "macos-icon", "macos-icon-frame", "macos-icon-ghost-color", "macos-icon-screen-color",
    "macos-window-buttons", "macos-hidden", "scrollbar", "background-opacity",
    "window-position-x", "window-position-y", "window-height", "window-width",
    "window-save-state", "window-new-tab-position", "auto-update-channel", "auto-update",
    // Also parsed by TakoCoreUI.TerminalTheme from the same config text
    // (see Tako+Config.swift's `init(config:)`), listed here too so they
    // don't get flagged as unknown.
    "background-blur-radius", "background-blur", "background", "font-family",
    "font-family-bold", "font-family-italic", "font-family-bold-italic", "font-size",
    "font-feature", "font-style", "font-style-bold", "font-style-italic", "font-synthetic-style",
    "adjust-cell-width", "adjust-cell-height", "adjust-font-baseline",
    "adjust-underline-position", "adjust-underline-thickness", "grapheme-width-method",
    "theme", "foreground", "selection-background", "selection-foreground", "selection-invert-fg-bg",
    "cursor-color", "cursor-style", "cursor-style-blink", "cursor-opacity", "cursor-thickness",
    "cursor-click-to-move", "cell-width", "cell_width", "cell-height", "cell_height",
    "window-padding-x", "window-padding-y", "window-padding-balance", "window-padding-color",
    "window-inherit-working-directory", "window-inherit-font-size", "window-colorspace",
    "command", "working-directory", "shell-integration", "shell-integration-features",
    "scrollback-limit", "mouse-hide-while-typing", "mouse-shift-capture", "copy-on-select",
    "confirm-close-surface", "quick-terminal-position", "quick-terminal-screen",
    "quick-terminal-animation-duration", "quick-terminal-autohide", "quick-terminal-space-behavior",
    "unfocused-split-opacity", "unfocused-split-fill", "custom-shader", "custom-shader-animation",
    "link-url", "palette",
]

/// Strips one layer of matching quotes from a configuration value.
///
/// Values are ordinarily written bare -- `font-size = 13`, `title = My
/// Terminal` -- and quoting is how you keep leading or trailing spaces, or
/// write a value that would otherwise read as empty. Upstream's Zig parser
/// accepts both, and its own UI tests write `title = "..."`, so a value that
/// arrives quoted has to come back out without them: keeping the quotes puts
/// them in the window title.
///
/// Only a matching pair is removed, and only when there is something between
/// them, so a lone quote or an apostrophe inside a value survives intact.
func unquoteConfigValue(_ value: String) -> String {
    guard value.count >= 2 else { return value }
    let first = value.first!
    guard first == "\"" || first == "'", value.last == first else { return value }
    return String(value.dropFirst().dropLast())
}

func parseTakoConfigText(_ text: String, into storage: TakoConfigStorage) {
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { continue }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        let value = unquoteConfigValue(
            line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
        guard !key.isEmpty else { continue }
        if key == "keybind" {
            storage.keybindLines.append(value)
            continue
        }
        guard knownTakoConfigKeys.contains(key) else {
            storage.errors.append("unknown configuration key: \(key)")
            continue
        }
        storage.values[key] = value
    }
}
