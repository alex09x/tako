/*
 * tako — «Оформление ▸» context menu tests
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

@MainActor
struct DesktopAppearanceMenuTests {
    private func menu(_ sandbox: DesktopSettingsTests.Sandbox, store: ScopedAppearanceStore, workspace: UUID,
                      opened: @escaping (Bool) -> Void = { _ in }) -> DesktopAppearanceMenu {
        let context = ScopedAppearanceContext(scope: .workspace(workspace), title: "workspace «W»", store: store,
                                              globalTheme: { .takoDefault })
        let own = context.value(for: "theme")
        var menu = DesktopAppearanceMenu(level: .init(kind: .workspace(workspace), kindTitle: "workspace", name: "W"),
                                         context: context,
                                         presets: DesktopAppearanceMenu.choices(["Base", "Typed", "A", "B", "C", "D", "E"], selected: own),
                                         themePaths: [sandbox.builtin.path], selected: own, inherited: "TakoCore")
        menu.openSettings = opened
        return menu
    }

    @Test func presetsPutTheLevelsOwnFirstAndStopAtSix() {
        let names = ["TakoCore", "Tako Dawn", "Tako Ember", "Tako Forest", "Tako Ink", "Tako Night", "Tako Ocean"]
        #expect(DesktopAppearanceMenu.choices(names, selected: nil) == Array(names.prefix(6)))
        let night = DesktopAppearanceMenu.choices(names, selected: "tako night")
        #expect(night.first == "Tako Night" && night.count == 6 && Set(night).count == 6)
        #expect(DesktopAppearanceMenu.choices(names, selected: "Gone").first == "TakoCore", "a missing theme is not offered")
    }

    /// The same rule as Settings: a full preset replaces the level's own
    /// fields, a colours-only one keeps them; «Наследовать» drops only this level.
    @Test func choosingFollowsTheSettingsRuleAndInheritResetsOnlyThisLevel() throws {
        let sandbox = try DesktopSettingsTests.Sandbox()
        let store = sandbox.scopes()
        let ws = UUID(), other = UUID()
        try store.setValue("#123456", for: "background", scope: .workspace(ws))
        try store.setValue("Base", for: "theme", scope: .workspace(other))

        menu(sandbox, store: store, workspace: ws).choose("Base")
        #expect(store.value(for: "theme", scope: .workspace(ws)) == "Base")
        #expect(store.value(for: "background", scope: .workspace(ws)) == "#123456")

        menu(sandbox, store: store, workspace: ws).choose("Typed")
        #expect(store.value(for: "theme", scope: .workspace(ws)) == "Typed")
        #expect(store.value(for: "background", scope: .workspace(ws)) == nil)

        let current = menu(sandbox, store: store, workspace: ws)
        #expect(current.isSelected("typed") && !current.inherits && current.presets.first == "Typed")
        current.inherit()
        #expect(store.document.overrides(for: .workspace(ws))?.isEmpty != false)
        #expect(store.value(for: "theme", scope: .workspace(other)) == "Base", "other levels untouched")
        #expect(menu(sandbox, store: store, workspace: ws).inherits)
    }

    @Test func appKitMenuNamesEveryItemMarksTheChoiceAndOpensSettings() throws {
        let sandbox = try DesktopSettingsTests.Sandbox()
        let store = sandbox.scopes()
        let ws = UUID()
        try store.setValue("Base", for: "theme", scope: .workspace(ws))
        var opened: [Bool] = []
        let item = menu(sandbox, store: store, workspace: ws) { opened.append($0) }.menuItem()
        #expect(item.title == "Appearance" && item.identifier?.rawValue == "DesktopAppearanceMenu")
        let entries = try #require(item.submenu).items
        let ids = entries.compactMap { $0.identifier?.rawValue }
        #expect(ids.first == "DesktopAppearanceInherit")
        #expect(ids.contains("DesktopAppearancePreset-Base") && ids.contains("DesktopAppearancePreset-Typed"))
        #expect(Array(ids.suffix(2)) == ["DesktopAppearanceAllThemes", "DesktopAppearanceEdit"])
        #expect(entries.first?.title == "Inherit · TakoCore" && entries.first?.state == .off)
        #expect(entries.first { $0.identifier?.rawValue == "DesktopAppearancePreset-Base" }?.state == .on)
        #expect(entries.filter { $0.identifier?.rawValue.hasPrefix("DesktopAppearancePreset-") == true }.count <= 6)

        func press(_ id: String) throws {
            let entry = try #require(entries.first { $0.identifier?.rawValue == id })
            _ = (entry.target as? NSObject)?.perform(try #require(entry.action), with: entry)
        }
        try press("DesktopAppearanceAllThemes")
        try press("DesktopAppearanceEdit")
        #expect(opened == [false, true])
        try press("DesktopAppearancePreset-Typed")
        #expect(store.value(for: "theme", scope: .workspace(ws)) == "Typed")
        try press("DesktopAppearanceInherit")
        #expect(store.document.overrides(for: .workspace(ws))?.isEmpty != false)
    }
}
