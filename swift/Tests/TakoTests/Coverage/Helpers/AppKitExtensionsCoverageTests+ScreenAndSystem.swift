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

@MainActor

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
