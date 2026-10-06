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
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TakoKit
@testable import Tako

// MARK: EventModifiers+Extension

@MainActor
struct EventModifiersExtensionTests {
    @Test func nsFlagsMapToSwiftUIModifiers() {
        let flags: NSEvent.ModifierFlags = [.shift, .control, .option, .command, .capsLock]
        let modifiers = EventModifiers(nsFlags: flags)
        #expect(modifiers.contains(.shift))
        #expect(modifiers.contains(.control))
        #expect(modifiers.contains(.option))
        #expect(modifiers.contains(.command))
        #expect(modifiers.contains(.capsLock))
    }

    @Test func nsFlagsMapEmptySet() {
        let modifiers = EventModifiers(nsFlags: [])
        #expect(modifiers.isEmpty)
    }

    @Test func swiftUIModifiersMapToNSFlags() {
        let flags = NSEvent.ModifierFlags(swiftUIFlags: [.shift, .control, .option, .command, .capsLock])
        #expect(flags.contains(.shift))
        #expect(flags.contains(.control))
        #expect(flags.contains(.option))
        #expect(flags.contains(.command))
        #expect(flags.contains(.capsLock))
    }

    @Test func swiftUIModifiersMapEmptySet() {
        let flags = NSEvent.ModifierFlags(swiftUIFlags: [])
        #expect(flags.isEmpty)
    }
}

// MARK: KeyboardShortcut+Extension

@MainActor
struct KeyboardShortcutExtensionTests {
    @Test func keyListIncludesAllModifierGlyphsInOrder() {
        let shortcut = KeyboardShortcut("a", modifiers: [.control, .option, .shift, .command])
        #expect(shortcut.keyList == ["⌃", "⌥", "⇧", "⌘", "A"])
    }

    @Test func keyListWithNoModifiersOnlyHasKey() {
        let shortcut = KeyboardShortcut("x", modifiers: [])
        #expect(shortcut.keyList == ["X"])
    }

    @Test func specialKeysRenderAsGlyphs() {
        #expect(KeyboardShortcut(.return, modifiers: []).keyList == ["⏎"])
        #expect(KeyboardShortcut(.escape, modifiers: []).keyList == ["⎋"])
        #expect(KeyboardShortcut(.delete, modifiers: []).keyList == ["⌫"])
        #expect(KeyboardShortcut(.deleteForward, modifiers: []).keyList == ["⌦"])
        #expect(KeyboardShortcut(.space, modifiers: []).keyList == ["␣"])
        #expect(KeyboardShortcut(.tab, modifiers: []).keyList == ["⇥"])
        #expect(KeyboardShortcut(.upArrow, modifiers: []).keyList == ["▲"])
        #expect(KeyboardShortcut(.downArrow, modifiers: []).keyList == ["▼"])
        #expect(KeyboardShortcut(.leftArrow, modifiers: []).keyList == ["◀"])
        #expect(KeyboardShortcut(.rightArrow, modifiers: []).keyList == ["▶"])
        #expect(KeyboardShortcut(.pageUp, modifiers: []).keyList == ["↑"])
        #expect(KeyboardShortcut(.pageDown, modifiers: []).keyList == ["↓"])
        #expect(KeyboardShortcut(.home, modifiers: []).keyList == ["⤒"])
        #expect(KeyboardShortcut(.end, modifiers: []).keyList == ["⤓"])
    }

    @Test func descriptionJoinsKeyListWithoutSeparator() {
        let shortcut = KeyboardShortcut("c", modifiers: .command)
        #expect(shortcut.description == "⌘C")
    }

    @Test func keyEquivalentEqualityComparesCharacter() {
        // KeyEquivalent already exposes an unrelated `==` overload from
        // SwiftUI itself, so calling the operator directly at this call site
        // is ambiguous; routing through a generic Equatable requirement
        // forces dispatch through this extension's actual conformance witness.
        func equatable<T: Equatable>(_ a: T, _ b: T) -> Bool { a == b }
        #expect(equatable(KeyEquivalent("a"), KeyEquivalent("a")))
        #expect(!equatable(KeyEquivalent("a"), KeyEquivalent("b")))
    }
}

// MARK: NSAppearance+Extension

@MainActor
struct NSAppearanceExtensionTests {
    private final class MockConfig: Tako.Config {
        let themeOverride: String?
        init(theme: String?) {
            self.themeOverride = theme
            super.init(config: nil)
        }
        override var windowTheme: String? { themeOverride }
    }

    @Test func isDarkDetectsDarkAquaByName() {
        let appearance = NSAppearance(named: .darkAqua)
        #expect(appearance?.isDark == true)
    }

    @Test func isDarkIsFalseForLightAppearance() {
        let appearance = NSAppearance(named: .aqua)
        #expect(appearance?.isDark == false)
    }

    @Test func takoConfigInitReturnsNilWithoutTheme() {
        let config = MockConfig(theme: nil)
        #expect(NSAppearance(takoConfig: config) == nil)
    }

