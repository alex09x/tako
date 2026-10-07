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

    /// Path to user configuration file.
    public var configPath: String {
        ("~/.config/tako/config" as NSString).expandingTildeInPath
    }

    /// Map of action name to customized trigger string (e.g. ["toggle_split_zoom": "cmd+shift+return"]).
    @Published public private(set) var customOverrides: [String: String] = [:]

    public init() {
        reload()
    }

    /// Reloads current overrides from configuration file.
    public func reload() {
        guard FileManager.default.fileExists(atPath: configPath),
              let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            customOverrides = [:]
            return
        }

        var overrides: [String: String] = [:]
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("keybind") else { continue }
            guard let firstEq = line.firstIndex(of: "=") else { continue }
            let value = line[line.index(after: firstEq)...].trimmingCharacters(in: .whitespaces)

            // value is <trigger>=<action>
            guard let secondEq = value.firstIndex(of: "=") else { continue }
            let trigger = value[..<secondEq].trimmingCharacters(in: .whitespaces)
            let action = value[value.index(after: secondEq)...].trimmingCharacters(in: .whitespaces)

            if !trigger.isEmpty && !action.isEmpty {
                overrides[action] = trigger
            }
        }
        self.customOverrides = overrides
    }

    /// Saves or updates a keybinding in the config file.
    public func setKeybind(action: String, trigger: String) {
        ensureConfigFileExists()

        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }
        var lines = content.components(separatedBy: "\n")
        var replaced = false

        let newLine = "keybind = \(trigger)=\(action)"

        for i in 0..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("keybind") && line.contains("=\(action)") {
                lines[i] = newLine
                replaced = true
                break
            }
        }

        if !replaced {
            // Append right before trailing empty lines or at end
            if let lastNonEmpty = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                lines.insert(newLine, at: lastNonEmpty + 1)
            } else {
                lines.append(newLine)
            }
        }

        saveLinesAndReload(lines)
    }

    /// Removes a custom keybinding override for an action, reverting it to default.
    public func removeKeybind(action: String) {
        guard FileManager.default.fileExists(atPath: configPath),
              let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }

        var lines = content.components(separatedBy: "\n")
        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("keybind") && trimmed.contains("=\(action)")
        }

        saveLinesAndReload(lines)
    }

    /// Resets all custom keybinding overrides back to application defaults.
    public func resetAllKeybinds() {
        guard FileManager.default.fileExists(atPath: configPath),
              let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }

        var lines = content.components(separatedBy: "\n")
        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("keybind")
        }

        saveLinesAndReload(lines)
    }

    // MARK: - Private Helpers

    private func ensureConfigFileExists() {
        let dir = (configPath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        if !FileManager.default.fileExists(atPath: configPath) {
            let initial = "# Tako Terminal Configuration\n"
            try? initial.write(toFile: configPath, atomically: true, encoding: .utf8)
        }
    }

    private func saveLinesAndReload(_ lines: [String]) {
        let output = lines.joined(separator: "\n")
        try? output.write(toFile: configPath, atomically: true, encoding: .utf8)
        reload()

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.tako.reloadConfig()
        }
    }
}
