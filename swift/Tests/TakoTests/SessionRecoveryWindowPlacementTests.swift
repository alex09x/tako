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
import Testing
@testable import Tako

@Suite(.serialized) @MainActor
struct SessionRecoveryWindowPlacementTests {
    @Test func recordsFromBeforeWindowPlacementStillDecode() throws {
        let record = SessionRecord(id: UUID(), runtimeID: "r", generation: "g", state: .detached, createdAt: Date())
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object.removeValue(forKey: "windowTabIdentifiers")
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.windowTabIdentifiers == nil)
        #expect(decoded.id == record.id && decoded.generation == record.generation)
    }

    @Test func savedSiblingsIdentifyTheOriginalGroupWithoutMergingAnotherWindow() {
        let scene = WorkspaceSwitchVisualScene()
        defer { scene.tearDown() }
        let first = scene.addTab(scene.surface("first", .idle), to: scene.main)
        let separate = scene.addTab(scene.surface("separate", .idle), to: scene.main, ownWindow: true)
        let firstGroup = Tako.CustomTabGroup.group(for: first.window)
        let separateGroup = Tako.CustomTabGroup.group(for: separate.window)
        var record = SessionRecord(id: UUID(), runtimeID: "r", generation: "g", state: .detached, createdAt: Date())
        record.tabIdentifier = "missing"
        record.windowTabIdentifiers = ["missing", first.window.stableTabIdentifier]
        let decision = SessionRecoveryWindowPlacement.decide(record: record, workspaceID: scene.main.id,
            groups: [firstGroup, separateGroup], store: scene.workspaces)
        guard case .existing(let anchor) = decision else { Issue.record("expected the matching window"); return }
        #expect(Tako.CustomTabGroup.group(for: anchor) === firstGroup)
        #expect(firstGroup !== separateGroup)

        // Two persistent split panes can share one tab ID. A recovered
        // sibling still identifies the original physical window.
        record.tabIdentifier = first.window.stableTabIdentifier
        record.windowTabIdentifiers = [first.window.stableTabIdentifier]
        if case .existing(let splitAnchor) = SessionRecoveryWindowPlacement.decide(record: record, workspaceID: scene.main.id,
            groups: [firstGroup, separateGroup], store: scene.workspaces) { #expect(splitAnchor === first.window) }
        else { Issue.record("a recovered split sibling should identify the window") }

        // With no surviving sibling, the user chooses instead of an
        // implicit merge or a surprise additional window.
        record.tabIdentifier = "missing"
        record.windowTabIdentifiers = ["missing"]
        if case .choose(let windows) = SessionRecoveryWindowPlacement.decide(record: record, workspaceID: scene.main.id,
            groups: [firstGroup, separateGroup], store: scene.workspaces) { #expect(windows.count == 2) }
        else { Issue.record("uncertain placement must ask") }
        if case .newWindow = SessionRecoveryWindowPlacement.decide(record: record, workspaceID: scene.main.id,
            groups: [], store: scene.workspaces) {} else { Issue.record("empty desktop needs a window") }
    }

    @Test func oldRecordsAskRatherThanGuessTheWindow() {
        let scene = WorkspaceSwitchVisualScene()
        defer { scene.tearDown() }
        let first = scene.addTab(scene.surface("first", .idle), to: scene.main)
        let second = scene.addTab(scene.surface("second", .idle), to: scene.main, ownWindow: true)
        let firstGroup = Tako.CustomTabGroup.group(for: first.window)
        let secondGroup = Tako.CustomTabGroup.group(for: second.window)
        let record = SessionRecord(id: UUID(), runtimeID: "r", generation: "g", state: .detached, createdAt: Date())
        if case .choose(let anchors) = SessionRecoveryWindowPlacement.decide(record: record, workspaceID: scene.main.id,
            groups: [firstGroup], store: scene.workspaces) { #expect(anchors.count == 1 && anchors[0] === first.window) }
        else { Issue.record("legacy placement must not silently merge a window") }
        if case .choose(let anchors) = SessionRecoveryWindowPlacement.decide(record: record, workspaceID: scene.main.id,
            groups: [firstGroup, secondGroup], store: scene.workspaces) { #expect(anchors.count == 2) }
        else { Issue.record("multiple possible groups require a user choice") }
        if case .choose(let anchors) = SessionRecoveryWindowPlacement.decide(record: record, workspaceID: scene.legal.id,
            groups: [firstGroup], store: scene.workspaces) { #expect(anchors.count == 1) }
        else { Issue.record("a different workspace must not be guessed") }
    }
}
