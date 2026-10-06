/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Tako
import TakoKit

// MARK: - Config defaults not already covered by ConfigTests.swift

@Suite
struct ConfigDefaultsCoverageTests {
    @Test func bellFeaturesDefaultsToEmpty() throws {
        let config = try TemporaryConfig("")
        #expect(config.bellFeatures.isEmpty)
    }

    @Test func bellAudioDefaults() throws {
        let config = try TemporaryConfig("")
        #expect(config.bellAudioPath == nil)
        #expect(config.bellAudioVolume == 0.5)
    }

    @Test func notifyOnCommandFinishDefaults() throws {
        let config = try TemporaryConfig("")
        #expect(config.notifyOnCommandFinish == .never)
        #expect(config.notifyOnCommandFinishAction == .bell)
        #expect(config.notifyOnCommandFinishAfter == .seconds(5))
    }

    @Test func splitPreserveZoomDefaultsToEmpty() throws {
        let config = try TemporaryConfig("")
        #expect(config.splitPreserveZoom.isEmpty)
    }

    @Test func windowSaveStateIsAlways() throws {
        let config = try TemporaryConfig("")
        #expect(config.windowSaveState == "always")
    }

    @Test func windowNewTabPositionDefaultsToEmpty() throws {
        let config = try TemporaryConfig("")
        #expect(config.windowNewTabPosition == "")
    }

    @Test func windowThemeDefaultsToNil() throws {
        let config = try TemporaryConfig("")
        #expect(config.windowTheme == nil)
    }

    @Test func windowFullscreenDefaultsToNil() throws {
        let config = try TemporaryConfig("")
        #expect(config.windowFullscreen == nil)
        #expect(config.windowFullscreenMode == .native)
    }

    @Test func macosTitlebarProxyIconDefaultsToVisible() throws {
        let config = try TemporaryConfig("")
        #expect(config.macosTitlebarProxyIcon == .visible)
    }

    @Test func macosDockDropBehaviorDefaultsToNewTab() throws {
        let config = try TemporaryConfig("")
        #expect(config.macosDockDropBehavior == .new_tab)
        #expect(Tako.Config.MacDockDropBehavior(rawValue: "new-window") == .new_window)
    }

    @Test func macosCustomIconDefaultsToEmpty() throws {
        let config = try TemporaryConfig("")
        #expect(config.macosCustomIcon == "")
    }

    @Test func macosIconColorsDefaultToNil() throws {
        let config = try TemporaryConfig("")
        #expect(config.macosIconGhostColor == nil)
        #expect(config.macosIconScreenColor == nil)
    }

    @Test func macosHiddenDefaultsToNever() throws {
        let config = try TemporaryConfig("")
        #expect(config.macosHidden == .never)
        #expect(Tako.Config.MacHidden(rawValue: "always") == .always)
    }

    @Test func backgroundColorUsesTheme() throws {
        let config = try TemporaryConfig("")
        #expect(config.backgroundColor != nil)
    }

    @Test func backgroundBlurDisabledByDefault() throws {
        let config = try TemporaryConfig("")
        #expect(config.backgroundBlur == .disabled)
    }

    @Test func unfocusedSplitDefaults() throws {
        let config = try TemporaryConfig("")
        #expect(config.unfocusedSplitOpacity == 0.15)
        #expect(config.unfocusedSplitFill == .white)
        #expect(config.splitDividerColor != nil)
    }

    @Test func quickTerminalDefaults() throws {
        let config = try TemporaryConfig("")
        #expect(config.quickTerminalPosition == .top)
        #expect(config.quickTerminalScreen == .main)
        #expect(config.quickTerminalAnimationDuration == 0.2)
        #expect(config.quickTerminalAutoHide == true)
        #expect(config.quickTerminalSpaceBehavior == .move)
        #expect(config.quickTerminalSize.primary == nil)
    }

    @Test func resizeOverlayDurationIsOneSecond() throws {
        let config = try TemporaryConfig("")
        #expect(config.resizeOverlayDuration == 1000)
    }

