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

        /// Active passive regex triggers parsed from `trigger = ...` configuration lines (E7).
        public private(set) var triggers: [TerminalRegexTrigger] = []

        /// Optional user-defined redaction patterns for persisted snapshots (G5).
        public private(set) var snapshotRedactionPatterns: [NSRegularExpression] = []

        /// Per-action keybind overrides parsed from `keybind = ...` lines,
        /// consulted by `keyboardShortcut(for:)` before the hardcoded
        /// defaults below.
        var keybindOverrides: [String: KeybindOverride] = [:]

        /// Transparency ratio for window background (0.0 translucent to 1.0 opaque).
        open var backgroundOpacity: Double {
            theme.backgroundOpacity
        }

        /// Background blur effect applied behind translucent windows.
        open var backgroundBlur: BackgroundBlur {
            theme.backgroundBlur > 0 ? .radius(theme.backgroundBlur) : .disabled
        }

        /// Window background color derived from theme.
        open var backgroundColor: Color {
            Color(NSColor(cgColor: theme.background) ?? .windowBackgroundColor)
        }

        /// Custom window theme override (e.g. "light" or "dark").
        open var windowTheme: String? { nil }

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
                self.triggers = storage.triggerLines.compactMap { TerminalRegexTrigger.parse(line: $0) }
                self.snapshotRedactionPatterns = storage.snapshotRedactionPatternLines.compactMap {
                    try? NSRegularExpression(pattern: $0, options: [])
                }
                SessionSnapshotRedactor.shared.setPatterns(storage.snapshotRedactionPatternLines)
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
            if let storage = TakoKit.configStorage(config) {
                self.keybindOverrides = Self.parseKeybindOverrides(storage.keybindLines)
                self.triggers = storage.triggerLines.compactMap { TerminalRegexTrigger.parse(line: $0) }
                self.snapshotRedactionPatterns = storage.snapshotRedactionPatternLines.compactMap {
                    try? NSRegularExpression(pattern: $0, options: [])
                }
                SessionSnapshotRedactor.shared.setPatterns(storage.snapshotRedactionPatternLines)
            } else {
                self.keybindOverrides = [:]
                self.triggers = []
                self.snapshotRedactionPatterns = []
            }
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
        /// Raw string for `key`, if the loaded config set it -- see
        /// `knownTakoConfigKeys` in TakoKit.swift for the keys this can return.
        func rawValue(_ key: String) -> String? {
            TakoKit.configStorage(config)?.values[key]
        }

        func rawBool(_ key: String, default def: Bool) -> Bool {
            switch rawValue(key) {
            case "true": return true
            case "false": return false
            default: return def
            }
        }

        /// Parsed `Double` for `key`, if set and numeric.
        func rawDouble(_ key: String) -> Double? {
            rawValue(key).flatMap(Double.init)
        }
    }
}

