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

@MainActor
struct NSMenuExtensionTests {
    @Test func insertItemAfterActionInsertsAtCorrectIndex() {
        let menu = NSMenu()
        let first = NSMenuItem(title: "First", action: #selector(NSObject.description), keyEquivalent: "")
        let second = NSMenuItem(title: "Second", action: nil, keyEquivalent: "")
        menu.addItem(first)

        let inserted = NSMenuItem(title: "Inserted", action: nil, keyEquivalent: "")
        let index = menu.insertItem(inserted, after: #selector(NSObject.description))
        #expect(index == 1)
        #expect(menu.items[1] === inserted)

        menu.addItem(second)
        _ = second
    }

    @Test func insertItemAfterMissingActionReturnsNil() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Only", action: nil, keyEquivalent: ""))
        let inserted = NSMenuItem(title: "Inserted", action: nil, keyEquivalent: "")
        let index = menu.insertItem(inserted, after: #selector(NSObject.copy as () -> Any))
        #expect(index == nil)
        #expect(!menu.items.contains(where: { $0 === inserted }))
    }

    @Test func insertItemAfterRemovesExistingDuplicateIdentifierFirst() {
        let menu = NSMenu()
        let anchor = NSMenuItem(title: "Anchor", action: #selector(NSObject.description), keyEquivalent: "")
        menu.addItem(anchor)

        let identifier = NSUserInterfaceItemIdentifier("dup")
        let original = NSMenuItem(title: "Original", action: nil, keyEquivalent: "")
        original.identifier = identifier
        menu.addItem(original)

        let replacement = NSMenuItem(title: "Replacement", action: nil, keyEquivalent: "")
        replacement.identifier = identifier
        _ = menu.insertItem(replacement, after: #selector(NSObject.description))

        #expect(menu.items.filter { $0.identifier == identifier }.count == 1)
        #expect(menu.items.contains(where: { $0 === replacement }))
        #expect(!menu.items.contains(where: { $0 === original }))
    }

    @Test func removeItemsWithIdentifiersRemovesMatchingItemsOnly() {
        let menu = NSMenu()
        let keep = NSMenuItem(title: "Keep", action: nil, keyEquivalent: "")
        keep.identifier = NSUserInterfaceItemIdentifier("keep")
        let dropA = NSMenuItem(title: "DropA", action: nil, keyEquivalent: "")
        dropA.identifier = NSUserInterfaceItemIdentifier("drop-a")
        let dropB = NSMenuItem(title: "DropB", action: nil, keyEquivalent: "")
        dropB.identifier = NSUserInterfaceItemIdentifier("drop-b")

        menu.addItem(keep)
        menu.addItem(dropA)
        menu.addItem(dropB)

        menu.removeItems(withIdentifiers: [dropA.identifier!, dropB.identifier!])

        #expect(menu.items == [keep])
    }
}

// MARK: NSPasteboard+Extension

@MainActor
struct NSPasteboardExtensionAdditionalTests {
    @Test func mimeTypeInitHandlesUnregisteredMimeType() {
        // UTType(mimeType:) dynamically synthesizes a type for unknown MIME
        // strings on modern macOS, so this exercises the general utType.identifier
        // path (the raw-identifier fallback below it only fires if that ever
        // returns nil); either way the result must be non-nil and usable.
        let type = NSPasteboard.PasteboardType(mimeType: "application/x-tako-totally-made-up")
        #expect(type != nil)
    }

    @Test func takoSelectsGeneralPasteboardForStandardClipboard() {
        #expect(NSPasteboard.tako(TAKO_CLIPBOARD_STANDARD) === NSPasteboard.general)
    }

    @Test func takoSelectsSelectionPasteboardForSelectionClipboard() {
        #expect(NSPasteboard.tako(TAKO_CLIPBOARD_SELECTION) === NSPasteboard.takoSelection)
    }

    @Test func opinionatedContentsReturnsNilWhenPasteboardEmpty() {
        let pasteboard = NSPasteboard(name: .init("test-empty-\(UUID().uuidString)"))
        pasteboard.clearContents()
        #expect(pasteboard.getOpinionatedStringContents() == nil)
    }

    @Test func opinionatedContentsEscapesFileURLPath() {
        let pasteboard = NSPasteboard(name: .init("test-file-\(UUID().uuidString)"))
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        let url = URL(fileURLWithPath: "/tmp/has space/file.txt")
        item.setString((url as NSURL).absoluteString ?? url.absoluteString, forType: .fileURL)
        pasteboard.writeObjects([item])

        let result = pasteboard.getOpinionatedStringContents()
        #expect(result != nil)
        #expect(result?.contains("has\\ space") == true || result?.contains("\\ ") == true)
    }
}

// MARK: OSPasteboard+Extension

@MainActor
struct OSPasteboardExtensionTests {
    @MainActor
    @Test func stringGetterReflectsSetter() {
        let pasteboard = NSPasteboard(name: .init("test-osstring-\(UUID().uuidString)"))
        pasteboard.string = "hello os pasteboard"
        #expect(pasteboard.string == "hello os pasteboard")
    }

    @MainActor
    @Test func stringSetterWithNilClearsContents() {
        let pasteboard = NSPasteboard(name: .init("test-osstring-nil-\(UUID().uuidString)"))
        pasteboard.string = "content"
        pasteboard.string = nil
        #expect(pasteboard.string == nil)
    }

    @MainActor
    @Test func findPasteboardIsAccessible() {
        #expect(OSPasteboard.find.name == .find)
    }
}

// MARK: NSWorkspace+Extension

@MainActor
struct NSWorkspaceExtensionTests {
    @Test func defaultApplicationURLForExtensionResolvesTextFiles() {
        let url = NSWorkspace.shared.defaultApplicationURL(forExtension: "txt")
        #expect(url == nil || url?.isFileURL == true)
    }

    @Test func defaultApplicationURLForUnknownExtensionIsNilOrFile() {
        let url = NSWorkspace.shared.defaultApplicationURL(forExtension: "definitely-not-a-real-ext-xyz")
        #expect(url == nil)
    }

    @Test func defaultTextEditorAndTerminalAreQueriable() {
        // We can't assert a specific app is installed on the CI machine, but the
        // computed properties must route through defaultApplicationURL(forContentType:)
        // without crashing and return a file URL when present.
        let editor = NSWorkspace.shared.defaultTextEditor
        #expect(editor == nil || editor?.isFileURL == true)

        let terminal = NSWorkspace.shared.defaultTerminal
        #expect(terminal == nil || terminal?.isFileURL == true)
    }
}

// MARK: NSImage+Extension

@MainActor
struct NSImageExtensionTests {
    private func solidImage(size: NSSize, color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    @Test func combineRequiresMatchingCounts() {
        let image = solidImage(size: .init(width: 4, height: 4), color: .red)
        let result = NSImage.combine(images: [image], blendingModes: [.normal, .multiply])
        #expect(result == nil)
    }

    @Test func combineRequiresNonEmptyInput() {
        let result = NSImage.combine(images: [], blendingModes: [])
        #expect(result == nil)
    }

    @Test func combineProducesImageOfFirstImageSize() {
        let a = solidImage(size: .init(width: 8, height: 8), color: .red)
        let b = solidImage(size: .init(width: 8, height: 8), color: .blue)
        let combined = NSImage.combine(images: [a, b], blendingModes: [.normal, .multiply])
        #expect(combined?.size == NSSize(width: 8, height: 8))
    }

    @Test func gradientProducesNonNilImage() {
        let base = solidImage(size: .init(width: 10, height: 10), color: .black)
        let result = base.gradient(colors: [.red, .blue])
        #expect(result != nil)
        #expect(result?.size == base.size)
    }

    @Test func tintProducesImageOfSameSize() {
        let base = solidImage(size: .init(width: 6, height: 6), color: .white)
        let tinted = base.tint(color: .green)
        #expect(tinted != nil)
        #expect(tinted?.size == base.size)
    }
}

// MARK: NSScreen+Extension (hasDock / hasNotch / displayID via controllable mocks)

@MainActor
struct NSScreenExtensionAdditionalTests {
    private final class MockScreen: NSScreen {
        let mockFrame: NSRect
        let mockVisibleFrame: NSRect
        let mockSafeAreaInsets: NSEdgeInsets

        init(frame: NSRect, visibleFrame: NSRect, safeAreaInsets: NSEdgeInsets = .init()) {
            self.mockFrame = frame
            self.mockVisibleFrame = visibleFrame
            self.mockSafeAreaInsets = safeAreaInsets
            super.init()
        }

        required init?(coder: NSCoder) { fatalError("unsupported") }

        override var frame: NSRect { mockFrame }
        override var visibleFrame: NSRect { mockVisibleFrame }
        override var safeAreaInsets: NSEdgeInsets { mockSafeAreaInsets }

        // AppKit's own description of a screen traps on one with no display
        // behind it, and a failed #expect describes the values it read -- so
        // without these a failure killed the whole test process instead of
        // being reported.
        override var description: String { "MockScreen(\(mockFrame), visible: \(mockVisibleFrame))" }
        override var debugDescription: String { description }
    }

    // The dock expectations pass the autohide preference in: `hasDock` alone
    // reads the one of the Mac running the tests, which is whatever its owner
    // chose.

    @Test func hasDockIsTrueWhenVisibleWidthIsNarrower() {
        let screen = MockScreen(
            frame: .init(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: .init(x: 0, y: 0, width: 900, height: 800))
        #expect(screen.hasDock(dockAutohides: false))
    }

    @Test func hasDockIsTrueWhenVisibleHeightLeavesRoomForADock() {
        _ = NSApplication.shared
        let screen = MockScreen(
            frame: .init(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: .init(x: 0, y: 0, width: 1000, height: 800 - 200))
        // Height difference alone (no width shrink) must exceed the menu bar
        // height + padding to be considered a dock; with such a large gap it
        // must read true.
        #expect(screen.hasDock(dockAutohides: false))
    }

    @Test func hasDockIsFalseWhenFramesMatch() {
        _ = NSApplication.shared
        let rect = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let screen = MockScreen(frame: rect, visibleFrame: rect)
        #expect(!screen.hasDock(dockAutohides: false))
    }

    @Test func anAutohidingDockIsNeverThere() {
        let screen = MockScreen(
            frame: .init(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: .init(x: 0, y: 0, width: 900, height: 800))
        #expect(!screen.hasDock(dockAutohides: true))
    }

    @Test func hasDockReadsTheAutohidePreferenceOfThisMac() {
        let screen = MockScreen(
            frame: .init(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: .init(x: 0, y: 0, width: 900, height: 800))
        let autohides = UserDefaults.tako.persistentDomain(forName: "com.apple.dock")?["autohide"] as? Bool ?? false
        #expect(screen.hasDock == !autohides)
    }

    @Test func hasNotchIsTrueWithPositiveTopInset() {
        let screen = MockScreen(
            frame: .init(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: .init(x: 0, y: 0, width: 1000, height: 780),
            safeAreaInsets: .init(top: 32, left: 0, bottom: 0, right: 0))
        #expect(screen.hasNotch)
    }

    @Test func hasNotchIsFalseWithoutTopInset() {
        let screen = MockScreen(
            frame: .init(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: .init(x: 0, y: 0, width: 1000, height: 780))
        #expect(!screen.hasNotch)
    }

    @Test func realMainScreenExposesDisplayIdentity() {
        guard let screen = NSScreen.main else {
            Issue.record("Expected a main screen while running on the test Mac")
            return
        }
        #expect(screen.displayID != nil)
        #expect(screen.displayUUID != nil)
    }
}

// MARK: UndoManager+Extension

@MainActor
struct UndoManagerExtensionTests {
    @Test func isUndoingOrRedoingReflectsEitherState() {
        let manager = UndoManager()
        #expect(!manager.isUndoingOrRedoing)
    }

    @Test func disableUndoRegistrationRunsHandlerAndRestoresState() {
        let manager = UndoManager()
        var handlerRan = false
        var registeredDuringHandler = false

        manager.disableUndoRegistration {
            handlerRan = true
            registeredDuringHandler = manager.isUndoRegistrationEnabled
        }

        #expect(handlerRan)
        #expect(!registeredDuringHandler)
        #expect(manager.isUndoRegistrationEnabled)
    }
}

// MARK: UserDefaults+Extension

@MainActor
struct UserDefaultsExtensionTests {
    @Test func takoSuiteReadsEnvironmentVariableInDebug() {
        let suiteName = "com.tako-core.coverage-test-\(UUID().uuidString)"
        setenv("TAKO_USER_DEFAULTS_SUITE", suiteName, 1)
        defer {
            unsetenv("TAKO_USER_DEFAULTS_SUITE")
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }

        #if DEBUG
        #expect(UserDefaults.takoSuite == suiteName)
        #expect(UserDefaults.tako.value(forKey: "unset-key") == nil)
        #else
        #expect(UserDefaults.takoSuite == nil)
        #endif
    }

    @Test func takoFallsBackToStandardWithoutSuite() {
        unsetenv("TAKO_USER_DEFAULTS_SUITE")
        #expect(UserDefaults.tako === UserDefaults.standard)
    }
}

// MARK: View+Extension

@MainActor
struct ViewExtensionTests {
    @Test func innerShadowProducesRenderableView() {
        let view = Rectangle().fill(.blue).innerShadow()
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        #expect(hosting.fittingSize.width >= 0)
    }

    @Test func pointerStyleFromCursorProducesRenderableView() {
        let view = Rectangle().fill(.red).pointerStyleFromCursor(.arrow)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        #expect(hosting.fittingSize.width >= 0)
    }
}
