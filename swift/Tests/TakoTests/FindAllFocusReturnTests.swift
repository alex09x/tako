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
    /// past the close's own asynchronous focus step.
    private func openAndClosePanel(_ controller: TerminalController) {
        controller.findAllIsShowing = true
        controller.findAllIsShowing = false
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    @Test func aHiddenPanelTabClosingAfterARevealLeavesTheRevealedTabChosen() throws {
        let old = try tab(shown: false), revealed = try tab(shown: true)
        defer { close(old, revealed) }
        Tako.CustomTabGroup.join(revealed.window, to: old.window, select: false)
        let group = Tako.CustomTabGroup.group(for: old.window)
        group.selectedWindow = revealed.window

        openAndClosePanel(old.controller)

        #expect(group.selectedWindow === revealed.window, "the tab the match was opened in stays chosen")
    }

    @Test func aStillVisibleButReplacedPanelTabDoesNotTakeTheTabBack() throws {
        // A tab just replaced stays on screen until its order-out runs.
        let old = try tab(shown: true), revealed = try tab(shown: true)
        defer { close(old, revealed) }
        Tako.CustomTabGroup.join(revealed.window, to: old.window, select: false)
        let group = Tako.CustomTabGroup.group(for: old.window)
        group.selectedWindow = revealed.window

        openAndClosePanel(old.controller)

        #expect(group.selectedWindow === revealed.window, "being visible is not being the chosen tab")
    }

    @Test func closingThePanelInTheShownTabGivesTheKeyboardBackToItsTerminal() throws {
        let shown = try tab(shown: true)
        defer { close(shown) }
        let group = Tako.CustomTabGroup.group(for: shown.window)
        #expect(group.selectedWindow === shown.window)
        shown.window.contentView?.layoutSubtreeIfNeeded()
        try #require(shown.pane.window === shown.window, "the terminal must be in its window for focus to land on it")
        shown.window.makeFirstResponder(nil)
        try #require(shown.window.firstResponder !== shown.pane)

        openAndClosePanel(shown.controller)

        #expect(TerminalTestSupport.waitUntil(timeout: 2) { shown.window.firstResponder === shown.pane },
                "closing the panel in the tab it covers returns the keyboard to that terminal")
        #expect(group.selectedWindow === shown.window)
    }
}
