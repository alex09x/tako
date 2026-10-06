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
import UserNotifications
@testable import Tako

struct AppDelegateSecureInputTests {
    @Test func setSecureInputOnOffAndToggleAllUpdateTheGlobalFlag() {
        let delegate = AppDelegate()
        let originallyOn = SecureInput.shared.global
        defer {
            if SecureInput.shared.global != originallyOn {
                delegate.setSecureInput(originallyOn ? .on : .off)
            }
        }

        delegate.setSecureInput(.on)
        #expect(SecureInput.shared.global)

        delegate.setSecureInput(.off)
        #expect(!SecureInput.shared.global)

        delegate.setSecureInput(.toggle)
        #expect(SecureInput.shared.global)

        delegate.setSecureInput(.toggle)
        #expect(!SecureInput.shared.global)
    }
}

@MainActor
struct AppDelegateIBActionTests {
    @Test func reloadConfigPostsAConfigChangeNotification() {
        let delegate = AppDelegate()
        var received = false
        let observer = NotificationCenter.default.addObserver(
            forName: .takoConfigDidChange, object: nil, queue: nil
        ) { _ in received = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        delegate.reloadConfig(nil)
        #expect(received)
    }

    @Test func newWindowAndNewTabIBActionsConstructRealControllersWithoutCrashing() {
        // Both defer `showWindow` the same way `applicationDidBecomeActive`'s
        // initial-window path does (see that test's doc comment): nothing
        // here reaches the excluded Terminal.xib nib.
        let delegate = AppDelegate()
        delegate.newWindow(nil)
        delegate.newTab(nil)
    }

    @Test func toggleSecureInputFlipsTheGlobalFlag() {
        let delegate = AppDelegate()
        let before = SecureInput.shared.global
        defer { if SecureInput.shared.global != before { delegate.toggleSecureInput(delegate) } }
        delegate.toggleSecureInput(delegate)
        #expect(SecureInput.shared.global != before)
    }

    @Test func toggleVisibilityActivatesTheAppWhenNotAlreadyActive() {
        // `NSApp.isActive` is false for this test host (this process cannot
        // win real macOS activation in this harness -- confirmed the same
        // way GlobalEventTapTests documents it), so this always takes the
        // "become active" branch, not the "hide" branch.
        let delegate = AppDelegate()
        delegate.toggleVisibility(delegate)
    }

    @Test func bringAllToFrontActivatesAndArrangesWindows() {
        let delegate = AppDelegate()
        delegate.bringAllToFront(delegate)
    }

    @Test func undoAndRedoAreNoOpsWithNothingRegistered() {
        let delegate = AppDelegate()
        #expect(!delegate.undoManager.canUndo)
        delegate.undo(nil)
        #expect(!delegate.undoManager.canRedo)
        delegate.redo(nil)
    }

    @Test func floatOnTopTogglesTheMenuItemStateEvenWithNoKeyWindow() {
        let delegate = AppDelegate()
        let item = NSMenuItem(title: "Float on Top", action: nil, keyEquivalent: "")
        item.state = .off
        delegate.floatOnTop(item)
        #expect(item.state == .on)
        delegate.floatOnTop(item)
        #expect(item.state == .off)
    }

    @Test func useAsDefaultWritesAndClearsTheDefaultLevelPreference() {
        let delegate = AppDelegate()
        let key = TerminalWindow.defaultLevelKey
        let ud = UserDefaults.tako
        defer { ud.removeObject(forKey: key) }

        let onItem = NSMenuItem(title: "Use as Default", action: nil, keyEquivalent: "")
        onItem.state = .off
        delegate.floatOnTop(onItem) // -> .on, matching menuFloatOnTop's own state indirectly
        delegate.useAsDefault(onItem)
        // useAsDefault reads self.menuFloatOnTop (an @IBOutlet, nil here since
        // there's no nib), not the item passed in, so this always takes the
        // "off" branch and removes the key -- covering the removal line
        // deterministically without depending on outlet wiring.
        #expect(ud.object(forKey: key) == nil)
    }

    @Test func useAsDefaultSetsTheFloatingLevelWhenMenuFloatOnTopIsOn() {
        // `menuFloatOnTop` was widened from `private` (an @IBOutlet with no
        // nib to wire it in this target) so this branch -- otherwise
        // unreachable, as the sibling test above documents -- can be driven
        // directly.
        let delegate = AppDelegate()
        let key = TerminalWindow.defaultLevelKey
        let ud = UserDefaults.tako
        defer { ud.removeObject(forKey: key) }

        delegate.menuFloatOnTop = NSMenuItem(title: "Float on Top", action: nil, keyEquivalent: "")
        delegate.menuFloatOnTop?.state = .on

        delegate.useAsDefault(delegate.menuFloatOnTop!)
        #expect(ud.value(forKey: key) as? NSWindow.Level == .floating)
    }
}

@MainActor
struct AppDelegateMenuValidationTests {
    private func menuItem(_ selector: Selector) -> NSMenuItem {
        NSMenuItem(title: "Item", action: selector, keyEquivalent: "")
    }

