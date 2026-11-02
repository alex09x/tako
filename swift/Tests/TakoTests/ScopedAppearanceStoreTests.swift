/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing
import CoreGraphics
@testable import Tako

@Suite @MainActor struct ScopedAppearanceStoreTests {
    private func makeTemporaryDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tako-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func color(_ hex: String) -> CGColor {
        TerminalTheme.parseColor(hex)!
    }

    @Test func precedenceHierarchy() throws {
        let tempDir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wsThemeFile = tempDir.appendingPathComponent("ws-theme")
        try "background = #111111\nforeground = #212121\n".write(to: wsThemeFile, atomically: true, encoding: .utf8)

        let paneThemeFile = tempDir.appendingPathComponent("pane-theme")
        try "background = #131313\ncursor-color = #333333\n".write(to: paneThemeFile, atomically: true, encoding: .utf8)

        let storeFile = tempDir.appendingPathComponent("Appearance.json")
        let store = ScopedAppearanceStore(fileURL: storeFile, themeSearchPaths: [tempDir.path])

        let global = TerminalTheme(
            background: color("#101010"),
            foreground: color("#202020"),
            cursorColor: color("#303030"),
            fontFamily: "GlobalFont",
            fontSize: 12
        )

        let wsID = UUID()
        let paneID = UUID()

        // 1. Workspace preset
        try store.setValue("ws-theme", for: "theme", scope: .workspace(wsID))
        // 2. Workspace explicit fields
        try store.setValue("#222222", for: "foreground", scope: .workspace(wsID))
        try store.setValue("14", for: "font-size", scope: .workspace(wsID))

        // 3. Pane preset
        try store.setValue("pane-theme", for: "theme", scope: .pane(paneID))
        // 4. Pane explicit fields
        try store.setValue("#141414", for: "background", scope: .pane(paneID))
        try store.setValue("#343434", for: "cursor-color", scope: .pane(paneID))

        let effective = store.effectiveTheme(global: global, workspaceID: wsID, paneID: paneID)

        // Pane explicit overrides pane preset, workspace explicit, workspace preset, and global
        #expect(effective.background == color("#141414"))
        // Workspace explicit overrides workspace preset and global (pane didn't override foreground)
        #expect(effective.foreground == color("#222222"))
        // Pane explicit overrides pane preset and global
        #expect(effective.cursorColor == color("#343434"))
        // Workspace explicit font-size overrides global 12 and is preserved across pane preset
        #expect(effective.fontSize == 14)
        // Global font family preserved across workspace and pane presets
        #expect(effective.fontFamily == "GlobalFont")
    }

    @Test func partialInheritance() throws {
        let tempDir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ScopedAppearanceStore(fileURL: tempDir.appendingPathComponent("Appearance.json"))
        let global = TerminalTheme(
            background: color("#010101"),
            foreground: color("#020202"),
            cursorColor: color("#030303"),
            fontFamily: "DefaultMono",
            fontSize: 13
        )

        let wsID = UUID()
        let paneID = UUID()

        try store.setValue("#112233", for: "background", scope: .workspace(wsID))
        try store.setValue("16", for: "font-size", scope: .workspace(wsID))
        try store.setValue("#445566", for: "foreground", scope: .pane(paneID))

        let paneTheme = store.effectiveTheme(global: global, workspaceID: wsID, paneID: paneID)
        #expect(paneTheme.background == color("#112233"))
        #expect(paneTheme.fontSize == 16)
        #expect(paneTheme.foreground == color("#445566"))
        #expect(paneTheme.cursorColor == color("#030303"))
        #expect(paneTheme.fontFamily == "DefaultMono")

        let wsTheme = store.effectiveTheme(global: global, workspaceID: wsID, paneID: nil)
        #expect(wsTheme.background == color("#112233"))
        #expect(wsTheme.fontSize == 16)
        #expect(wsTheme.foreground == color("#020202"))
    }

    @Test func resetScope() throws {
        let tempDir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ScopedAppearanceStore(fileURL: tempDir.appendingPathComponent("Appearance.json"))
        let wsID = UUID()
        let paneID = UUID()

        try store.setValue("#111111", for: "background", scope: .workspace(wsID))
        try store.setValue("15", for: "font-size", scope: .workspace(wsID))
        try store.setValue("#222222", for: "background", scope: .pane(paneID))

        #expect(store.value(for: "background", scope: .workspace(wsID)) == "#111111")
        #expect(store.value(for: "font-size", scope: .workspace(wsID)) == "15")

        try store.reset(.workspace(wsID))
        #expect(store.value(for: "background", scope: .workspace(wsID)) == nil)
        #expect(store.value(for: "font-size", scope: .workspace(wsID)) == nil)
        #expect(store.value(for: "background", scope: .pane(paneID)) == "#222222")

        try store.reset(.pane(paneID))
        #expect(store.value(for: "background", scope: .pane(paneID)) == nil)
    }

