/*
 * tako — Theme reference safety and recoverable lifecycle operations
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing
@testable import Tako

@MainActor @Suite(.serialized) struct ThemeControlLifecycleTests {
    @Test func renameUpdatesEveryScopeWithoutChangingSettingsOrAppearance() throws {
        let scene = try ThemeControlTestScene(); try scene.create()
        let workspace = scene.workspaces.createWorkspace(name: "Legal", color: "blue"), pane = UUID()
        try scene.call("apply", ["name": .string("Mine")], scope: .global)
        try scene.call("apply", ["name": .string("Mine")], scope: .workspace(workspace.id, workspace.name))
        try scene.call("apply", ["name": .string("Mine")], scope: .pane(pane, workspaceID: workspace.id))
        var text = try String(contentsOf: scene.config, encoding: .utf8)
        text += "font-size = 21\nforeground = #ffffff\n"
        try text.write(to: scene.config, atomically: true, encoding: .utf8)
        let beforeGlobal = try scene.service.current(.global)["effective_config"]
        let beforePane = try scene.service.current(.pane(pane, workspaceID: workspace.id))["effective_config"]
        let original = try scene.service.presets.load(named: "Mine").config
        try scene.call("rename", ["name": .string("Mine"), "new_name": .string("Renamed")])
        #expect(try scene.service.current(.global)["theme"]?.string == "Renamed")
        #expect(scene.styles.value(for: "theme", scope: .workspace(workspace.id)) == "Renamed")
        #expect(scene.styles.value(for: "theme", scope: .pane(pane)) == "Renamed")
        #expect(try scene.service.current(.global)["effective_config"] == beforeGlobal)
        #expect(try scene.service.current(.pane(pane, workspaceID: workspace.id))["effective_config"] == beforePane)
        #expect(try scene.service.presets.load(named: "Renamed").config == original)
        #expect(!FileManager.default.fileExists(atPath: scene.service.presets.directory.appendingPathComponent("Mine").path))
        #expect(try String(contentsOf: scene.config, encoding: .utf8).contains("font-size = 21"))
    }

    @Test func deletingAssignedPresetsIsRefusedAndUnusedRemovalIsRecoverable() throws {
        let scene = try ThemeControlTestScene(); try scene.create()
        let id = UUID()
        try scene.call("apply", ["name": .string("Mine")], scope: .pane(id, workspaceID: nil))
        let before = try scene.service.presets.load(named: "Mine").config
        do {
            _ = try scene.call("delete", ["name": .string("Mine")])
            Issue.record("assigned theme deletion succeeded")
        } catch let error as ControlError {
            #expect(error.code == .busy)
            #expect(error.candidates.contains("pane:\(id.uuidString.lowercased())"))
        }
        try scene.call("reset", scope: .pane(id, workspaceID: nil))
        let removed = try scene.call("delete", ["name": .string("Mine")])
        let path = try #require(removed["recovery_path"]?.string)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == before)
        #expect(throws: Error.self) { try scene.service.presets.load(named: "Mine") }
        try scene.call("create", ["name": .string("Recovered"), "config": .string(try String(contentsOfFile: path, encoding: .utf8))])
        #expect(try scene.service.presets.load(named: "Recovered").config == before)
    }

    @Test func renamingLegacyThemeKeepsItsFormatAndInheritedTypography() throws {
        let scene = try ThemeControlTestScene()
        let directory = scene.service.presets.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = "# legacy note\nbackground = 40,44,52\n"
        try legacy.write(to: directory.appendingPathComponent("Legacy"), atomically: true, encoding: .utf8)
        try "theme = Legacy\nfont-size = 23\n".write(to: scene.config, atomically: true, encoding: .utf8)
        let before = try scene.service.baseTheme()
        try scene.call("rename", ["name": .string("Legacy"), "new_name": .string("Legacy Renamed")])
        let after = try scene.service.baseTheme()
        #expect(after.background == before.background && after.fontSize == before.fontSize)
        #expect(try scene.service.presets.load(named: "Legacy Renamed").config == legacy)
    }

    @Test func renameRollsBackReferencesIfTheGlobalConfigCannotBeWritten() throws {
        let scene = try ThemeControlTestScene(); try scene.create()
        try scene.call("apply", ["name": .string("Mine")], scope: .global)
        let styles = ScopedAppearanceStore(fileURL: scene.root.appendingPathComponent("separate/Appearance.json"))
        let workspace = UUID()
        try styles.applyPreset("Mine", scope: .workspace(workspace))
        let service = ThemeControlService(configURL: scene.config, appearances: styles,
            workspaces: scene.workspaces, themePaths: [scene.builtins.path])
        let document = styles.document, config = try Data(contentsOf: scene.config)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: scene.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scene.root.path) }
        #expect(throws: Error.self) { try service.renamePreset(["name": .string("Mine"), "new_name": .string("Renamed")]) }
        #expect(styles.document == document)
        #expect(try Data(contentsOf: scene.config) == config)
        #expect(try service.presets.load(named: "Mine").config == service.presets.load(named: "Renamed").config)
    }

    @Test func unknownScopeDataAndNameCollisionsCannotLosePresetFiles() throws {
        let scene = try ThemeControlTestScene(); try scene.create()
        try scene.create("Existing")
        #expect(throws: Error.self) { try scene.call("rename", ["name": .string("Mine"), "new_name": .string("Existing")]) }
        #expect(throws: Error.self) { try scene.call("delete", ["name": .string("Readonly")]) }
        let corrupt = scene.root.appendingPathComponent("corrupt.json")
        try "not json".write(to: corrupt, atomically: true, encoding: .utf8)
        let service = ThemeControlService(configURL: scene.config, appearances: ScopedAppearanceStore(fileURL: corrupt),
                                          workspaces: scene.workspaces, themePaths: [scene.builtins.path])
        #expect(throws: Error.self) { try service.deletePreset(["name": .string("Mine")]) }
        #expect(throws: Error.self) { try service.renamePreset(["name": .string("Mine"), "new_name": .string("Other")]) }
        #expect(try scene.service.presets.load(named: "Mine").isUser)
        #expect(!FileManager.default.fileExists(atPath: scene.service.presets.directory.appendingPathComponent("Other").path))
    }

    @Test func externalAppearanceChangesCannotBeIgnoredWhenDeletingATheme() throws {
        let scene = try ThemeControlTestScene(); try scene.create()
        var external = AppearanceDocument()
        external.setOverride("Mine", for: "theme", scope: .pane(UUID()))
        let bytes = try JSONEncoder().encode(external)
        try bytes.write(to: scene.styles.fileURL, options: .atomic)
        #expect(throws: Error.self) { try scene.call("delete", ["name": .string("Mine")]) }
        #expect(try scene.service.presets.load(named: "Mine").isUser)
        #expect(try Data(contentsOf: scene.styles.fileURL) == bytes)
    }
}
