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
import Testing
@testable import Tako

/// Closing Find in All Tabs gives the keyboard back to its own terminal only
/// while its tab is still the one shown. A result opened in another tab closes
/// the panel after that tab was chosen; returning focus to the panel's tab then
/// chose it again and hid the match (a floating canvas selects its tab to
/// focus a pane).
@MainActor @Suite(.serialized)
struct FindAllFocusReturnTests {
    /// A terminal window whose visibility the test sets, so nothing has to be
    /// put on screen to be "visible" or ordered out to be hidden.
    final class ShownWindow: TerminalWindow {
        var shown = false
        override var isVisible: Bool { shown }
    }

    private func tab(shown: Bool) throws -> (controller: TerminalController, window: ShownWindow, pane: Tako.SurfaceView) {
        TerminalTestSupport.preventQuitting()
        let controller = TerminalController(Tako.App(), withBaseConfig: nil, withSurfaceTree: nil)
        let window = ShownWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        controller.windowDidLoad()
        controller.floatingCanvas.reduceMotionProvider = { true }
        window.shown = shown
        let pane = try #require(controller.focusedSurface)
        return (controller, window, pane)
    }

    private func close(_ tabs: (controller: TerminalController, window: ShownWindow, pane: Tako.SurfaceView)...) {
        for tab in tabs {
            tab.window.shown = false
            TerminalTestSupport.tearDown(tab.controller, tab.window)
        }
    }

    /// The panel over `controller` opens, then closes, and the main queue runs
    /// past the close's own asynchronous focus step. A test on the main actor
    /// runs inside a main-queue job, where spinning the run loop would not run
    /// the next main-queue block; suspending does.
    private func openAndClosePanel(_ controller: TerminalController) async throws {
        controller.findAllIsShowing = true
        controller.findAllIsShowing = false
        try await Task.sleep(for: .milliseconds(300))
    }

    @Test func aHiddenPanelTabClosingAfterARevealLeavesTheRevealedTabChosen() async throws {
        let old = try tab(shown: false), revealed = try tab(shown: true)
        defer { close(old, revealed) }
        Tako.CustomTabGroup.join(revealed.window, to: old.window, select: false)
        let group = Tako.CustomTabGroup.group(for: old.window)
        group.selectedWindow = revealed.window

        try await openAndClosePanel(old.controller)

        #expect(group.selectedWindow === revealed.window, "the tab the match was opened in stays chosen")
    }

    @Test func aStillVisibleButReplacedPanelTabDoesNotTakeTheTabBack() async throws {
        // A tab just replaced stays on screen until its order-out runs.
        let old = try tab(shown: true), revealed = try tab(shown: true)
        defer { close(old, revealed) }
        Tako.CustomTabGroup.join(revealed.window, to: old.window, select: false)
        let group = Tako.CustomTabGroup.group(for: old.window)
        group.selectedWindow = revealed.window

        try await openAndClosePanel(old.controller)

        #expect(group.selectedWindow === revealed.window, "being visible is not being the chosen tab")
    }

    @Test func closingThePanelInTheShownTabGivesTheKeyboardBackToItsTerminal() async throws {
        let shown = try tab(shown: true)
        defer { close(shown) }
        let group = Tako.CustomTabGroup.group(for: shown.window)
        #expect(group.selectedWindow === shown.window)
        shown.window.contentView?.layoutSubtreeIfNeeded()
        try #require(shown.pane.window === shown.window, "the terminal must be in its window for focus to land on it")
        // The window's own first focus completes once; let it, then take the
        // keyboard away and check nothing but the panel's close gives it back.
        try await Task.sleep(for: .milliseconds(500))
        shown.window.makeFirstResponder(nil)
        try await Task.sleep(for: .milliseconds(500))
        try #require(shown.window.firstResponder !== shown.pane, "control: nothing else returns the keyboard")

        try await openAndClosePanel(shown.controller)

        var returned = shown.window.firstResponder === shown.pane
        for _ in 0..<20 where !returned {
            try await Task.sleep(for: .milliseconds(100))
            returned = shown.window.firstResponder === shown.pane
        }
        #expect(returned, "closing the panel in the tab it covers returns the keyboard to that terminal")
        #expect(group.selectedWindow === shown.window)
    }
}
