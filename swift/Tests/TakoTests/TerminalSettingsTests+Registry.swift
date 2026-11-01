/*
 * tako — Terminal settings registry tests
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Testing
@testable import Tako

extension TerminalSettingsTests {
    @Test func registryContainsWorkspaceSyncWindowFrame() {
        let item = TerminalSettingRegistry.setting(for: "workspace-sync-window-frame")
        #expect(item != nil)
        #expect(item?.id == "workspace-sync-window-frame")
        #expect(item?.category == "Workspaces")
        #expect(item?.type == .boolean(defaultValue: false))
        #expect(item?.aliases.contains("workspace-inherit-window-frame") == true)
        let aliasItem = TerminalSettingRegistry.setting(for: "workspace-inherit-window-frame")
        #expect(aliasItem?.id == "workspace-sync-window-frame")
    }

    @Test func settingTypeNextAndPreviousValue() {
        let boolType = TerminalSettingType.boolean(defaultValue: false)
        #expect(boolType.defaultStringValue == "false")
        #expect(boolType.nextValue(current: "false") == "true")
        #expect(boolType.nextValue(current: "true") == "false")

        let optType = TerminalSettingType.options(options: ["modern", "native", "classic"], defaultValue: "modern")
        #expect(optType.defaultStringValue == "modern")
        #expect(optType.nextValue(current: "modern") == "native")
        #expect(optType.nextValue(current: "native") == "classic")
        #expect(optType.nextValue(current: "classic") == "modern")
        #expect(optType.previousValue(current: "classic") == "native")
        #expect(optType.previousValue(current: "modern") == "classic")

        let numType = TerminalSettingType.number(defaultValue: 13, min: 10, max: 15, step: 2)
        #expect(numType.defaultStringValue == "13")
        #expect(numType.nextValue(current: "13") == "15")
        #expect(numType.nextValue(current: "15") == "10")
        #expect(numType.previousValue(current: "10") == "15")
    }
}
