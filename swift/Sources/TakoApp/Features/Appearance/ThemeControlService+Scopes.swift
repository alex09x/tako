/*
 * tako — Theme assignment and complete effective configuration
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation
import TakoCoreUI

extension ThemeControlService {
    func applyPreset(_ name: String, to scope: ThemeControlScope) throws -> [String: JSON] {
        let preset = try loadPreset(name)
        let full = TerminalTheme.presetContainsTypography(named: preset.name, searchPaths: presets.searchPaths)
        if let local = scope.appearance {
            if full { try appearances.applyPreset(preset.name, scope: local) }
            else { try appearances.setValue(preset.name, for: "theme", scope: local) }
        } else {
            let previous = try readConfiguration()
            let changed = full ? KeybindConfigFile.configurationSelectingPreset(preset.name, from: previous)
                : configurationRenamingTheme(in: previous, to: preset.name)
            try writeConfiguration(changed, expecting: previous)
        }
        reload()
        return scope.metadata.merging(["action": .string("apply"), "name": .string(preset.name), "theme": .string(preset.name)]) { _, new in new }
    }

    func reset(_ scope: ThemeControlScope) throws -> [String: JSON] {
        if let local = scope.appearance {
            try appearances.reset(local)
            reload()
            return scope.metadata.merging(["action": .string("reset"), "theme": .null]) { _, new in new }
        }
        var result = try applyPreset("TakoCore", to: scope)
        result["action"] = .string("reset")
        return result
    }

    func current(_ scope: ThemeControlScope) throws -> [String: JSON] {
        if scope.appearance != nil { try appearances.verifyDiskIsCurrent() }
        let global = try baseTheme()
        let effective: TerminalTheme
        let values: [String: String]
        let selected: String?
        var session: String?
        if let pane = scope.paneID { session = paneSession(pane) }
        if let local = scope.appearance {
            values = appearances.document.overrides(for: local) ?? [:]
            selected = values["theme"]
            effective = appearances.effectiveTheme(global: global, workspaceID: scope.workspaceID,
                sessionID: session, paneID: scope.paneID, themeSearchPaths: presets.searchPaths)
        } else {
            selected = configuredTheme(in: try readConfiguration())
            var fields: [String: String] = [:]
            for line in try readConfiguration().components(separatedBy: .newlines) {
                if let item = KeybindConfigFile.parseConfigKeyValue(line), item.key == "theme" || ThemePresetConfig.isAppearanceKey(item.key) {
                    fields[item.key] = item.value
                }
            }
            values = fields
            effective = global
        }
        return scope.metadata.merging([
            "theme": selected.map(JSON.string) ?? .null,
            "overrides": .object(values.mapValues(JSON.string)),
            "effective_config": .string(ThemePresetConfig.configuration(from: effective))
        ].merging(scope.paneID == nil ? [:] : ["session_id": session.map(JSON.string) ?? .null]) { old, _ in old }) { _, new in new }
    }

    /// The owning tab's stable identifier, found through every controller's
    /// split tree so a pane not mounted in a window still resolves. A pane
    /// no controller holds (a saved or synthetic target) has none.
    static func liveSessionIdentity(ofPane id: UUID) -> String? {
        for window in NSApplication.shared.windows {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            if controller.surfaceTree.contains(where: { $0.id == id }) { return window.stableTabIdentifier }
        }
        return nil
    }
}
