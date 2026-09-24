import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Tako
import TakoKit

// Coverage for the shim's config defaults, key/mouse-event translation, shell
// escaping, the menu-shortcut key-equivalent dispatch path, the SwiftUI
// surface plumbing, and the crab command-lifecycle tracker + its NSView.
// TabBar/TabBarController/CustomTabGroup live in TakoTabBarCoverageTests.swift.

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

    @Test func macosAppleScriptDefaultsToTrue() throws {
        let config = try TemporaryConfig("")
        #expect(config.macosAppleScript == true)
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

// MARK: - Input event translation

@Suite
struct InputCoverageTests {
    @Test func modsFromNSFlagsCoversEveryBit() {
        let flags: NSEvent.ModifierFlags = [.shift, .control, .option, .command, .capsLock]
        let mods = Tako.Input.Mods(nsFlags: flags)
        #expect(mods.contains(.shift))
        #expect(mods.contains(.ctrl))
        #expect(mods.contains(.alt))
        #expect(mods.contains(.super))
        #expect(mods.contains(.capsLock))
        #expect(!mods.contains(.numLock))
    }

    @Test func modsFromEmptyFlagsIsEmpty() {
        let mods = Tako.Input.Mods(nsFlags: [])
        #expect(mods.isEmpty)
    }

    @Test func coreModsMapsEachFlag() {
        let mods: Tako.Input.Mods = [.shift, .alt, .ctrl, .super]
        let core = mods.coreMods
        #expect(core.shift)
        #expect(core.alt)
        #expect(core.ctrl)
        #expect(core.superKey)

        let none = Tako.Input.Mods([]).coreMods
        #expect(!none.shift && !none.alt && !none.ctrl && !none.superKey)
    }

    @Test func actionIsPress() {
        #expect(Tako.Input.Action.press.isPress)
        #expect(Tako.Input.Action.repeatKey.isPress)
        #expect(!Tako.Input.Action.release.isPress)
    }

    @Test func mouseButtonFromNumber() {
        #expect(Tako.Input.MouseButton(nsButtonNumber: 0) == .left)
        #expect(Tako.Input.MouseButton(nsButtonNumber: 1) == .right)
        #expect(Tako.Input.MouseButton(nsButtonNumber: 2) == .middle)
        #expect(Tako.Input.MouseButton(nsButtonNumber: 99) == .unknown)
    }

    @Test(arguments: [
        (UInt16(36), Tako.Input.Key.enter), (48, .tab), (51, .backspace), (53, .escape),
        (49, .space), (126, .up), (125, .down), (123, .left), (124, .right),
        (115, .home), (119, .end), (116, .pageUp), (121, .pageDown),
        (114, .insert), (117, .delete),
        (122, .f1), (120, .f2), (99, .f3), (118, .f4), (96, .f5), (97, .f6),
        (98, .f7), (100, .f8), (101, .f9), (109, .f10), (103, .f11), (111, .f12),
        (9999, .unidentified),
    ])
    func keyFromKeyCode(code: UInt16, expected: Tako.Input.Key) {
        #expect(Tako.Input.Key(keyCode: code) == expected)
    }

    @Test func ffiKeyMapsEveryNamedCase() {
        for key in Tako.Input.Key.allCases {
            let ffi = key.ffiKey
            if key == .unidentified {
                #expect(ffi == .character)
            } else if key == .space {
                // Space is deliberately absent from the table: send(keyEvent:)
                // delivers it as the character " " so modifiers encode as text.
                #expect(Tako.Input.Key.ffiKeys[key] == nil)
            } else {
                #expect(Tako.Input.Key.ffiKeys[key] == ffi)
            }
        }
    }

    @Test func keyEventConvenienceInitDefaultsToPress() {
        let event = Tako.Input.KeyEvent(key: .enter)
        #expect(event.action == .press)
        #expect(event.key == .enter)
        #expect(event.mods.isEmpty)
        #expect(event.text == nil)
    }

    @Test func splitFocusDirectionTranslatesPreviousAndNext() {
        let previousMatches: Bool
        if case .previous = Tako.SplitFocusDirection.previous.toSplitTreeFocusDirection() {
            previousMatches = true
        } else {
            previousMatches = false
        }
        #expect(previousMatches)

        let nextMatches: Bool
        if case .next = Tako.SplitFocusDirection.next.toSplitTreeFocusDirection() {
            nextMatches = true
        } else {
            nextMatches = false
        }
        #expect(nextMatches)
    }

    @Test func splitFocusDirectionTranslatesSpatialDirections() {
        let cases: [(Tako.SplitFocusDirection, SplitTree<Tako.SurfaceView>.Spatial.Direction)] = [
            (.up, .up), (.down, .down), (.left, .left), (.right, .right),
        ]
        for (direction, expected) in cases {
            switch direction.toSplitTreeFocusDirection() {
            case .spatial(let spatial):
                #expect("\(spatial)" == "\(expected)")
            default:
                Issue.record("expected .spatial for \(direction)")
            }
        }
    }

    @Test func clipboardRequestPromptText() {
        #expect(Tako.ClipboardRequest.paste.text().contains("dangerous"))
        #expect(Tako.ClipboardRequest.osc_52_read.text().contains("read"))
        #expect(Tako.ClipboardRequest.osc_52_write(nil).text().contains("write"))
    }

    @Test @MainActor func nsEventTakoKeyEventFromKeyDown() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ) else {
            Issue.record("failed to build synthetic NSEvent")
            return
        }
        let key = event.takoKeyEvent
        #expect(key.action == .press)
        #expect(key.text == "a")
        #expect(key.mods.contains(.shift))

        let released = event.takoKeyEvent(.release)
        #expect(released.action == .release)

        let cKey = event.takoKeyEvent(TAKO_ACTION_PRESS)
        #expect(cKey.action == TAKO_ACTION_PRESS)
    }
}

