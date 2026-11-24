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

    /// Session-aware move: the tab keeps its stable session identity, so its
    /// own session and pane records already travel. The source workspace's
    /// style is carried into the session record (one atomic write), under the
    /// session's own explicit fields, so later splits in the same session keep
    /// it too and pane records are left exactly as their owners wrote them.
    ///
    /// Boundary: a full session preset already replaced every source value.
    /// A partial legacy session preset keeps every source value it does not
    /// restate (see `portableSessionFields`). Destination fields the source
    /// never set still apply after the move.
    @discardableResult
    func preserveWorkspaceStyle(from workspaceID: UUID, session sessionID: String) throws -> Bool {
        try verifyDiskIsCurrent()
        guard let inherited = document.overrides(for: .workspace(workspaceID)), !inherited.isEmpty else { return false }
        let local = document.overrides(for: .session(sessionID)) ?? [:]
        let portable = portableSessionFields(inherited: inherited, local: local)
        guard portable != local else { return false }
        var draft = document
        for (key, value) in portable { draft.setOverride(value, for: key, scope: .session(sessionID)) }
        try commitDocument(draft)
        return true
    }

    /// Every scope that names `name` as its preset, including sessions, so
    /// delete refuses and rename rewrites all of them in one transaction.
    func references(toPreset name: String) -> [AppearanceScope] {
        func matches(_ fields: [String: String]) -> Bool { fields["theme"]?.caseInsensitiveCompare(name) == .orderedSame }
        let workspace = document.workspaces.compactMap { id, fields -> AppearanceScope? in
            guard matches(fields), let uuid = UUID(uuidString: id) else { return nil }
            return .workspace(uuid)
        }
        let sessions = document.sessions.compactMap { id, fields -> AppearanceScope? in
            matches(fields) ? .session(id) : nil
        }
        let panes = document.panes.compactMap { id, fields -> AppearanceScope? in
            guard matches(fields), let uuid = UUID(uuidString: id) else { return nil }
            return .pane(uuid)
        }
        return workspace + sessions + panes
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
