/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Testing
@testable import Tako
import SwiftUI
import AppKit

/// Config keys `Tako.Config` parses but a property used to ignore, wired up
/// to actually read them. See `Tako+Config.swift`.
@Suite
struct ConfigKeysTests {
    // MARK: - quick-terminal-position

    @Test func quickTerminalPositionDefaultsToTop() throws {
        let config = try TemporaryConfig("")
        #expect(config.quickTerminalPosition == .top)
    }

    @Test(arguments: [
        ("top", QuickTerminalPosition.top),
        ("bottom", QuickTerminalPosition.bottom),
        ("left", QuickTerminalPosition.left),
        ("right", QuickTerminalPosition.right),
        ("center", QuickTerminalPosition.center),
    ])
    func quickTerminalPositionValues(raw: String, expected: QuickTerminalPosition) throws {
        let config = try TemporaryConfig("quick-terminal-position = \(raw)")
        #expect(config.quickTerminalPosition == expected)
    }

    @Test func quickTerminalPositionInvalidFallsBackToTop() throws {
        let config = try TemporaryConfig("quick-terminal-position = sideways")
        #expect(config.quickTerminalPosition == .top)
    }

    // MARK: - quick-terminal-screen

    @Test func quickTerminalScreenDefaultsToMain() throws {
        let config = try TemporaryConfig("")
        #expect(config.quickTerminalScreen == .main)
    }

    @Test(arguments: [
        ("main", QuickTerminalScreen.main),
        ("mouse", QuickTerminalScreen.mouse),
        ("macos-menu-bar", QuickTerminalScreen.menuBar),
    ])
    func quickTerminalScreenValues(raw: String, expected: QuickTerminalScreen) throws {
        let config = try TemporaryConfig("quick-terminal-screen = \(raw)")
        #expect(config.quickTerminalScreen == expected)
    }

    @Test func quickTerminalScreenInvalidFallsBackToMain() throws {
        let config = try TemporaryConfig("quick-terminal-screen = elsewhere")
        #expect(config.quickTerminalScreen == .main)
    }

    // MARK: - quick-terminal-animation-duration

    @Test func quickTerminalAnimationDurationDefaultsToPointTwo() throws {
        let config = try TemporaryConfig("")
        #expect(config.quickTerminalAnimationDuration == 0.2)
    }

    @Test func quickTerminalAnimationDurationSetToCustom() throws {
        let config = try TemporaryConfig("quick-terminal-animation-duration = 0.5")
        #expect(config.quickTerminalAnimationDuration == 0.5)
    }

    @Test func quickTerminalAnimationDurationInvalidFallsBackToDefault() throws {
        let config = try TemporaryConfig("quick-terminal-animation-duration = fast")
        #expect(config.quickTerminalAnimationDuration == 0.2)
    }

    // MARK: - quick-terminal-autohide

    @Test func quickTerminalAutoHideDefaultsToTrue() throws {
        let config = try TemporaryConfig("")
        #expect(config.quickTerminalAutoHide == true)
    }

    @Test func quickTerminalAutoHideSetToFalse() throws {
        let config = try TemporaryConfig("quick-terminal-autohide = false")
        #expect(config.quickTerminalAutoHide == false)
    }

    @Test func quickTerminalAutoHideInvalidFallsBackToDefault() throws {
        let config = try TemporaryConfig("quick-terminal-autohide = maybe")
        #expect(config.quickTerminalAutoHide == true)
    }

    // MARK: - quick-terminal-space-behavior

    @Test func quickTerminalSpaceBehaviorDefaultsToMove() throws {
        let config = try TemporaryConfig("")
        #expect(config.quickTerminalSpaceBehavior == .move)
    }

    @Test(arguments: [
        ("move", QuickTerminalSpaceBehavior.move),
        ("remain", QuickTerminalSpaceBehavior.remain),
    ])
    func quickTerminalSpaceBehaviorValues(raw: String, expected: QuickTerminalSpaceBehavior) throws {
        let config = try TemporaryConfig("quick-terminal-space-behavior = \(raw)")
        #expect(config.quickTerminalSpaceBehavior == expected)
    }

    @Test func quickTerminalSpaceBehaviorInvalidFallsBackToMove() throws {
        let config = try TemporaryConfig("quick-terminal-space-behavior = teleport")
        #expect(config.quickTerminalSpaceBehavior == .move)
    }

    // MARK: - unfocused-split-opacity

    @Test func unfocusedSplitOpacityDefaultsToFifteenPercentDimming() throws {
        let config = try TemporaryConfig("")
        #expect(config.unfocusedSplitOpacity == 0.15)
    }

