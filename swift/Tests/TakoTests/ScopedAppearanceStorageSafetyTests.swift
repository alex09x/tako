/*
 * tako — Scoped appearance storage safety
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing
@testable import Tako

@MainActor @Suite struct ScopedAppearanceStorageSafetyTests {
    @Test func caseAliasedUUIDsAreRefusedWithoutCrashingOrOverwriting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("appearance.json")
        let id = UUID()
        let raw = "{\"version\":1,\"workspaces\":{\"\(id.uuidString)\":{\"font-size\":\"14\"},\"\(id.uuidString.lowercased())\":{\"font-size\":\"16\"}},\"panes\":{}}"
        try raw.write(to: file, atomically: true, encoding: .utf8)
        let store = ScopedAppearanceStore(fileURL: file)
        #expect(store.loadError != nil)
        #expect(throws: AppearanceStoreError.self) { try store.setValue("18", for: "font-size", scope: .workspace(id)) }
        #expect(try String(contentsOf: file, encoding: .utf8) == raw)
    }

    @Test func fontOverridesScaleConfiguredCellMetrics() {
        var global = TerminalTheme.takoDefault
        global.fontSize = 12
        global.cellWidth = 8
        global.cellHeight = 16
        let theme = ScopedAppearanceResolver.resolve(global: global,
            workspaceOverrides: ["font-size": "18"], paneOverrides: ["font-size": "24"])
        #expect(theme.fontSize == 24)
        #expect(theme.cellWidth == 16)
        #expect(theme.cellHeight == 32)
    }
}