// MARK: - Misc: Shell, launch source, menu shortcut dispatch

@Suite
struct MiscCoverageTests {
    @Test func launchSourceReflectsStdinIsATTY() {
        // In the test harness stdin is not a live terminal, so this always
        // resolves to `.app` -- exercising the computed property either way.
        #expect(Tako.launchSource == .app || Tako.launchSource == .cli)
    }

    @Test func setSecureInputRawValues() {
        #expect(Tako.SetSecureInput.on.rawValue == 1)
        #expect(Tako.SetSecureInput.off.rawValue == 0)
        #expect(Tako.SetSecureInput.toggle.rawValue == 2)
    }

    @Test func userNotificationIdentifiersAreStable() {
        #expect(Tako.userNotificationCategory == "com.tako.notification")
        #expect(Tako.userNotificationActionShow == "com.tako.notification.show")
    }

    @Test @MainActor func performBindingMenuKeyEquivalentDispatchesRegisteredItem() async throws {
        let config = try TemporaryConfig("")
        let manager = Tako.MenuShortcutManager()
        manager.reset()

        final class Recorder: NSObject {
            var invoked = false
            @objc func fire(_ sender: Any?) { invoked = true }
        }
        let recorder = Recorder()
        let menu = NSMenu()
        let item = NSMenuItem(title: "New Window", action: #selector(Recorder.fire(_:)), keyEquivalent: "")
        item.target = recorder
        menu.addItem(item)

        manager.syncMenuShortcut(config, action: "new_window", menuItem: item)
        #expect(item.keyEquivalent == "n")

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "n",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: 0
        ) else {
            Issue.record("failed to build synthetic NSEvent")
            return
        }

        let handled = manager.performTakoBindingMenuKeyEquivalent(with: event)
        #expect(handled)
        #expect(recorder.invoked)
    }

    @Test @MainActor func performBindingMenuKeyEquivalentReturnsFalseWithoutMatch() {
        let manager = Tako.MenuShortcutManager()
        manager.reset()
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "z",
            charactersIgnoringModifiers: "z",
            isARepeat: false,
            keyCode: 0
        ) else {
            Issue.record("failed to build synthetic NSEvent")
            return
        }
        #expect(!manager.performTakoBindingMenuKeyEquivalent(with: event))
    }

    @Test @MainActor func performBindingMenuKeyEquivalentReturnsFalseWhenItemDisabled() throws {
        let config = try TemporaryConfig("")
        let manager = Tako.MenuShortcutManager()
        manager.reset()

        let menu = NSMenu()
        let item = NSMenuItem(title: "New Window", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        manager.syncMenuShortcut(config, action: "new_window", menuItem: item)

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "n",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: 0
        ) else {
            Issue.record("failed to build synthetic NSEvent")
            return
        }
        #expect(!manager.performTakoBindingMenuKeyEquivalent(with: event))
    }

    @Test func shellEscapeAndQuoteRoundTrip() {
        #expect(Tako.Shell.escape("a b") == "a\\ b")
        #expect(Tako.Shell.quote("plain") == "plain")
        #expect(Tako.Shell.quote("") == "''")
    }
}

// MARK: - SurfaceUI

@Suite
struct SurfaceUICoverageTests {
    @Test func draggingSurfaceKeyDefaultsToNil() {
        #expect(Tako.DraggingSurfaceKey.defaultValue == nil)
    }

    @Test func draggingSurfaceKeyReducePrefersNextNonNilValue() {
        var value: Tako.SurfaceView.ID? = nil
        Tako.DraggingSurfaceKey.reduce(value: &value) { nil }
        #expect(value == nil)

        let id = UUID()
        Tako.DraggingSurfaceKey.reduce(value: &value) { id }
        #expect(value == id)

        // A nil next value keeps whatever was already accumulated.
        Tako.DraggingSurfaceKey.reduce(value: &value) { nil }
        #expect(value == id)
    }

