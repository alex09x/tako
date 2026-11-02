/*
 * tako — Portable session appearance and preset reference transactions
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

extension ScopedAppearanceStore {
    /// A user move carries the source workspace's custom style with each
    /// previously inheriting pane. An explicit pane preset already travels
    /// with its stable ID and must not gain fields from another scope.
    @discardableResult
    func preserveWorkspaceStyle(from workspaceID: UUID, for paneIDs: [UUID]) throws -> Set<UUID> {
        try verifyDiskIsCurrent()
        guard let inherited = document.overrides(for: .workspace(workspaceID)), !inherited.isEmpty else { return [] }
        var draft = document
        var changed = Set<UUID>()
        for id in Set(paneIDs) {
            let local = document.overrides(for: .pane(id)) ?? [:]
            guard local["theme"] == nil else { continue }
            let portable = inherited.merging(local) { _, own in own }
            guard portable != local else { continue }
            for (key, value) in portable { draft.setOverride(value, for: key, scope: .pane(id)) }
            changed.insert(id)
        }
        if !changed.isEmpty { try commitDocument(draft) }
        return changed
    }

    func references(toPreset name: String) -> [AppearanceScope] {
        let workspace = document.workspaces.compactMap { id, fields -> AppearanceScope? in
            guard fields["theme"]?.caseInsensitiveCompare(name) == .orderedSame, let uuid = UUID(uuidString: id) else { return nil }
            return .workspace(uuid)
        }
        let panes = document.panes.compactMap { id, fields -> AppearanceScope? in
            guard fields["theme"]?.caseInsensitiveCompare(name) == .orderedSame, let uuid = UUID(uuidString: id) else { return nil }
            return .pane(uuid)
        }
        return workspace + panes
    }

    func renamePresetReferences(from old: String, to name: String) throws {
        if let loadError { throw loadError }
        try AppearanceValidator.validate(value: name, for: .theme)
        let scopes = references(toPreset: old)
        guard !scopes.isEmpty else { return }
        var draft = document
        for scope in scopes { draft.setOverride(name, for: "theme", scope: scope) }
        try commitDocument(draft)
    }
}
