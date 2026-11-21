/*
 * tako — Status-driven menu rebuilds must not rediscover theme files
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Testing
@testable import Tako

@MainActor @Suite(.serialized)
struct DesktopAppearanceMenuCatalogTests {
    @Test func repeatedSidebarMenuBuildsReuseDiskMetadataButKeepScopeSelectionLive() throws {
        let sandbox = try DesktopSettingsTests.Sandbox()
        let scopes = sandbox.scopes()
        let notifications = NotificationCenter()
        var reads = 0
        let catalog = DesktopAppearanceMenuCatalog(notifications: notifications) { _ in
            reads += 1
            return .init(paths: [sandbox.builtin.path], names: ["Base", "Typed"], globalTheme: "Base")
        }
        let id = WorkspaceStore.defaultWorkspaceId
        let level = DesktopScopeLevel(kind: .workspace(id), kindTitle: "workspace", name: "Default")
        for _ in 0..<200 {
            let menu = try #require(DesktopAppearanceMenu.make(for: level, app: nil, store: scopes,
                                                              window: nil, catalog: catalog))
            #expect(menu.inherited == "Base" && menu.selected == nil)
        }
        #expect(reads == 1, "Status updates must not rediscover theme files for every sidebar row")
        try scopes.setValue("Typed", for: "theme", scope: .workspace(id))
        let selected = try #require(DesktopAppearanceMenu.make(for: level, app: nil, store: scopes,
                                                              window: nil, catalog: catalog))
        #expect(selected.selected == "Typed" && selected.presets.first == "Typed")
        #expect(reads == 1, "Scope changes are in-memory and must not trigger catalog IO")
        notifications.post(name: .takoThemePresetsDidChange, object: nil)
        _ = catalog.snapshot(configPath: nil)
        #expect(reads == 2, "Saving, renaming or deleting a theme refreshes the catalog")
        notifications.post(name: .takoConfigDidChange, object: nil)
        _ = catalog.snapshot(configPath: nil)
        #expect(reads == 3, "Config reload refreshes inherited global values")
    }

    @Test func configurationIdentitiesDoNotShareMetadataAndInvalidationIsComplete() {
        let notifications = NotificationCenter()
        var reads = 0
        let catalog = DesktopAppearanceMenuCatalog(notifications: notifications) { path in
            reads += 1
            return .init(paths: [], names: [path ?? "default"], globalTheme: path ?? "default")
        }
        #expect(catalog.snapshot(configPath: "/a/config").globalTheme == "/a/config")
        #expect(catalog.snapshot(configPath: "/b/config").globalTheme == "/b/config")
        _ = catalog.snapshot(configPath: "/a/config")
        #expect(reads == 2)
        notifications.post(name: .takoConfigDidChange, object: nil)
        _ = catalog.snapshot(configPath: "/a/config")
        _ = catalog.snapshot(configPath: "/b/config")
        #expect(reads == 4)
    }
}
