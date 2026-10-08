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

    @Test
    func findConflictIdentifiesShadowedDefaultHolder() {
        // Config assigns cmd+t to close_surface.
        // The active parser unbinds new_tab, so close_surface is the active holder of cmd+t.
        // Checking cmd+t against another action (e.g. new_split:right) must report close_surface, NOT new_tab.
        let configLines = [
            "keybind = cmd+t=close_surface"
        ]
        let conflict = KeybindRegistry.findConflict(
            for: "cmd+t",
            targetAction: "new_split:right",
            configLines: configLines
        )
        #expect(conflict != nil)
        #expect(conflict?.id == "close_surface")
        #expect(conflict?.title == "Close Split / Tab")
    }

    @Test
    func findConflictDetectsShiftedPunctuationEquivalence() {
        // Config assigns cmd+shift+! to close_surface.
        // Runtime MenuShortcutKey normalizes cmd+shift+! to key "1" with [.command, .shift].
        // Checking cmd+shift+1 against another action must detect conflict with close_surface.
        let configLines = [
            "keybind = cmd+shift+!=close_surface"
        ]
        let conflict = KeybindRegistry.findConflict(
            for: "cmd+shift+1",
            targetAction: "new_split:right",
            configLines: configLines
        )
        #expect(conflict != nil)
        #expect(conflict?.id == "close_surface")
        #expect(conflict?.title == "Close Split / Tab")
    }

    @Test
    func findConflictDetectsUnshiftedToShiftedPunctuationEquivalence() {
        // Existing binding in config is cmd+shift+1.
        // Recording cmd+shift+! (or pressing Shift+1) must report conflict.
        let configLines = [
            "keybind = cmd+shift+1=close_surface"
        ]
        let conflict = KeybindRegistry.findConflict(
            for: "cmd+shift+!",
            targetAction: "new_split:right",
            configLines: configLines
        )
        #expect(conflict != nil)
        #expect(conflict?.id == "close_surface")
    }

    @Test
    func findConflictReturnsNilWhenDefaultIsUnbound() {
        // Config unbinds cmd+t.
        // Checking cmd+t against new_split:right should return nil because cmd+t is free.
        let configLines = [
            "keybind = cmd+t=unbind"
        ]
        let conflict = KeybindRegistry.findConflict(
            for: "cmd+t",
            targetAction: "new_split:right",
            configLines: configLines
        )
        #expect(conflict == nil)
    }

    @Test
    func findConflictDetectsQuitDefaultShortcut() {
        // Quit is bound to cmd+q by default. Recording cmd+q for new_tab must report conflict.
        let conflict = KeybindRegistry.findConflict(
            for: "cmd+q",
            targetAction: "new_tab",
            configLines: []
        )
        #expect(conflict != nil)
        #expect(conflict?.id == "quit")
        #expect(conflict?.title == "Quit Tako")
    }

    @Test
    func findConflictDetectsCloseAllWindowsDefaultShortcut() {
        // close_all_windows defaults to cmd+opt+shift+w.
        let conflict = KeybindRegistry.findConflict(
            for: "cmd+opt+shift+w",
            targetAction: "new_tab",
            configLines: []
        )
        #expect(conflict != nil)
        #expect(conflict?.id == "close_all_windows")
        #expect(conflict?.title == "Close All Windows")
    }

    @Test
    func findConflictDetectsCustomUnregisteredAction() {
        // A custom action in config not present in defaultKeyboardShortcuts.
        let configLines = [
            "keybind = cmd+k=custom_external_action"
        ]
        let conflict = KeybindRegistry.findConflict(
            for: "cmd+k",
            targetAction: "new_tab",
            configLines: configLines
        )
        #expect(conflict != nil)
        #expect(conflict?.id == "custom_external_action")
        #expect(conflict?.title == "Custom External Action")
    }
}
