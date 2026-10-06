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


@Suite(.serialized)
@MainActor
struct SurfaceFindActionTests {
    /// Three matches differing only in case: the oldest deep in
    /// scrollback, one just above the screen, the newest on screen.
    private func seededSurface() -> (Tako.SurfaceView, NSWindow) {
        let (view, window) = hostedSurface()
        feedLines(view, count: 200, extra: [
            10: "alpha Needle-Xyz omega",
            150: "beta NEEDLE-XYZ",
            199: "gamma needle-xyz",
        ])
        return (view, window)
    }

    private func visibleRow(of view: Tako.SurfaceView) -> Int? {
        view.core.selectionRange().map { Int($0.startRow) }
    }

    @Test func searchSelectsTheNewestMatchAndNavigationWrapsBothWays() throws {
        let (view, window) = seededSurface()
        defer { window.close() }

        #expect(view.performBindingAction("search:needle-xyz"))
        let state = try #require(view.searchState)
        #expect(state.total == 3)
        #expect(state.selected == 0)
        #expect(view.core.selectedText() == "needle-xyz")
        #expect(view.viewportOffset == 0)

        // Next goes to older output: into the scrollback, which scrolls.
        #expect(view.performBindingAction("navigate_search:next"))
        #expect(view.core.selectedText() == "NEEDLE-XYZ")
        #expect(state.selected == 1)
        #expect(view.viewportOffset > 0)
        #expect(visibleRow(of: view) != nil)

        #expect(view.performBindingAction("navigate_search:next"))
        #expect(view.core.selectedText() == "Needle-Xyz")
        #expect(state.selected == 2)
        #expect(visibleRow(of: view) != nil)

        // Past the oldest, next wraps round to the newest.
        #expect(view.performBindingAction("navigate_search:next"))
        #expect(view.core.selectedText() == "needle-xyz")
        #expect(state.selected == 0)
        #expect(view.viewportOffset == 0)

        // And previous wraps the other way, from the newest to the oldest.
        #expect(view.performBindingAction("navigate_search:previous"))
        #expect(view.core.selectedText() == "Needle-Xyz")
        #expect(state.selected == 2)
        #expect(visibleRow(of: view) != nil)

        #expect(view.performBindingAction("navigate_search:previous"))
        #expect(view.core.selectedText() == "NEEDLE-XYZ")
        #expect(state.selected == 1)

        #expect(view.findPasteboard.string(forType: .string) == "needle-xyz")
        #expect(!view.performBindingAction("navigate_search:sideways"))
    }

