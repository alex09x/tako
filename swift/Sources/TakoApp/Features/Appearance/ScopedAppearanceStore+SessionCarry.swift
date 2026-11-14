/*
 * tako — Portable session appearance: what a moved or detached session carries
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

extension ScopedAppearanceStore {
    /// Color keys a scope record can state explicitly.
    static let carriedColorKeys: Set<String> = [AppearanceKey.background, .foreground, .cursorColor, .selectionBackground]
        .reduce(into: []) { $0.insert($1.rawValue) }

    /// The appearance fields a preset file states, as `key = value` pairs.
    /// Nil when no preset of that name is installed.
    static func presetFields(named name: String, searchPaths: [String]) -> [String: String]? {
        for directory in searchPaths {
            let path = (directory as NSString).appendingPathComponent(name)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            var fields: [String: String] = [:]
            for line in text.components(separatedBy: .newlines) {
                if let item = KeybindConfigFile.parseConfigKeyValue(line) { fields[item.key] = item.value }
            }
            return fields
        }
        return nil
    }

    /// Only values a scope record accepts may be carried.
    private static func valid(_ key: String, _ value: String) -> Bool {
        guard let typed = AppearanceKey(rawValue: key) else { return false }
        return (try? AppearanceValidator.validate(value: value, for: typed)) != nil
    }

    /// The session record that renders, in any destination workspace, what
    /// the session rendered under `inherited` (the source workspace record).
    ///
    /// A partial (legacy, colors-only) session preset merges onto whatever
    /// its parents resolved, so carrying only fonts lets the destination's
    /// background, palette and typography leak in. When the source has a
    /// full preset and every color the session preset states can be written
    /// explicitly, the session record adopts the source preset and states
    /// the legacy colors explicitly. Otherwise the session preset is kept and
    /// every source value the session preset does not restate is carried.
    func portableSessionFields(inherited: [String: String], local: [String: String]) -> [String: String] {
        let paths = themeSearchPaths ?? TerminalTheme.themeSearchPaths
        guard let preset = local["theme"] else { return inherited.merging(local) { _, own in own } }
        if TerminalTheme.presetContainsTypography(named: preset, searchPaths: paths) { return local }
        let legacy = Self.presetFields(named: preset, searchPaths: paths) ?? [:]
        // A legacy preset never changes fonts; it replaces the colors it states.
        let restated = Set(legacy.keys).filter { !$0.hasPrefix("font") }
        var carried = inherited.filter { $0.key != "theme" && !restated.contains($0.key) }
        guard let source = inherited["theme"],
              TerminalTheme.presetContainsTypography(named: source, searchPaths: paths) else {
            return carried.merging(local) { _, own in own }
        }
        let expressible = restated.allSatisfy { key in
            Self.carriedColorKeys.contains(key) && legacy[key].map { Self.valid(key, $0) } == true
        }
        if expressible {
            carried["theme"] = source
            for key in restated { carried[key] = legacy[key] }
            return carried.merging(local.filter { $0.key != "theme" }) { _, own in own }
        }
        // Keep the session's preset reference; carry the source preset's
        // expressible values under it. Palette entries cannot be stated by a
        // scope record, so only the colors and fonts below travel.
        let sourceFields = Self.presetFields(named: source, searchPaths: paths) ?? [:]
        for (key, value) in sourceFields where key != "theme" && carried[key] == nil && !restated.contains(key)
            && Self.valid(key, value) {
            carried[key] = value
        }
        return carried.merging(local) { _, own in own }
    }

    /// Detaching a pane into a new window gives it a new session identity.
    /// Carry the old session's fields into the pane's own record, under the
    /// pane's explicit fields, so the detached pane keeps its look. A pane
    /// with its own preset is left as its owner wrote it. One atomic write.
    @discardableResult
    func carrySessionStyle(from sessionID: String, toPane paneID: UUID) throws -> Bool {
        try verifyDiskIsCurrent()
        guard let session = document.overrides(for: .session(sessionID)), !session.isEmpty else { return false }
        let local = document.overrides(for: .pane(paneID)) ?? [:]
        guard local["theme"] == nil else { return false }
        let portable = session.merging(local) { _, own in own }
        guard portable != local else { return false }
        var draft = document
        for (key, value) in portable { draft.setOverride(value, for: key, scope: .pane(paneID)) }
        try commitDocument(draft)
        return true
    }

    /// The fields a pane inherits from a workspace and session pair, as a
    /// session record would state them.
    func parentFields(workspace workspaceID: UUID?, session sessionID: String?) -> [String: String] {
        let workspace = workspaceID.flatMap { document.overrides(for: .workspace($0)) } ?? [:]
        let session = sessionID.flatMap { document.overrides(for: .session($0)) } ?? [:]
        return portableSessionFields(inherited: workspace, local: session)
    }

    /// Moving a pane into another tab changes its parents: the destination
    /// session, and maybe another workspace. Every field the pane inherited
    /// from its old parents that its new parents would state differently --
    /// a shared workspace's value the destination session overrides
    /// included -- goes into the pane's own record, under its explicit
    /// fields, so it keeps its look. A pane with its own preset is left as
    /// its owner wrote it. Boundary: a field only the new parents state,
    /// which the pane took from the global config before, is not frozen.
    /// One atomic write; throws, writing nothing, when it cannot be stored.
    @discardableResult
    func carryMovedPaneStyle(from source: (workspace: UUID?, session: String?),
                             to destination: (workspace: UUID?, session: String?),
                             toPane paneID: UUID) throws -> Bool {
        let local = document.overrides(for: .pane(paneID)) ?? [:]
        guard local["theme"] == nil else { return false }
        let old = parentFields(workspace: source.workspace, session: source.session)
        let new = parentFields(workspace: destination.workspace, session: destination.session)
        let differing = old.filter { new[$0.key] != $0.value }
        let portable = differing.merging(local) { _, own in own }
        guard portable != local else { return false }
        try verifyDiskIsCurrent()
        var draft = document
        for (key, value) in portable { draft.setOverride(value, for: key, scope: .pane(paneID)) }
        try commitDocument(draft)
        return true
    }
}
