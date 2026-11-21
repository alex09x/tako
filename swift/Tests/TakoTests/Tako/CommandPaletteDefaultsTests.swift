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
@testable import Tako

struct CommandPaletteDefaultsTests {
    @Test func usefulCommandsHaveStableTitlesAndConcreteActions() throws {
        let commands = try TemporaryConfig("").commandPaletteEntries
        let expected = [
            "clear_screen": "Clear Screen",
            "close_all_windows": "Close All Windows",
            "new_tab": "New Tab",
            "new_window": "New Window",
            "copy_to_clipboard": "Copy",
            "paste_from_clipboard": "Paste",
            "start_search": "Find in Current Tab",
            "new_split:right": "Split Right (Vertical)",
            "resize_split:left,10": "Resize Split Left",
            "increase_font_size:1": "Increase Font Size",
            "navigate_search:next": "Find Next",
        ]
        for (action, title) in expected {
            let matches = commands.filter { $0.action == action }
            #expect(matches.count == 1)
            #expect(matches.first?.title == title)
        }
    }

    @Test func entriesAreUniqueSupportedMetadataWithoutBareParameterizedActions() throws {
        let commands = try TemporaryConfig("").commandPaletteEntries
        #expect(!commands.isEmpty)
        #expect(Set(commands.map(\.action)).count == commands.count)
        #expect(Set(commands.map(\.title)).count == commands.count)
        let requiresParameter: Set<String> = [
            "goto_tab", "move_tab", "new_split", "goto_split", "resize_split",
            "navigate_search", "scroll_page_lines", "text", "csi", "esc", "search",
        ]
        for command in commands {
            #expect(!command.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!command.action.isEmpty)
            #expect(command.isSupported)
            #expect(Tako.SurfaceView.isBindingActionSupported(command.action))
            let parts = command.action.split(separator: ":", maxSplits: 1)
            #expect(command.actionKey == String(parts[0]))
            if requiresParameter.contains(command.actionKey) {
                #expect(parts.count == 2)
                #expect(parts.last?.isEmpty == false)
            }
        }
        // Recognition only: never dispatch close-all or any other command here.
        #expect(!commands.contains { ["quit", "new_workspace", "text", "search"].contains($0.action) })
    }

    @Test func defaultsSurviveKeybindOverridesAndConfigurationReload() throws {
        let config = try TemporaryConfig("")
        let defaults = config.commandPaletteEntries
        try config.reload("keybind = clear\nkeybind = cmd+k=clear_screen")
        #expect(config.commandPaletteEntries == defaults)
        #expect(config.keyboardShortcut(for: "clear_screen") != nil)
        #expect(config.keyboardShortcut(for: "close_all_windows") == nil)
    }
}
