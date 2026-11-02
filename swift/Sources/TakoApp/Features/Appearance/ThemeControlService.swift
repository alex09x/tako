/*
 * tako — Shared theme control service
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation

@MainActor final class ThemeControlService {
    static let maxConfigBytes = ControlProtocol.maxRequestBytes
    let configURL: URL
    let configFile: KeybindConfigFile
    let presets: ThemePresetStore
    let appearances: ScopedAppearanceStore
    let workspaces: WorkspaceStore
    let reload: () -> Void
    let globalTheme: (() -> TerminalTheme)?

    init(configURL: URL, appearances: ScopedAppearanceStore = .shared,
         workspaces: WorkspaceStore = .shared, themePaths: [String]? = nil,
         globalTheme: (() -> TerminalTheme)? = nil, reload: @escaping () -> Void = {}) {
        self.configURL = configURL
        let file = KeybindConfigFile(configPath: configURL.path)
        self.configFile = file
        self.appearances = appearances
        self.workspaces = workspaces
        self.reload = reload
        self.globalTheme = globalTheme
        let directory = configURL.deletingLastPathComponent().appendingPathComponent("themes", isDirectory: true)
        self.presets = ThemePresetStore(directory: directory, searchPaths: [directory.path] + (themePaths ?? file.appearanceThemePaths))
    }

    func handle(_ args: [String: JSON], scope: ThemeControlScope? = nil) throws -> [String: JSON] {
        let action = args["action"]?.string ?? "list"
        switch action {
        case "list": return try listPresets()
        case "fonts": return ["fonts": .array(TerminalAppearanceCatalog.fontFamilies().map(JSON.string))]
        case "keys": return ["keys": .array(ThemePresetConfig.controlKeys.map(JSON.string))]
        case "show": return presetJSON(try loadPreset(try name(args)))
        case "create": return try createPreset(args)
        case "set": return try updatePreset(args)
        case "rename": return try renamePreset(args)
        case "delete": return try deletePreset(args)
        case "apply", "reset", "current":
            guard let scope else { throw ControlError(.invalid, "choose --global, --workspace NAME, or --target SESSION") }
            if action == "apply" { return try applyPreset(try name(args), to: scope) }
            if action == "reset" { return try reset(scope) }
            return try current(scope)
        default: throw ControlError(.invalid, "unknown theme action: \(action)")
        }
    }

    func name(_ args: [String: JSON], key: String = "name") throws -> String {
        guard let name = args[key]?.string else { throw ControlError(.invalid, "theme \(key) is required") }
        try ThemePresetStore.validatePresetName(name)
        return name
    }

    func loadPreset(_ name: String) throws -> ThemePreset {
        try presets.load(named: name.lowercased() == "tako" ? "TakoCore" : name)
    }

    func readConfiguration() throws -> String {
        if !FileManager.default.fileExists(atPath: configURL.path) { return "" }
        return try String(contentsOf: configURL, encoding: .utf8)
    }

    func writeConfiguration(_ text: String, expecting previous: String? = nil) throws {
        if let previous, try readConfiguration() != previous { throw ControlError(.busy, "configuration changed during the operation") }
        let target = configURL.resolvingSymlinksInPath()
        let manager = FileManager.default
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let permissions = (try? manager.attributesOfItem(atPath: target.path)[.posixPermissions]) ?? NSNumber(value: 0o600)
        try text.write(to: target, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        configFile.reload()
    }

    func baseTheme() throws -> TerminalTheme {
        if let globalTheme { return globalTheme() }
        let text = try readConfiguration()
        let base = configuredTheme(in: text).map {
            TerminalTheme.takoDefault.applyingTheme(named: $0, searchPaths: presets.searchPaths)
        } ?? .takoDefault
        return TerminalTheme.parse(config: text, base: base, honourTheme: false, configPath: configURL.path)
    }

    func configuredTheme(in text: String) -> String? {
        text.components(separatedBy: .newlines).compactMap(KeybindConfigFile.parseConfigKeyValue)
            .last(where: { $0.key == "theme" }).map { ThemePresetConfig.unquoted($0.value) }
    }

    func presetJSON(_ preset: ThemePreset) -> [String: JSON] {
        ["name": .string(preset.name), "config": .string(preset.config), "is_user": .bool(preset.isUser)]
    }

    func checkedConfiguration(_ value: JSON?) throws -> String? {
        guard let value else { return nil }
        guard let text = value.string, text.utf8.count <= Self.maxConfigBytes else {
            throw ControlError(.invalid, "config must be UTF-8 text no larger than \(Self.maxConfigBytes) bytes")
        }
        return text
    }
}