    @Test func workAreaMoveModeledAsDifferentWorkspaceSamePane() throws {
        let tempDir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ScopedAppearanceStore(fileURL: tempDir.appendingPathComponent("Appearance.json"))
        let global = TerminalTheme(background: color("#000000"), fontSize: 13)

        let ws1 = UUID()
        let ws2 = UUID()
        let pane = UUID()

        try store.setValue("#111111", for: "background", scope: .workspace(ws1))
        try store.setValue("#222222", for: "background", scope: .workspace(ws2))
        try store.setValue("17", for: "font-size", scope: .pane(pane))
        try store.setValue("#aabbcc", for: "selection-background", scope: .pane(pane))

        let inWs1 = store.effectiveTheme(global: global, workspaceID: ws1, paneID: pane)
        #expect(inWs1.background == color("#111111"))
        #expect(inWs1.fontSize == 17)
        #expect(inWs1.selectionBackground == color("#aabbcc"))

        let inWs2 = store.effectiveTheme(global: global, workspaceID: ws2, paneID: pane)
        #expect(inWs2.background == color("#222222"))
        #expect(inWs2.fontSize == 17)
        #expect(inWs2.selectionBackground == color("#aabbcc"))
    }

    @Test func presetVsFontPreservationWithSpacesInName() throws {
        let tempDir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let themeFileName = "Solarized Dark Custom"
        let themeFile = tempDir.appendingPathComponent(themeFileName)
        try "background = #002b36\nforeground = #839496\nfont-size = 99\nfont-family = \"IgnoredInPreset\"\n".write(
            to: themeFile,
            atomically: true,
            encoding: .utf8
        )

        let store = ScopedAppearanceStore(fileURL: tempDir.appendingPathComponent("Appearance.json"), themeSearchPaths: [tempDir.path])
        let global = TerminalTheme(background: color("#000000"), fontFamily: "Menlo", fontSize: 13)
        let wsID = UUID()

        try store.setValue(themeFileName, for: "theme", scope: .workspace(wsID))
        #expect(store.value(for: "theme", scope: .workspace(wsID)) == themeFileName)

        let effective = store.effectiveTheme(global: global, workspaceID: wsID, paneID: nil)
        #expect(effective.background == color("#002b36"))
        #expect(effective.foreground == color("#839496"))
        #expect(effective.fontFamily == "Menlo")
        #expect(effective.fontSize == 13)
    }

    @Test func roundtripAndPersistence() throws {
        let tempDir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("Appearance.json")
        let store1 = ScopedAppearanceStore(fileURL: fileURL)
        let wsID = UUID()
        let paneID = UUID()

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .takoScopedAppearanceDidChange,
            object: store1,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try store1.setValue("Dark Theme", for: "theme", scope: .workspace(wsID))
        try store1.setValue("SF Mono", for: "font-family", scope: .workspace(wsID))
        try store1.setValue("15", for: "font-size", scope: .workspace(wsID))
        try store1.setValue("#123456", for: "background", scope: .workspace(wsID))
        try store1.setValue("#654321", for: "foreground", scope: .workspace(wsID))
        try store1.setValue("#abcdef", for: "cursor-color", scope: .pane(paneID))
        try store1.setValue("#fedcba", for: "selection-background", scope: .pane(paneID))

        #expect(notificationCount == 7)

        // Remove an override with nil
        try store1.setValue(nil, for: "foreground", scope: .workspace(wsID))
        #expect(notificationCount == 8)
        #expect(store1.value(for: "foreground", scope: .workspace(wsID)) == nil)

        // Verify fresh store instance roundtrips from disk
        let store2 = ScopedAppearanceStore(fileURL: fileURL)
        #expect(store2.value(for: "theme", scope: .workspace(wsID)) == "Dark Theme")
        #expect(store2.value(for: "font-family", scope: .workspace(wsID)) == "SF Mono")
        #expect(store2.value(for: "font-size", scope: .workspace(wsID)) == "15")
        #expect(store2.value(for: "background", scope: .workspace(wsID)) == "#123456")
        #expect(store2.value(for: "foreground", scope: .workspace(wsID)) == nil)
        #expect(store2.value(for: "cursor-color", scope: .pane(paneID)) == "#abcdef")
        #expect(store2.value(for: "selection-background", scope: .pane(paneID)) == "#fedcba")
    }