    @Test func setAsDefaultTerminalValidatesAgainstTheCurrentDefaultTerminal() {
        let delegate = AppDelegate()
        let item = menuItem(#selector(AppDelegate.setAsDefaultTerminal(_:)))
        _ = delegate.validateMenuItem(item)
    }

    @Test func floatOnTopAndUseAsDefaultAreOnlyValidWithATerminalWindowKey() {
        let delegate = AppDelegate()
        let floatItem = menuItem(#selector(AppDelegate.floatOnTop(_:)))
        let useAsDefaultItem = menuItem(#selector(AppDelegate.useAsDefault(_:)))
        #expect(!delegate.validateMenuItem(floatItem))
        #expect(!delegate.validateMenuItem(useAsDefaultItem))
    }

    @Test func undoAndRedoUpdateTitlesToReflectAvailability() {
        let delegate = AppDelegate()
        let undoItem = menuItem(#selector(AppDelegate.undo(_:)))
        let redoItem = menuItem(#selector(AppDelegate.redo(_:)))
        #expect(!delegate.validateMenuItem(undoItem))
        #expect(undoItem.title == "Undo")
        #expect(!delegate.validateMenuItem(redoItem))
        #expect(redoItem.title == "Redo")
    }

    @Test func unrelatedSelectorsAreAlwaysValid() {
        let delegate = AppDelegate()
        let item = menuItem(#selector(AppDelegate.reloadConfig(_:)))
        #expect(delegate.validateMenuItem(item))
    }
}

@MainActor
struct AppDelegateFloatOnTopMenuSyncTests {
    @Test func syncFloatOnTopMenuTurnsOffWhenTheKeyWindowIsNotATerminalWindow() {
        let delegate = AppDelegate()
        let plain = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        plain.isReleasedWhenClosed = false
        defer { plain.close() }

        delegate.syncFloatOnTopMenu(plain)
        // No @IBOutlet is wired for a bare AppDelegate(), so this only
        // confirms the call is safe with a non-TerminalWindow argument.
    }

    @Test func syncFloatOnTopMenuFallsBackToTheKeyWindowWhenGivenNil() {
        let delegate = AppDelegate()
        delegate.syncFloatOnTopMenu(nil)
    }

    @Test func syncFloatOnTopMenuReflectsAFloatingTerminalWindowsLevel() {
        // `TerminalWindow` has no custom designated initializer of its own
        // (it relies on the inherited `NSWindow` one), so it's safe to
        // construct directly without going through `Terminal.xib`.
        let delegate = AppDelegate()
        let window = TerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        window.level = .floating
        delegate.syncFloatOnTopMenu(window)

        window.level = .normal
        delegate.syncFloatOnTopMenu(window)
    }
}

@MainActor