    @Test func menuActionsDriveTheSameSearch() throws {
        let (view, window) = seededSurface()
        defer { window.close() }
        let next = menuItem(#selector(Tako.SurfaceView.findNext(_:)))
        let hide = menuItem(#selector(Tako.SurfaceView.findHide(_:)))

        #expect(!view.validateUserInterfaceItem(next))
        #expect(!view.validateUserInterfaceItem(hide))
        #expect(view.validateUserInterfaceItem(menuItem(#selector(Tako.SurfaceView.find(_:)))))

        view.findPasteboard.clearContents()
        view.findPasteboard.setString("needle-xyz", forType: .string)
        view.find(self)
        let state = try #require(view.searchState)
        #expect(state.needle == "needle-xyz")
        #expect(state.total == 3)
        #expect(view.validateUserInterfaceItem(next))
        #expect(view.validateUserInterfaceItem(hide))

        view.findNext(self)
        #expect(view.core.selectedText() == "NEEDLE-XYZ")
        view.findPrevious(self)
        #expect(view.core.selectedText() == "needle-xyz")

        // Typing into the open bar searches again.
        state.needle = "alpha"
        #expect(state.total == 1)
        #expect(view.core.selectedText() == "alpha")

        // Find while open keeps the bar and its needle.
        view.find(self)
        #expect(view.searchState === state)

        view.findHide(self)
        #expect(view.searchState == nil)
        #expect(!view.validateUserInterfaceItem(next))
        #expect(!view.performBindingAction("navigate_search:next"))
        #expect(!view.performBindingAction("end_search"))
        // The last match stays selected so it can be copied.
        #expect(view.core.selectedText() == "alpha")
    }

    @Test func theControllerForwardsFindAndFindPreviousToTheirOwnActions() {
        let (view, window) = seededSurface()
        defer { window.close() }
        let controller = BaseTerminalController(Tako.App(), surfaceTree: .init(view: view))
        controller.focusedSurface = view
        let previous = menuItem(#selector(BaseTerminalController.findPrevious(_:)))

        #expect(!controller.validateMenuItem(previous))
        #expect(view.performBindingAction("search:needle-xyz"))
        #expect(controller.validateMenuItem(previous))
        controller.findNext(self)
        #expect(view.core.selectedText() == "NEEDLE-XYZ")
        // Find Previous used to run Find Next.
        controller.findPrevious(self)
        #expect(view.core.selectedText() == "needle-xyz")
        controller.findHide(self)
        #expect(view.searchState == nil)
    }

    @Test func searchSelectionAndScrollToSelection() throws {
        let (view, window) = seededSurface()
        defer { window.close() }
        let scrollItem = menuItem(#selector(Tako.SurfaceView.scrollToSelection(_:)))

        #expect(!view.performBindingAction("search_selection"))
        #expect(!view.performBindingAction("scroll_to_selection"))
        #expect(!view.validateUserInterfaceItem(scrollItem))

        #expect(view.performBindingAction("search:beta"))
        #expect(view.core.selectedText() == "beta")
        #expect(view.performBindingAction("end_search"))

        // Scrolled away, the selection is off screen until asked for.
        view.scrollViewportToBottom()
        #expect(view.core.selectionRange() == nil)
        #expect(view.validateUserInterfaceItem(scrollItem))
        #expect(view.performBindingAction("scroll_to_selection"))
        #expect(view.core.selectionRange() != nil)
        #expect(view.viewportOffset > 0)

        #expect(view.performBindingAction("search_selection"))
        let state = try #require(view.searchState)
        #expect(state.needle == "beta")
        #expect(state.total == 1)
        view.selectionForFind(self)
        #expect(view.searchState === state)
    }

    @Test func matchesAreFoundByColumnPastWideCharacters() {
        let (view, window) = hostedSurface()
        defer { window.close() }
        view.core.feed(bytes: Data("\r\n\u{65E5}\u{672C} wide-needle tail".utf8))

        #expect(view.performBindingAction("search:WIDE-needle"))
        #expect(view.core.selectedText() == "wide-needle")
        let range = view.core.selectionRange()
        #expect(range?.startCol == 5)
        #expect(range?.endCol == 15)
    }

    @Test func aSearchWithNoMatchesSelectsNothing() throws {
        let (view, window) = seededSurface()
        defer { window.close() }

        #expect(!view.performBindingAction("search:"))
        #expect(view.performBindingAction("start_search"))
        let state = try #require(view.searchState)
        state.needle = "not-in-the-buffer"
        #expect(state.total == 0)
        #expect(state.selected == nil)
        #expect(!view.performBindingAction("navigate_search:next"))
        #expect(!view.validateUserInterfaceItem(menuItem(#selector(Tako.SurfaceView.findNext(_:)))))
    }

    @Test func resetWhileSearchingEmptiesTheResults() throws {
        let (view, window) = seededSurface()
        defer { window.close() }
        #expect(view.performBindingAction("search:needle-xyz"))
        let state = try #require(view.searchState)

        #expect(view.performBindingAction("reset"))
        #expect(state.total == 0)
        #expect(view.core.hasSelection() == false)
    }

    @Test func theFindBarCountsAndNavigates() throws {
        let (view, window) = seededSurface()
        defer { window.close() }
        #expect(Tako.SurfaceSearchBar.counter(selected: nil, total: nil) == "")
        #expect(Tako.SurfaceSearchBar.counter(selected: nil, total: 0) == "0/0")
        #expect(Tako.SurfaceSearchBar.counter(selected: 1, total: 3) == "2/3")

        #expect(view.performBindingAction("search:needle-xyz"))
        let state = try #require(view.searchState)
        let hosting = NSHostingView(rootView: Tako.InspectableSurface(surfaceView: view))
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 240)
        hosting.layoutSubtreeIfNeeded()
        let bar = Tako.SurfaceSearchBar(surfaceView: view, searchState: state)
        _ = NSHostingView(rootView: bar).fittingSize

        bar.submit(shift: false)
        #expect(state.selected == 1)
        bar.submit(shift: true)
        #expect(state.selected == 0)
    }
}

// MARK: - Binding dispatch
