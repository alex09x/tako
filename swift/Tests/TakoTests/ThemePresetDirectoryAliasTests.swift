/*
 * tako — Legacy profile aliases do not make custom themes read-only
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing
@testable import Tako

@MainActor @Suite(.serialized) struct ThemePresetDirectoryAliasTests {
    @Test func legacyParentAliasSupportsTheCompleteCustomPresetLifecycle() throws {
        let scene = try ThemeControlTestScene()
        let alias = scene.root.appendingPathComponent("legacy-profile")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: scene.root)
        let service = ThemeControlService(configURL: scene.config, appearances: scene.styles,
            workspaces: scene.workspaces, themePaths: [alias.appendingPathComponent("themes").path, scene.builtins.path])
        func call(_ action: String, _ fields: [String: JSON]) throws {
            _ = try service.handle(fields.merging(["action": .string(action)]) { _, value in value })
        }
        try call("create", ["name": .string("Mine"), "from_theme": .string("TakoCore")])
        try call("set", ["name": .string("Mine"), "settings": .array([
            .object(["key": .string("font-weight"), "value": .string("550")])])])
        #expect(try service.presets.load(named: "Mine").isUser)
        #expect(try service.presets.load(named: "Mine").config.contains("font-weight = 550"))
        try call("rename", ["name": .string("Mine"), "new_name": .string("Renamed")])
        try call("create", ["name": .string("Copied"), "from_theme": .string("Renamed")])
        try call("delete", ["name": .string("Renamed")])
        #expect(try service.presets.load(named: "Copied").config.contains("font-weight = 550"))
        #expect(!FileManager.default.fileExists(atPath: service.presets.directory.appendingPathComponent("Renamed").path))
    }

    @Test func actualBuiltinsAndDirectUserDirectorySymlinksStayProtected() throws {
        let scene = try ThemeControlTestScene()
        let user = scene.service.presets.directory
        let store = ThemePresetStore(directory: user, searchPaths: [scene.builtins.path])
        #expect(throws: ThemePresetError.self) { try store.save(name: "TakoCore", config: "font-weight = 550") }
        let actual = scene.root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: user, withDestinationURL: actual)
        let linked = ThemePresetStore(directory: user, searchPaths: [])
        #expect(throws: ThemePresetError.self) { try linked.save(name: "No", config: "font-weight = 550") }
        #expect(!FileManager.default.fileExists(atPath: actual.appendingPathComponent("No").path))
    }
}