    @Test func resizeOverlayPositionDirections() throws {
        #expect(Tako.Config.ResizeOverlayPosition.top_left.top())
        #expect(Tako.Config.ResizeOverlayPosition.top_left.left())
        #expect(!Tako.Config.ResizeOverlayPosition.top_left.bottom())
        #expect(!Tako.Config.ResizeOverlayPosition.top_left.right())

        #expect(Tako.Config.ResizeOverlayPosition.bottom_right.bottom())
        #expect(Tako.Config.ResizeOverlayPosition.bottom_right.right())
        #expect(!Tako.Config.ResizeOverlayPosition.bottom_right.top())
        #expect(!Tako.Config.ResizeOverlayPosition.bottom_right.left())

        #expect(!Tako.Config.ResizeOverlayPosition.center.top())
        #expect(!Tako.Config.ResizeOverlayPosition.center.bottom())
        #expect(!Tako.Config.ResizeOverlayPosition.center.left())
        #expect(!Tako.Config.ResizeOverlayPosition.center.right())
    }

    @Test func undoTimeoutIsFiveSeconds() throws {
        let config = try TemporaryConfig("")
        #expect(config.undoTimeout == .seconds(5))
    }

    @Test func autoUpdateChannelDefaultsToStable() throws {
        let config = try TemporaryConfig("")
        #expect(config.autoUpdateChannel == .stable)
        #expect(Tako.AutoUpdateChannel(rawValue: "tip") != nil)
    }

    @Test func secureInputDefaultsToOn() throws {
        let config = try TemporaryConfig("")
        #expect(config.autoSecureInput == true)
        #expect(config.secureInputIndication == true)
    }


    @Test func abnormalCommandExitRuntimeDefault() throws {
        let config = try TemporaryConfig("")
        #expect(config.abnormalCommandExitRuntime == .milliseconds(250))
    }

    @Test func commandPaletteEntriesDefaultsToEmpty() throws {
        let config = try TemporaryConfig("")
        #expect(config.commandPaletteEntries.isEmpty)
    }

    @Test func progressStyleDefaultsToTrue() throws {
        let config = try TemporaryConfig("")
        #expect(config.progressStyle == true)
    }

    @Test func defaultConfigInitLoadsWithoutAPath() {
        let config = Tako.Config()
        #expect(config.loaded == false)
        #expect(config.errors.isEmpty)
    }

    @Test func cloneConvenienceInitCopiesConfig() throws {
        let base = try TemporaryConfig("title = Cloned")
        let cloned = Tako.Config(clone: base.config)
        #expect(cloned.title == "Cloned")
    }

    @Test func keybindWithControlAndOptionModifiers() throws {
        let config = try TemporaryConfig("keybind=ctrl+alt+x=goto_split:up")
        let shortcut = try #require(config.keyboardShortcut(for: "goto_split:up"))
        #expect(shortcut == .init("x", modifiers: [.control, .option]))
    }

    /// Dropping the modifier it does not know would bind the action to a bare
    /// `z`, which then fires on every z typed.
    @Test func keybindWithUnrecognizedModifierIsSkipped() throws {
        let config = try TemporaryConfig("keybind=fn+z=goto_split:down")
        #expect(config.keyboardShortcut(for: "goto_split:down") == nil)
    }

    /// Upstream's own quick-terminal recipe. The prefix used to be read as a
    /// modifier and dropped, and the key name cut to its first letter, which
    /// bound the quick terminal to a bare `g`.
    @Test func keybindPrefixesAreStrippedAndKeyNamesResolved() throws {
        let config = try TemporaryConfig("""
        keybind = global:cmd+grave_accent=toggle_quick_terminal
        keybind = all:unconsumed:ctrl+backquote=toggle_visibility
        keybind = performable:cmd+key_k=clear_screen
        """)
        #expect(config.keyboardShortcut(for: "toggle_quick_terminal") == .init("`", modifiers: .command))
        #expect(config.keyboardShortcut(for: "toggle_visibility") == .init("`", modifiers: .control))
        #expect(config.keyboardShortcut(for: "clear_screen") == .init("k", modifiers: .command))
    }

