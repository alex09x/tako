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

/// Manages reading, writing, and persisting user keybindings in the Tako configuration file.
@MainActor
public final class KeybindConfigFile: ObservableObject {
    public static let shared = KeybindConfigFile()

    /// Explicit path provided at initialization or configuration.
    public let explicitConfigPath: String?

    /// Map of action name to customized trigger string (e.g. ["toggle_split_zoom": "cmd+shift+return"]).
    @Published public private(set) var customOverrides: [String: String] = [:]

    public init(configPath: String? = nil) {
        self.explicitConfigPath = configPath
        reload()
    }

    /// Path to active user configuration file, or nil if no active path could be resolved.
    public var configPath: String? {
        if let explicit = explicitConfigPath, !explicit.isEmpty {
            return (explicit as NSString).expandingTildeInPath
        }
        if let appDelegate = NSApp.delegate as? AppDelegate {
            return appDelegate.tako.activeConfigPath
        }
        if let env = ProcessInfo.processInfo.environment["TAKO_CONFIG_PATH"], !env.isEmpty {
            return (env as NSString).expandingTildeInPath
        }
        return nil
    }

    /// Finds the trigger/action separator `=` in a keybind value string (e.g. "cmd+opt+==equalize_splits"),
    /// correctly skipping any `=` that is part of the trigger key.
    public static func triggerSeparator(in line: String) -> String.Index? {
        Tako.Config.triggerSeparator(in: line)
    }

    /// Parses a line into trigger and action if it is a valid `keybind = <trigger>=<action>` line.
    public static func parseLineAction(_ line: String) -> (trigger: String, action: String)? {
        guard line.hasPrefix("keybind"), let firstEq = line.firstIndex(of: "=") else { return nil }
        let value = String(line[line.index(after: firstEq)...].trimmingCharacters(in: .whitespaces))
        guard let sep = triggerSeparator(in: value) else { return nil }
        let trigger = String(value[..<sep].trimmingCharacters(in: .whitespaces))
        let action = String(value[value.index(after: sep)...].trimmingCharacters(in: .whitespaces))
        guard !trigger.isEmpty, !action.isEmpty else { return nil }
        return (trigger, action)
    }

    /// Reloads current overrides from configuration file.
    public func reload() {
        guard let path = configPath,
              FileManager.default.fileExists(atPath: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            customOverrides = [:]
            return
        }

        var overrides: [String: String] = [:]
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let parsed = Self.parseLineAction(line) {
                overrides[parsed.action] = parsed.trigger
            }
        }
        self.customOverrides = overrides
    }

    /// Saves or updates a keybinding in the config file.
    @discardableResult
    public func setKeybind(action: String, trigger: String) -> Bool {
        guard let path = configPath else { return false }
        do {
            try ensureConfigFileExists(at: path)
            let content = try String(contentsOfFile: path, encoding: .utf8)
            var lines = content.components(separatedBy: "\n")
            var replaced = false
            let newLine = "keybind = \(trigger)=\(action)"

            for i in 0..<lines.count {
                let line = lines[i].trimmingCharacters(in: .whitespaces)
                if let parsed = Self.parseLineAction(line), parsed.action == action {
                    lines[i] = newLine
                    replaced = true
                    break
                }
            }

            if !replaced {
                if let lastNonEmpty = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    lines.insert(newLine, at: lastNonEmpty + 1)
                } else {
                    lines.append(newLine)
                }
            }

            try saveLinesAndReload(lines, to: path)
            return true
        } catch {
            return false
        }
    }

    /// Removes a custom keybinding override for an action, reverting it to default.
    @discardableResult
    public func removeKeybind(action: String) -> Bool {
        guard let path = configPath, FileManager.default.fileExists(atPath: path) else { return false }
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            var lines = content.components(separatedBy: "\n")
            lines.removeAll { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let parsed = Self.parseLineAction(trimmed) {
                    return parsed.action == action
                }
                return false
            }

            try saveLinesAndReload(lines, to: path)
            return true
        } catch {
            return false
        }
    }

    /// Resets all custom keybinding overrides back to application defaults.
    @discardableResult
    public func resetAllKeybinds() -> Bool {
        guard let path = configPath, FileManager.default.fileExists(atPath: path) else { return false }
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            var lines = content.components(separatedBy: "\n")
            lines.removeAll { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return Self.parseLineAction(trimmed) != nil
            }

            try saveLinesAndReload(lines, to: path)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Private Helpers

    private func ensureConfigFileExists(at path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        if !FileManager.default.fileExists(atPath: path) {
            let initial = "# Tako Terminal Configuration\n"
            try initial.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func saveLinesAndReload(_ lines: [String], to path: String) throws {
        let output = lines.joined(separator: "\n")
        try output.write(toFile: path, atomically: true, encoding: .utf8)
        reload()

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.tako.reloadConfig()
        }
    }
}