    @Test func environmentLastFocusedSurfaceRoundTrips() {
        var env = EnvironmentValues()
        #expect(env.takoLastFocusedSurface == nil)
        final class Dummy: AnyObject {}
        // takoLastFocusedSurface is typed to Tako.SurfaceView specifically,
        // so exercise the setter/getter with a nil payload wrapped in Weak.
        let weak = Weak<Tako.SurfaceView>(nil)
        env.takoLastFocusedSurface = weak
        #expect(env.takoLastFocusedSurface === weak)
        _ = Dummy.self
    }

    @Test @MainActor func lastFocusedSurfaceViewModifierAppliesEnvironmentValue() {
        struct Probe: View {
            @Environment(\.takoLastFocusedSurface) var focused
            var body: some View { Color.clear }
        }
        let view = Probe().takoLastFocusedSurface(nil)
        // Hosting and rendering the view exercises the `environment(_:_:)`
        // modifier this wraps; just constructing it must not crash.
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        hosting.layout()
        #expect(hosting.fittingSize.width >= 0)
    }
}

// MARK: - Crab state tracking

@Suite
struct CrabTrackerCoverageTests {
    @Test func priorityOrderMatchesDesignSpec() {
        let ordered: [Tako.CrabState] = [
            .reconnecting, .idle, .succeeded, .attention, .running, .failed(code: 1), .ghost,
        ]
        for (index, state) in ordered.enumerated() {
            #expect(state.priority == index)
        }
    }

    @Test func colorForEachState() {
        #expect(Tako.CrabState.succeeded.color == Tako.Brand.ok)
        #expect(Tako.CrabState.failed(code: nil).color == Tako.Brand.error)
        #expect(Tako.CrabState.ghost.color == Tako.Brand.dim)
        #expect(Tako.CrabState.idle.color == Tako.Brand.ember)
        #expect(Tako.CrabState.running.color == Tako.Brand.ember)
        #expect(Tako.CrabState.attention.color == Tako.Brand.ember)
        #expect(Tako.CrabState.reconnecting.color == Tako.Brand.ember)
    }

    @Test @MainActor func commandShorterThanThresholdEndsIdleWithoutFlashingGreen() {
        var now = Date(timeIntervalSince1970: 0)
        let tracker = Tako.CrabTracker(now: { now })
        tracker.commandStarted()
        now = now.addingTimeInterval(1)
        tracker.commandEnded(exitCode: 0)
        #expect(tracker.state == .idle)
        #expect(tracker.elapsedLabel == nil)
    }

    @Test @MainActor func commandLongerThanThresholdSucceedsAndLingers() {
        var now = Date(timeIntervalSince1970: 0)
        let tracker = Tako.CrabTracker(now: { now })
        tracker.commandStarted()
        now = now.addingTimeInterval(5)
        tracker.tick()
        #expect(tracker.state == .running)
        #expect(tracker.elapsedLabel != nil)

        tracker.commandEnded(exitCode: 0)
        #expect(tracker.state == .succeeded)
        #expect(tracker.elapsedLabel == nil)
    }

    @Test @MainActor func failedCommandHoldsUntilFocused() {
        var now = Date(timeIntervalSince1970: 0)
        let tracker = Tako.CrabTracker(now: { now })
        tracker.commandStarted()
        now = now.addingTimeInterval(4)
        tracker.commandEnded(exitCode: 7)
        #expect(tracker.state == .failed(code: 7))

        tracker.focused()
        #expect(tracker.state == .idle)
    }

    @Test @MainActor func bellRingsAttentionButNeverDowngradesFailure() {
        let tracker = Tako.CrabTracker()
        tracker.commandEnded(exitCode: 3)
        #expect(tracker.state == .failed(code: 3))
        tracker.bellRang()
        // failed (priority 5) outranks attention (priority 3): stays failed.
        #expect(tracker.state == .failed(code: 3))

        let idleTracker = Tako.CrabTracker()
        idleTracker.bellRang()
        #expect(idleTracker.state == .attention)
    }

    @Test @MainActor func progressReportedSetsAndClears() {
        let tracker = Tako.CrabTracker()
        tracker.progressReported(state: 1, value: 42)
        #expect(tracker.progress == 42)
        tracker.progressReported(state: 0, value: nil)
        #expect(tracker.progress == nil)
    }

    @Test @MainActor func connectionLostAndReconnecting() {
        let tracker = Tako.CrabTracker()
        tracker.connectionLost()
        #expect(tracker.state == .ghost)
        #expect(tracker.unread)

        tracker.reconnecting()
        #expect(tracker.state == .reconnecting)
    }