    @Test func keybindNamedKeysMapToTheirKeyEquivalents() throws {
        let config = try TemporaryConfig("""
        keybind = cmd+enter=toggle_fullscreen
        keybind = ctrl+page_up=previous_tab
        keybind = cmd+arrow_left=goto_split:left
        keybind = cmd+shift+up=goto_split:up
        keybind = f5=reload_config
        keybind = cmd+digit_3=goto_tab:3
        keybind = cmd+seven=goto_tab:7
        keybind = ctrl+bracket_left=goto_split:previous
        keybind = super+backslash=equalize_splits
        keybind = alt+tab=toggle_tab_overview
        keybind = opt+space=toggle_command_palette
        keybind = cmd+escape=end_search
        keybind = cmd+backspace=clear_line
        keybind = cmd+delete=delete_word
        keybind = ctrl+home=scroll_to_top
        keybind = ctrl+end=scroll_to_bottom
        keybind = shift+page_down=scroll_page_down
        keybind = cmd+plus=increase_font_size:2
        """)
        #expect(config.keyboardShortcut(for: "toggle_fullscreen") == .init(.return, modifiers: .command))
        #expect(config.keyboardShortcut(for: "previous_tab") == .init(.pageUp, modifiers: .control))
        #expect(config.keyboardShortcut(for: "goto_split:left") == .init(.leftArrow, modifiers: .command))
        #expect(config.keyboardShortcut(for: "goto_split:up") == .init(.upArrow, modifiers: [.command, .shift]))
        let f5 = Character(UnicodeScalar(NSF5FunctionKey)!)
        #expect(config.keyboardShortcut(for: "reload_config") == .init(KeyEquivalent(f5), modifiers: []))
        #expect(config.keyboardShortcut(for: "goto_tab:3") == .init("3", modifiers: .command))
        #expect(config.keyboardShortcut(for: "goto_tab:7") == .init("7", modifiers: .command))
        #expect(config.keyboardShortcut(for: "goto_split:previous") == .init("[", modifiers: .control))
        #expect(config.keyboardShortcut(for: "equalize_splits") == .init("\\", modifiers: .command))
        #expect(config.keyboardShortcut(for: "toggle_tab_overview") == .init(.tab, modifiers: .option))
        #expect(config.keyboardShortcut(for: "toggle_command_palette") == .init(.space, modifiers: .option))
        #expect(config.keyboardShortcut(for: "end_search") == .init(.escape, modifiers: .command))
        #expect(config.keyboardShortcut(for: "clear_line") == .init(.delete, modifiers: .command))
        #expect(config.keyboardShortcut(for: "delete_word") == .init(.deleteForward, modifiers: .command))
        #expect(config.keyboardShortcut(for: "scroll_to_top") == .init(.home, modifiers: .control))
        #expect(config.keyboardShortcut(for: "scroll_to_bottom") == .init(.end, modifiers: .control))
        #expect(config.keyboardShortcut(for: "scroll_page_down") == .init(.pageDown, modifiers: .shift))
        #expect(config.keyboardShortcut(for: "increase_font_size:2") == .init("+", modifiers: .command))
    }

    @Test func anEqualsSignRightAfterAPlusIsTheKey() throws {
        let config = try TemporaryConfig("keybind = ctrl+==increase_font_size:3")
        #expect(config.keyboardShortcut(for: "increase_font_size:3") == .init("=", modifiers: .control))
    }

    /// Lines a menu item cannot carry leave the action's default alone
    /// instead of replacing it with a guess.
    @Test func keybindsWithoutAMenuShortcutKeepTheDefault() throws {
        let config = try TemporaryConfig("""
        keybind = cmd+numpad_add=new_tab
        keybind = ctrl+a>n=new_window
        keybind = cmd+f99=select_all
        keybind = cmd+=
        """)
        #expect(config.keyboardShortcut(for: "new_tab") == .init("t", modifiers: .command))
        #expect(config.keyboardShortcut(for: "new_window") == .init("n", modifiers: .command))
        #expect(config.keyboardShortcut(for: "select_all") == .init("a", modifiers: .command))
    }

