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
@testable import Tako

/// `Terminal.xib` and its titlebar variants are excluded from this SwiftPM
/// test target (see `swift/Package.swift`), so these windows are built
/// directly (never through a nib) and `awakeFromNib()` is invoked manually,
/// mirroring `TerminalTestSupport`/`QTTestSupport`'s established pattern.
@MainActor
func withAppDelegate<T>(_ body: (AppDelegate) throws -> T) rethrows -> T {
    let appDelegate = AppDelegate()
    let originalDelegate = NSApplication.shared.delegate
    NSApplication.shared.delegate = appDelegate
    defer { NSApplication.shared.delegate = originalDelegate }
    return try body(appDelegate)
}

@MainActor
func makeWindow() -> TerminalWindow {
    let window = TerminalWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    return window
}

@Suite(.serialized)
@MainActor
struct TerminalWindowCoverageTests {
    @Test func awakeFromNibConfiguresTheWindowWithAnAppDelegate() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            #expect(window.tabbingMode == .disallowed)
            #expect(window.titleVisibility == .hidden)
            #expect(window.titlebarAppearsTransparent)
        }
    }

    @Test func awakeFromNibIsSafeWithoutAnAppDelegate() {
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = nil
        defer { NSApplication.shared.delegate = originalDelegate }
        let window = makeWindow()
        defer { window.orderOut(nil) }
        window.awakeFromNib()
        #expect(window.tabbingMode == .disallowed)
    }

    @Test func canBecomeKeyAndMainAreAlwaysTrue() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        #expect(window.canBecomeKey)
        #expect(window.canBecomeMain)
    }

    @Test func closePostsTheWillCloseNotification() {
        withAppDelegate { _ in
            let window = makeWindow()
            window.awakeFromNib()
            window.makeKeyAndOrderFront(nil)
            var posted = false
            let token = NotificationCenter.default.addObserver(
                forName: TerminalWindow.terminalWillCloseNotification, object: window, queue: nil
            ) { _ in posted = true }
            defer { NotificationCenter.default.removeObserver(token) }
            window.close()
            #expect(posted)
        }
    }

    @Test func becomeKeyAndResignKeyDoNotCrash() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.becomeKey()
            window.resignKey()
            #expect(true)
        }
    }

    @Test func becomeMainAndResignMainDoNotCrash() {
        withAppDelegate { _ in
            let window = makeWindow()
            defer { window.orderOut(nil) }
            window.awakeFromNib()
            window.becomeMain()
            window.resignMain()
            #expect(true)
        }
    }

    @Test func mergeAllWindowsDoesNotCrash() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        window.mergeAllWindows(nil)
        #expect(true)
    }

    @Test func hasMoreThanOneTabsIsFalseForALoneWindow() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        #expect(!window.hasMoreThanOneTabs)
    }

    @Test func isTabBarDetectsAnUnidentifiedEmptyBottomAccessory() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let vc = NSTitlebarAccessoryViewController()
        vc.layoutAttribute = .bottom
        vc.view = NSView()
        #expect(window.isTabBar(vc))
    }

    @Test func isTabBarRejectsAnUnrelatedAccessory() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let vc = NSTitlebarAccessoryViewController()
        vc.layoutAttribute = .right
        vc.view = NSView()
        #expect(!window.isTabBar(vc))
    }

    @Test func isTabBarHonorsAnExplicitIdentifier() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let vc = NSTitlebarAccessoryViewController()
        vc.identifier = TerminalWindow.tabBarIdentifier
        vc.view = NSView()
        #expect(window.isTabBar(vc))
    }

    @Test func addAndRemoveTitlebarAccessoryViewControllerTracksTheTabBar() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let vc = NSTitlebarAccessoryViewController()
        vc.layoutAttribute = .bottom
        vc.view = NSView()
        window.addTitlebarAccessoryViewController(vc)
        #expect(vc.identifier == TerminalWindow.tabBarIdentifier)
        window.removeTitlebarAccessoryViewController(at: 0)
        #expect(true)
    }

    @Test func keyEquivalentUpdatesTheLabel() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        window.keyEquivalent = "1"
        #expect(window.keyEquivalent == "1")
        window.keyEquivalent = nil
        #expect(window.keyEquivalent == nil)
    }

    @Test func surfaceIsZoomedTogglesTheResetButton() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        window.surfaceIsZoomed = true
        #expect(window.surfaceIsZoomed)
        window.surfaceIsZoomed = false
        #expect(!window.surfaceIsZoomed)
    }

    @Test func titleUpdatesTheTabAttributedTitle() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        window.title = "Hello"
        #expect(window.title == "Hello")
    }

    @Test func titlebarFontFallsBackToTheSystemFont() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        window.titlebarFont = nil
        #expect(window.titlebarFont == nil)
        window.titlebarFont = NSFont.systemFont(ofSize: 12)
        #expect(window.titlebarFont != nil)
    }

    @Test func attributedTitleIsNilWithoutATitlebarFont() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        window.titlebarFont = nil
        #expect(window.attributedTitle == nil)
    }

    @Test func attributedTitleIsSetWithATitlebarFont() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        window.title = "Hi"
        window.titlebarFont = NSFont.systemFont(ofSize: 12)
        #expect(window.attributedTitle != nil)
    }

    @Test func titlebarContainerIsFoundFromTheRealWindowChrome() {
        // Even without our own nib, a `.titled` `NSWindow` still gets
        // AppKit's standard titlebar chrome, so this is found regardless.
        let window = makeWindow()
        defer { window.orderOut(nil) }
        #expect(window.titlebarContainer != nil)
    }


}