    @Test func takoConfigInitReturnsDarkAquaForDarkTheme() {
        let config = MockConfig(theme: "dark")
        let appearance = NSAppearance(takoConfig: config)
        #expect(appearance?.name == .darkAqua)
    }

    @Test func takoConfigInitReturnsAquaForLightTheme() {
        let config = MockConfig(theme: "light")
        let appearance = NSAppearance(takoConfig: config)
        #expect(appearance?.name == .aqua)
    }

    @Test func takoConfigInitReturnsNilForUnknownTheme() {
        let config = MockConfig(theme: "sepia")
        #expect(NSAppearance(takoConfig: config) == nil)
    }

    @Test func takoConfigInitResolvesAutoUsingBackgroundLuminance() {
        let config = MockConfig(theme: "auto")
        let appearance = NSAppearance(takoConfig: config)
        // The default shim background resolves to a concrete NSColor either
        // way; whichever branch runs, we get a definitive aqua/darkAqua result.
        #expect(appearance?.name == .aqua || appearance?.name == .darkAqua)
    }
}

// MARK: NSApplication+Extension

@MainActor
struct NSApplicationExtensionTests {
    @Test func acquireAndReleasePresentationOptionReferenceCounts() {
        let app = NSApplication.shared
        let before = app.presentationOptions.contains(.autoHideDock)

        app.acquirePresentationOption(.autoHideDock)
        app.acquirePresentationOption(.autoHideDock)
        #expect(app.presentationOptions.contains(.autoHideDock))

        // First release should not remove it yet (count is 2 -> 1).
        app.releasePresentationOption(.autoHideDock)
        #expect(app.presentationOptions.contains(.autoHideDock))

        // Second release drops the count to zero and clears the option.
        app.releasePresentationOption(.autoHideDock)
        #expect(app.presentationOptions.contains(.autoHideDock) == before)
    }

    @Test func releaseWithoutAcquireIsNoOp() {
        let app = NSApplication.shared
        let before = app.presentationOptions.contains(.hideDock)
        app.releasePresentationOption(.hideDock)
        #expect(app.presentationOptions.contains(.hideDock) == before)
    }

    @Test func presentationOptionsElementIsHashable() {
        var set: Set<NSApplication.PresentationOptions.Element> = []
        set.insert(.autoHideMenuBar)
        set.insert(.autoHideMenuBar)
        #expect(set.count == 1)
    }

    @Test func isFrontmostReflectsBundleIdentifierComparison() {
        // In the `swift test` host process this app is not the frontmost
        // application, so this should reliably read false.
        #expect(NSApplication.shared.isFrontmost == (NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier))
    }
}

// MARK: NSColor+Extension

@MainActor
struct NSColorExtensionTests {
    @Test func adjustingSaturationChangesSaturationComponent() {
        let color = NSColor(hue: 0.5, saturation: 0.5, brightness: 0.5, alpha: 1)
        let adjusted = color.adjustingSaturation(by: 0.5)
        var s: CGFloat = 0
        adjusted.usingColorSpace(.sRGB)?.getHue(nil, saturation: &s, brightness: nil, alpha: nil)
        #expect(s < 0.5)
    }

    @Test func adjustingSaturationClampsToUnitRange() {
        let color = NSColor(hue: 0.5, saturation: 0.5, brightness: 0.5, alpha: 1)
        let boosted = color.adjustingSaturation(by: 10)
        var s: CGFloat = 0
        boosted.usingColorSpace(.sRGB)?.getHue(nil, saturation: &s, brightness: nil, alpha: nil)
        #expect(s == 1)
    }

    @Test func distanceToSelfIsZero() {
        let color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        #expect(color.distance(to: color) == 0)
    }

    @Test func distanceToDifferentColorIsPositive() {
        let a = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let b = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        #expect(a.distance(to: b) > 0)
    }

    @Test func namedInitializerReturnsKnownAppleColor() {
        // "Apple" system color list ships with well-known keys like "Red".
        let color = NSColor(named: "Red")
        #expect(color != nil)
    }

    @Test func namedInitializerReturnsNilForUnknownName() {
        let color = NSColor(named: "definitely-not-a-real-color-\(UUID().uuidString)")
        #expect(color == nil)
    }

    @Test func colorNamesIsNonEmpty() {
        #expect(!NSColor.colorNames.isEmpty)
    }
}

// MARK: NSMenuItem+Extension

@MainActor
struct NSMenuItemExtensionTests {
    @Test func setImageIfDesiredIsSafeToCall() {
        let item = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
        let before = item.image
        item.setImageIfDesired(systemSymbolName: "doc.on.doc")
        // Below macOS 26 this remains a no-op; either way it must not crash
        // and the item's image is deterministic relative to its prior state.
        if #available(macOS 26, *) {
            #expect(item.image != nil)
        } else {
            #expect(item.image === before)
        }
    }
}

// MARK: NSMenu+Extension
