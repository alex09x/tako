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