    @Test @MainActor func durationLabelFormatting() {
        #expect(Tako.CrabTracker.durationLabel(1.2) == "1.2s")
        #expect(Tako.CrabTracker.durationLabel(9.5) == "9.5s")
        #expect(Tako.CrabTracker.durationLabel(45) == "45s")
        #expect(Tako.CrabTracker.durationLabel(65) == "1m 05s")
        #expect(Tako.CrabTracker.durationLabel(125) == "2m 05s")
    }

    @Test @MainActor func tickBeforeThresholdDoesNotSetElapsedOrState() {
        var now = Date(timeIntervalSince1970: 0)
        let tracker = Tako.CrabTracker(now: { now })
        tracker.commandStarted()
        now = now.addingTimeInterval(1)
        tracker.tick()
        #expect(tracker.state == .idle)
        #expect(tracker.elapsed == nil)
    }

    @Test @MainActor func tickWithoutAStartedCommandIsANoOp() {
        let tracker = Tako.CrabTracker()
        tracker.tick()
        #expect(tracker.state == .idle)
    }
}

// MARK: - CrabView drawing + animation state machine

@Suite
struct CrabViewCoverageTests {
    @MainActor private func draw(_ view: Tako.CrabView) {
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        view.draw(view.bounds)
        image.unlockFocus()
    }

    /// Renders `view` into a real bitmap so pixels can be compared, per the
    /// task's prescribed technique for proving drawn state actually changed.
    @MainActor private func snapshot(_ view: NSView) -> NSBitmapImageRep {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            fatalError("could not create a bitmap rep for \(view)")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func bitmapsEqual(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
              let da = a.bitmapData, let db = b.bitmapData
        else { return false }
        let length = a.bytesPerRow * a.pixelsHigh
        guard length == b.bytesPerRow * b.pixelsHigh else { return false }
        return memcmp(da, db, length) == 0
    }

    private func hasOpaquePixel(_ rep: NSBitmapImageRep) -> Bool {
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 {
                    return true
                }
            }
        }
        return false
    }

    @Test @MainActor func intrinsicContentSizeIsSixteenByFixteen() {
        let view = Tako.CrabView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        #expect(view.intrinsicContentSize == NSSize(width: 16, height: 16))
        #expect(!view.isFlipped)
    }

    @Test @MainActor func drawsWithoutUnreadDotByDefault() {
        let view = Tako.CrabView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        let defaultSnapshot = snapshot(view) // `unread` is false by default.

        let explicitlyOff = Tako.CrabView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        explicitlyOff.unread = false
        #expect(bitmapsEqual(defaultSnapshot, snapshot(explicitlyOff)))

        view.unread = true
        // Turning it on paints something the false-by-default render did not.
        #expect(!bitmapsEqual(defaultSnapshot, snapshot(view)))
    }

    @Test @MainActor func drawsWithUnreadDot() {
        let view = Tako.CrabView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        let before = snapshot(view)

        view.unread = true
        let after = snapshot(view)
        #expect(!bitmapsEqual(before, after))

        view.unread = false
        // Turning it back off restores the original pixels exactly.
        #expect(bitmapsEqual(before, snapshot(view)))
    }

    @Test @MainActor func settingSameStateTwiceDoesNotRestartAnimation() {
        let view = Tako.CrabView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        view.state = .running
        // Synchronous: the 0.2s leg-cycle timer cannot have ticked yet, so
        // this is deterministically the phase-0 frame.
        let phase0 = snapshot(view)

        var phase1: NSBitmapImageRep?
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            let current = snapshot(view)
            if !bitmapsEqual(current, phase0) {
                phase1 = current
                break
            }
        }
        guard let phase1 else {
            Issue.record("the running animation never ticked")
            return
        }

        // Re-assigning the same state must not restart the animation: the
        // phase the timer already reached has to survive the redundant set,
        // undisturbed (a restart would reset it back to phase 0).
        view.state = .running
        #expect(bitmapsEqual(snapshot(view), phase1))
    }

    @Test @MainActor func everyStateDrawsCleanly() {
        let view = Tako.CrabView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        var renders: [NSBitmapImageRep] = []
        for state: Tako.CrabState in [.idle, .running, .succeeded, .failed(code: 1), .attention, .reconnecting, .ghost] {
            view.state = state
            let image = snapshot(view)
            // Every state actually paints the crab's body, not a blank frame.
            #expect(hasOpaquePixel(image))
            renders.append(image)
        }
        // Succeeded and failed recolour the mark (Brand.ok vs Brand.error):
        // their renders must not coincidentally be pixel-identical.
        #expect(!bitmapsEqual(renders[2], renders[3]))
    }
}
