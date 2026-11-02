/*
 * tako — Preserve theme assignments through rename and removal
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

extension ThemeControlService {
    func references(to name: String) throws -> [String] {
        try appearances.verifyDiskIsCurrent()
        var result: [String] = []
        if configuredTheme(in: try readConfiguration())?.caseInsensitiveCompare(name) == .orderedSame { result.append("global") }
        result += appearances.references(toPreset: name).map { scope in
            switch scope {
            case .workspace(let id): return "workspace:\(id.uuidString.lowercased())"
            case .pane(let id): return "pane:\(id.uuidString.lowercased())"
            }
        }
        return result.sorted()
    }

    func deletePreset(_ args: [String: JSON]) throws -> [String: JSON] {
        let original = try loadPreset(try name(args))
        guard original.isUser else { throw ThemePresetError.readOnlyBuiltin(original.name) }
        let assigned = try references(to: original.name)
        guard assigned.isEmpty else {
            throw ControlError(.busy, "theme is assigned; apply another preset or reset these scopes before deleting", candidates: assigned)
        }
        let recovery = try presets.remove(original)
        reload()
        return ["action": .string("delete"), "name": .string(original.name), "recovery_path": .string(recovery.path)]
    }

    func renamePreset(_ args: [String: JSON]) throws -> [String: JSON] {
        let original = try loadPreset(try name(args))
        let newName = try name(args, key: "new_name")
        guard original.isUser else { throw ThemePresetError.readOnlyBuiltin(original.name) }
        if original.name == newName { return ["action": .string("rename"), "name": .string(newName), "previous_name": .string(original.name)] }
        try appearances.verifyDiskIsCurrent()
        let beforeConfig = try readConfiguration()
        let beforeDocument = appearances.document
        // Copy before changing any reference. If the app exits mid-operation,
        // both old and new references still identify the same valid theme.
        _ = try presets.copyForRename(original, to: newName)
        var changedConfig: String?
        var changedDocument: AppearanceDocument?
        var changedDocumentData: Data?
        do {
            try appearances.renamePresetReferences(from: original.name, to: newName)
            if appearances.document != beforeDocument {
                changedDocument = appearances.document
                changedDocumentData = try Data(contentsOf: appearances.fileURL)
            }
            if configuredTheme(in: beforeConfig)?.caseInsensitiveCompare(original.name) == .orderedSame {
                let after = configurationRenamingTheme(in: beforeConfig, to: newName)
                try writeConfiguration(after, expecting: beforeConfig)
                changedConfig = after
            }
            guard try references(to: original.name).isEmpty else {
                throw ControlError(.busy, "old theme gained another assignment during rename")
            }
            let recovery = try presets.remove(original)
            reload()
            return ["action": .string("rename"), "name": .string(newName), "previous_name": .string(original.name),
                    "recovery_path": .string(recovery.path)]
        } catch {
            // Never overwrite an intervening external edit during rollback.
            if let changedConfig, (try? readConfiguration()) == changedConfig {
                try? writeConfiguration(beforeConfig, expecting: changedConfig)
            }
            if let changedDocument, appearances.document == changedDocument,
               let changedDocumentData, (try? Data(contentsOf: appearances.fileURL)) == changedDocumentData {
                try? appearances.commitDocument(beforeDocument)
            }
            // Keep both files on failure, even if a rollback write was denied.
            // No restored or partially updated reference is left dangling.
            reload()
            throw ControlError(.internalError, "rename failed; both preset files were retained for recovery: \(error.localizedDescription)")
        }
    }

    func configurationRenamingTheme(in text: String, to name: String) -> String {
        var lines = text.components(separatedBy: "\n").filter { line in
            KeybindConfigFile.parseConfigKeyValue(line)?.key != "theme"
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        lines.append("theme = \(name)")
        return lines.joined(separator: "\n") + "\n"
    }
}