    @Test func unfocusedSplitOpacitySetToCustom() throws {
        let config = try TemporaryConfig("unfocused-split-opacity = 0.5")
        #expect(config.unfocusedSplitOpacity == 0.5)
    }

    @Test func unfocusedSplitOpacityClampsBelowFloor() throws {
        let config = try TemporaryConfig("unfocused-split-opacity = 0")
        #expect(config.unfocusedSplitOpacity == 0.85)
    }

    @Test func unfocusedSplitOpacityClampsAboveCeiling() throws {
        let config = try TemporaryConfig("unfocused-split-opacity = 2")
        #expect(config.unfocusedSplitOpacity == 0)
    }

    @Test func unfocusedSplitOpacityInvalidFallsBackToDefault() throws {
        let config = try TemporaryConfig("unfocused-split-opacity = translucent")
        #expect(config.unfocusedSplitOpacity == 0.15)
    }

    // MARK: - unfocused-split-fill

    @Test func unfocusedSplitFillDefaultsToWhite() throws {
        let config = try TemporaryConfig("")
        #expect(config.unfocusedSplitFill == .white)
    }

    @Test func unfocusedSplitFillSetToColor() throws {
        let config = try TemporaryConfig("unfocused-split-fill = #ff0000")
        let expected = try #require(TerminalTheme.parseColor("#ff0000"))
        #expect(config.unfocusedSplitFill == Color(NSColor(cgColor: expected) ?? .windowBackgroundColor))
        #expect(config.unfocusedSplitFill != .white)
    }

    @Test func unfocusedSplitFillInvalidFallsBackToWhite() throws {
        let config = try TemporaryConfig("unfocused-split-fill = not-a-color")
        #expect(config.unfocusedSplitFill == .white)
    }

    // MARK: - window-new-tab-position

    @Test func windowNewTabPositionDefaultsToEmpty() throws {
        let config = try TemporaryConfig("")
        #expect(config.windowNewTabPosition == "")
    }

    @Test func windowNewTabPositionSetToEnd() throws {
        let config = try TemporaryConfig("window-new-tab-position = end")
        #expect(config.windowNewTabPosition == "end")
    }

    @Test func windowNewTabPositionSetToCurrent() throws {
        let config = try TemporaryConfig("window-new-tab-position = current")
        #expect(config.windowNewTabPosition == "current")
    }

    @Test func windowNewTabPositionInvalidFallsBackToEmpty() throws {
        let config = try TemporaryConfig("window-new-tab-position = elsewhere")
        #expect(config.windowNewTabPosition == "")
    }

    // MARK: - macos-titlebar-proxy-icon

    @Test func macosTitlebarProxyIconDefaultsToVisible() throws {
        let config = try TemporaryConfig("")
        #expect(config.macosTitlebarProxyIcon == .visible)
    }

    @Test(arguments: [
        ("visible", Tako.MacOSTitlebarProxyIcon.visible),
        ("hidden", Tako.MacOSTitlebarProxyIcon.hidden),
    ])
    func macosTitlebarProxyIconValues(raw: String, expected: Tako.MacOSTitlebarProxyIcon) throws {
        let config = try TemporaryConfig("macos-titlebar-proxy-icon = \(raw)")
        #expect(config.macosTitlebarProxyIcon == expected)
    }

    @Test func macosTitlebarProxyIconInvalidFallsBackToVisible() throws {
        let config = try TemporaryConfig("macos-titlebar-proxy-icon = translucent")
        #expect(config.macosTitlebarProxyIcon == .visible)
    }

    // MARK: - macos-auto-secure-input

    @Test func autoSecureInputDefaultsToTrue() throws {
        let config = try TemporaryConfig("")
        #expect(config.autoSecureInput == true)
    }

    @Test func autoSecureInputSetToFalse() throws {
        let config = try TemporaryConfig("macos-auto-secure-input = false")
        #expect(config.autoSecureInput == false)
    }

    @Test func autoSecureInputInvalidFallsBackToDefault() throws {
        let config = try TemporaryConfig("macos-auto-secure-input = nope")
        #expect(config.autoSecureInput == true)
    }

    // MARK: - macos-secure-input-indication

    @Test func secureInputIndicationDefaultsToTrue() throws {
        let config = try TemporaryConfig("")
        #expect(config.secureInputIndication == true)
    }

    @Test func secureInputIndicationSetToFalse() throws {
        let config = try TemporaryConfig("macos-secure-input-indication = false")
        #expect(config.secureInputIndication == false)
    }

    @Test func secureInputIndicationInvalidFallsBackToDefault() throws {
        let config = try TemporaryConfig("macos-secure-input-indication = nope")
        #expect(config.secureInputIndication == true)
    }


}