    /// One trigger, one action: the split that held Cmd+D must not keep
    /// showing it next to New Window.
    @Test func bindingATriggerTakesItFromTheActionThatHadIt() throws {
        let config = try TemporaryConfig("""
        keybind = cmd+d=new_window
        keybind = cmd+j=new_tab
        keybind = cmd+j=close_surface
        """)
        #expect(config.keyboardShortcut(for: "new_window") == .init("d", modifiers: .command))
        #expect(config.keyboardShortcut(for: "new_split:right") == nil)
        #expect(config.keyboardShortcut(for: "close_surface") == .init("j", modifiers: .command))
        #expect(config.keyboardShortcut(for: "new_tab") == nil)
    }

    @Test func keybindClearDropsEveryDefault() throws {
        let config = try TemporaryConfig("""
        keybind = clear
        keybind = cmd+n=new_tab
        """)
        #expect(config.keyboardShortcut(for: "new_window") == nil)
        #expect(config.keyboardShortcut(for: "copy_to_clipboard") == nil)
        #expect(config.keyboardShortcut(for: "new_tab") == .init("n", modifiers: .command))
    }

    @Test func keybindLineWithoutEqualsIsIgnored() throws {
        let config = try TemporaryConfig("keybind=not-a-valid-trigger")
        #expect(config.keyboardShortcut(for: "not-a-valid-trigger") == nil)
    }

    @Test func unknownActionHasNoDefaultShortcut() throws {
        let config = try TemporaryConfig("")
        #expect(config.keyboardShortcut(for: "totally_unknown_action") == nil)
    }
}

@Suite
struct ConfigNestedTypesCoverageTests {
    @Test func backgroundBlurFromCValueZeroIsDisabled() {
        let blur = Tako.Config.BackgroundBlur(fromCValue: 0)
        #expect(blur == .disabled)
        #expect(!blur.isEnabled)
        #expect(!blur.isGlassStyle)
        #expect(blur.radius == nil)
    }

    @Test func backgroundBlurFromCValuePositiveIsRadius() {
        let blur = Tako.Config.BackgroundBlur(fromCValue: 12)
        #expect(blur == .radius(12))
        #expect(blur.isEnabled)
        #expect(!blur.isGlassStyle)
        #expect(blur.radius == 12)
    }

    @Test func backgroundBlurGlassVariantsAreEnabledButHaveNoRadius() {
        let regular = Tako.Config.BackgroundBlur(fromCValue: -1)
        let clear = Tako.Config.BackgroundBlur(fromCValue: -2)
        for blur in [regular, clear] {
            if #available(macOS 26.0, *) {
                #expect(blur.isEnabled)
                #expect(blur.isGlassStyle)
            } else {
                // Glass needs macOS 26; older systems get no blur at all.
                #expect(blur == .disabled)
            }
            #expect(blur.radius == nil)
        }
    }

    @Test func windowDecorationEnabled() {
        #expect(!Tako.Config.WindowDecoration.none.enabled())
        #expect(Tako.Config.WindowDecoration.client.enabled())
        #expect(Tako.Config.WindowDecoration.server.enabled())
        #expect(Tako.Config.WindowDecoration.auto.enabled())
    }

    @Test func defaultTitlebarStyleConstant() {
        #expect(Tako.Config.MacOSTitlebarStyle.default == .transparent)
    }

    @Test func commandPaletteEntryIsSupportedByDefault() {
        let entry = Tako.Command(
            title: "Copy", description: "", action: "copy_to_clipboard", actionKey: "copy_to_clipboard")
        #expect(entry.isSupported)
    }

    @Test func commandPaletteEntryForAnActionThePortCannotDoIsUnsupported() {
        let entry = Tako.Command(title: "Inspector", action: "inspector:toggle", actionKey: "inspector")
        #expect(!entry.isSupported)
    }

    @Test func commandPaletteEntryUnsupportedActionKeys() {
        let entry = Tako.Command(actionKey: "toggle_tab_overview")
        #expect(!entry.isSupported)
    }

    @Test func configPathHoldsPathAndOptionalFlag() {
        let path = Tako.ConfigPath(path: "/tmp/x", optional: true)
        #expect(path.path == "/tmp/x")
        #expect(path.optional)
    }

    @Test func macosIconAssetNameIsNilForBothVariants() {
        #expect(Tako.MacOSIcon.official.assetName == nil)
        #expect(Tako.MacOSIcon.custom.assetName == nil)
    }
}

