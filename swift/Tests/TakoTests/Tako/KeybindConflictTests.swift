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
import SwiftUI
import Testing
@testable import Tako

@Suite
@MainActor
struct KeybindConflictTests {
    @Test
    func normalizeTriggerCanonicalOrder() {
        #expect(KeybindRegistry.normalizeTrigger("cmd+opt+t") == "opt+cmd+t")
        #expect(KeybindRegistry.normalizeTrigger("opt+cmd+t") == "opt+cmd+t")
        #expect(KeybindRegistry.normalizeTrigger("super+shift+d") == "shift+cmd+d")
        #expect(KeybindRegistry.normalizeTrigger("shift+super+d") == "shift+cmd+d")
        #expect(KeybindRegistry.normalizeTrigger("ctrl+shift+tab") == "ctrl+shift+tab")
        #expect(KeybindRegistry.normalizeTrigger("shift+ctrl+tab") == "ctrl+shift+tab")
    }

    @Test
    func triggerFromKeyboardShortcut() {
        let cmdT = SwiftUI.KeyboardShortcut("t", modifiers: .command)
        #expect(KeybindRegistry.trigger(for: cmdT) == "cmd+t")

        let shiftCmdReturn = SwiftUI.KeyboardShortcut(.return, modifiers: [.command, .shift])
        #expect(KeybindRegistry.normalizeTrigger(KeybindRegistry.trigger(for: shiftCmdReturn)) == "shift+cmd+return")

        let ctrlTab = SwiftUI.KeyboardShortcut(.tab, modifiers: .control)
        #expect(KeybindRegistry.trigger(for: ctrlTab) == "ctrl+tab")
    }

    @Test
    func findConflictWithDefaultShortcut() {
        // "new_tab" defaults to cmd+t. Assigning cmd+t to "new_split:right" should report conflict with "new_tab".
        let conflict = KeybindRegistry.findConflict(
            for: "cmd+t",
            targetAction: "new_split:right",
            customOverrides: [:]
        )
        #expect(conflict != nil)
        #expect(conflict?.id == "new_tab")
        #expect(conflict?.title == "New Tab")
    }

    @Test
    func findConflictIgnoresTargetActionSelf() {
        // Assigning cmd+t to "new_tab" itself is not a conflict.
        let conflict = KeybindRegistry.findConflict(
            for: "cmd+t",
            targetAction: "new_tab",
            customOverrides: [:]
        )
        #expect(conflict == nil)
    }

    @Test
    func findConflictWithCustomOverride() {
        // An action with a custom override should be detected when another action tries to claim it.
        var overrides: [String: String] = [:]
        overrides["close_surface"] = "cmd+k"

        let conflict = KeybindRegistry.findConflict(
            for: "cmd+k",
            targetAction: "new_split:down",
            customOverrides: overrides
        )
        #expect(conflict != nil)
        #expect(conflict?.id == "close_surface")
        #expect(conflict?.title == "Close Split / Tab")
    }

    @Test
    func findConflictReturnsNilForUnusedTrigger() {
        // Rare modifier combination not bound to any action.
        let conflict = KeybindRegistry.findConflict(
            for: "ctrl+opt+shift+cmd+z",
            targetAction: "new_tab",
            customOverrides: [:]
        )
        #expect(conflict == nil)
    }

    @Test
    func findConflictMatchesAcrossEquivalentTriggerSyntax() {
        // "super+t" and "cmd+t" both refer to Command+T and should detect conflict.
        let conflict = KeybindRegistry.findConflict(
            for: "super+t",
            targetAction: "new_split:down",
            customOverrides: [:]
        )
        #expect(conflict != nil)
        #expect(conflict?.id == "new_tab")
    }
}
