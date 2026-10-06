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

// MARK: - Config Storage and Parsing

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
    public var triggerLines: [String] = []
    public var snapshotRedactionPatternLines: [String] = []
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
    clone.triggerLines = storage.triggerLines
    clone.snapshotRedactionPatternLines = storage.snapshotRedactionPatternLines
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
    "notify-on-command-finish", "notify-on-command-finish-action", "notify-on-command-finish-after",
    "session-persistence", "remote-control", "window-save-state", "window-save-content", "window-save-content-limit", "window-new-tab-position", "auto-update-channel", "auto-update",
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
    "link-url", "palette", "safe-paste", "command-marks", "command-durations", "command-timestamps", "progress-style", "sticky-command-header", "editor", "trigger", "passive-regex-triggers", "clipboard-read",
    "snapshot-redact-pattern", "snapshot-redaction-pattern",
]

/// Strips one layer of matching quotes from a configuration value.
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
        if key == "trigger" {
            storage.triggerLines.append(value)
            continue
        }
        if key == "snapshot-redact-pattern" || key == "snapshot-redaction-pattern" {
            storage.snapshotRedactionPatternLines.append(value)
            continue
        }
        guard knownTakoConfigKeys.contains(key) else {
            storage.errors.append("unknown configuration key: \(key)")
            continue
        }
        storage.values[key] = value
    }
}