    @Test func unknownAndCorruptProtection() throws {
        let tempDir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Corrupt JSON
        let corruptURL = tempDir.appendingPathComponent("corrupt.json")
        let corruptContent = "{ not valid json"
        try corruptContent.write(to: corruptURL, atomically: true, encoding: .utf8)

        let corruptStore = ScopedAppearanceStore(fileURL: corruptURL)
        #expect(throws: AppearanceStoreError.self) {
            try corruptStore.setValue("#112233", for: "background", scope: .workspace(UUID()))
        }
        #expect(throws: AppearanceStoreError.self) {
            try corruptStore.reset(.workspace(UUID()))
        }
        let diskAfterCorrupt = try String(contentsOf: corruptURL, encoding: .utf8)
        #expect(diskAfterCorrupt == corruptContent)

        // 2. Unknown Version
        let unknownVersionURL = tempDir.appendingPathComponent("unknown_version.json")
        let unknownVersionContent = "{\"version\": 99, \"workspaces\": {}}"
        try unknownVersionContent.write(to: unknownVersionURL, atomically: true, encoding: .utf8)

        let versionStore = ScopedAppearanceStore(fileURL: unknownVersionURL)
        #expect(throws: AppearanceStoreError.self) {
            try versionStore.setValue("#112233", for: "background", scope: .workspace(UUID()))
        }
        #expect(throws: AppearanceStoreError.self) {
            try versionStore.reset(.workspace(UUID()))
        }
        let diskAfterVersion = try String(contentsOf: unknownVersionURL, encoding: .utf8)
        #expect(diskAfterVersion == unknownVersionContent)
    }

    @Test func invalidInputs() throws {
        let tempDir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ScopedAppearanceStore(fileURL: tempDir.appendingPathComponent("Appearance.json"))
        let scope = AppearanceScope.workspace(UUID())

        var notified = false
        let observer = NotificationCenter.default.addObserver(
            forName: .takoScopedAppearanceDidChange,
            object: store,
            queue: nil
        ) { _ in
            notified = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Unknown keys
        #expect(throws: AppearanceStoreError.self) { try store.setValue("value", for: "unknown-key", scope: scope) }
        #expect(throws: AppearanceStoreError.self) { try store.setValue("14", for: "fontSize", scope: scope) }

        // Font size bounds & numbers
        #expect(throws: AppearanceStoreError.self) { try store.setValue("5.9", for: "font-size", scope: scope) }
        #expect(throws: AppearanceStoreError.self) { try store.setValue("72.1", for: "font-size", scope: scope) }
        #expect(throws: AppearanceStoreError.self) { try store.setValue("abc", for: "font-size", scope: scope) }
        #expect(throws: AppearanceStoreError.self) { try store.setValue("NaN", for: "font-size", scope: scope) }

        // Colors
        #expect(throws: AppearanceStoreError.self) { try store.setValue("#12345", for: "background", scope: scope) }
        #expect(throws: AppearanceStoreError.self) { try store.setValue("#1234567", for: "background", scope: scope) }
        #expect(throws: AppearanceStoreError.self) { try store.setValue("blue", for: "background", scope: scope) }
        #expect(throws: AppearanceStoreError.self) { try store.setValue("", for: "background", scope: scope) }

        // Names (nonempty & control-free)
        #expect(throws: AppearanceStoreError.self) { try store.setValue("", for: "theme", scope: scope) }
        #expect(throws: AppearanceStoreError.self) { try store.setValue("   ", for: "theme", scope: scope) }
        #expect(throws: AppearanceStoreError.self) { try store.setValue("Theme\nName", for: "theme", scope: scope) }
        #expect(throws: AppearanceStoreError.self) { try store.setValue("Theme\0Name", for: "theme", scope: scope) }
        #expect(throws: AppearanceStoreError.self) { try store.setValue("Font\tFamily", for: "font-family", scope: scope) }

        #expect(!notified)
    }

    @Test func failedPersistenceDoesNotPublish() throws {
        let tempDir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a regular file so attempting to write inside it fails with ENOTDIR
        let regularFile = tempDir.appendingPathComponent("blocker_file")
        try "regular file content".write(to: regularFile, atomically: true, encoding: .utf8)

        let unwritableURL = regularFile.appendingPathComponent("Appearance.json")
        let store = ScopedAppearanceStore(fileURL: unwritableURL)
        let scope = AppearanceScope.workspace(UUID())

        var notified = false
        let observer = NotificationCenter.default.addObserver(
            forName: .takoScopedAppearanceDidChange,
            object: store,
            queue: nil
        ) { _ in
            notified = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        var failed = false
        do {
            try store.setValue("#112233", for: "background", scope: scope)
        } catch {
            failed = true
        }

        #expect(failed)
        #expect(store.value(for: "background", scope: scope) == nil)
        #expect(!notified)
    }
}
