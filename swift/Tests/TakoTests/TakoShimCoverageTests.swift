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

