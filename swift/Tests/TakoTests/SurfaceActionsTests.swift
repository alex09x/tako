import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Tako

// The actions a surface carries out when a menu item, a keybinding, the
// command palette or AppleScript asks for them by name, and the ones it
// refuses. Each test hosts a real surface in an offscreen window.
//
// The surface starts a login shell like the app does. It is closed straight
// away: the tests feed the engine directly, and a prompt arriving part-way
// through would make what is on screen depend on the shell.

@MainActor
private func settle(_ seconds: TimeInterval = 0.2) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

@MainActor
private func hostedSurface(theme: TerminalTheme = TerminalTheme()) -> (Tako.SurfaceView, NSWindow) {
    let view = Tako.SurfaceView(theme: theme)
    view.close()
    settle()
    let window = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: 480, height: 240),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    view.flushPendingResizeForTesting()
    view.findPasteboard = OSPasteboard.withUniqueName()
    return (view, window)
}

@MainActor
private func menuItem(_ action: Selector) -> NSMenuItem {
    NSMenuItem(title: "", action: action, keyEquivalent: "")
}

/// Records the notifications posted for `object`.
final class NotificationLog {
    private(set) var names: [Notification.Name] = []
    private var tokens: [NSObjectProtocol] = []

    init(_ names: Notification.Name..., object: AnyObject) {
        tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] note in
                self?.names.append(note.name)
            }
        }
    }

    func stop() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
    }
}

/// Feeds `count` numbered lines, putting `extra[i]` on line `i` instead.
@MainActor
private func feedLines(_ view: Tako.SurfaceView, count: Int, extra: [Int: String] = [:]) {
    let text = (0..<count).map { extra[$0] ?? "history line \($0)" }.joined(separator: "\r\n")
    view.core.feed(bytes: Data(text.utf8))
}

// MARK: - Font size

@Suite(.serialized)
@MainActor
struct SurfaceFontSizeActionTests {
    @Test func fontSizeChangesCellMetricsAndTheGridAndResets() {
        let (view, window) = hostedSurface()
        defer { window.close() }
        let width = view.cellWidth
        let height = view.cellHeight
        let cols = view.cols
        let rows = view.rows

        #expect(view.performBindingAction("increase_font_size:6"))
        #expect(view.theme.fontSize == 19)
        #expect(view.cellWidth > width)
        #expect(view.cellHeight > height)
        view.flushPendingResizeForTesting()
        #expect(view.cols < cols)
        #expect(view.rows < rows)

        #expect(view.performBindingAction("decrease_font_size"))
        #expect(view.theme.fontSize == 18)

        #expect(view.performBindingAction("reset_font_size"))
        #expect(view.theme.fontSize == 13)
        #expect(view.cellWidth == width)
        #expect(view.cellHeight == height)
        view.flushPendingResizeForTesting()
        #expect(view.cols == cols)
        #expect(view.rows == rows)
    }

    @Test func fontSizeIsClampedAndMalformedAmountsAreRefused() {
        let (view, window) = hostedSurface()
        defer { window.close() }

        view.changeFontSize(.decrease(100))
        #expect(view.theme.fontSize == Tako.SurfaceView.fontSizeRange.lowerBound)
        view.changeFontSize(.increase(1000))
        #expect(view.theme.fontSize == Tako.SurfaceView.fontSizeRange.upperBound)

        #expect(!view.performBindingAction("increase_font_size:lots"))
        #expect(!view.performBindingAction("decrease_font_size:0"))
        #expect(view.theme.fontSize == Tako.SurfaceView.fontSizeRange.upperBound)
    }

    @Test func aConfiguredCellSizeScalesWithTheFont() {
        let (view, window) = hostedSurface(theme: TerminalTheme(fontSize: 10, cellWidth: 8, cellHeight: 16))
        defer { window.close() }

        #expect(view.performBindingAction("increase_font_size:10"))
        #expect(view.cellWidth == 16)
        #expect(view.cellHeight == 32)
        #expect(view.performBindingAction("reset_font_size"))
        #expect(view.cellWidth == 8)
        #expect(view.cellHeight == 16)
    }

    /// A reloaded configuration is the new size a reset returns to.
    @Test func updatingTheThemeMovesTheResetPoint() {
        let (view, window) = hostedSurface()
        defer { window.close() }

        view.updateTheme(TerminalTheme(fontSize: 15))
        view.changeFontSize(.increase(3))
        #expect(view.theme.fontSize == 18)
        view.changeFontSize(.reset)
        #expect(view.theme.fontSize == 15)
    }
}

// MARK: - Reset

@Suite(.serialized)
@MainActor
struct SurfaceResetActionTests {
    @Test func resetClearsScreenScrollbackAndModesButKeepsTheThemeColors() {
        let (view, window) = hostedSurface()
        defer { window.close() }
        // Foreground and background of the bottom-right cell, which nothing
        // writes to.
        func blankColors() -> [UInt8] { Array(Array(view.core.viewportPacked().suffix(16))[4..<10]) }
        let blankBefore = blankColors()

        feedLines(view, count: 60, extra: [5: "reset-marker in history", 59: "reset-marker on screen"])
        #expect(view.core.scrollbackLen() > 0)
        view.core.feed(bytes: Data("\u{1b}[?1049halternate-marker\u{1b}[?1000h\u{1b}[?25l\u{1b}[?2004h".utf8))
        #expect(view.core.modes().alternateScreen)
        #expect(view.core.modes().mouseTracking != .off)
        #expect(view.core.modes().bracketedPaste)
        #expect(!view.core.cursorVisible())

        #expect(view.performBindingAction("reset"))

        let text = view.core.bufferText()
        #expect(!text.contains("reset-marker"))
        #expect(!text.contains("alternate-marker"))
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(view.core.scrollbackLen() == 0)
        let modes = view.core.modes()
        #expect(!modes.alternateScreen)
        #expect(modes.mouseTracking == .off)
        #expect(!modes.bracketedPaste)
        #expect(view.core.cursorVisible())
        #expect(view.core.cursorRow() == 0)
        #expect(view.core.cursorCol() == 0)
        // The blank cell is drawn in the theme's colors, not the engine's
        // built-in ones.
        #expect(blankColors() == blankBefore)
    }

    @Test func resetFromTheControllerMenuItemResetsTheFocusedSurface() {
        let (view, window) = hostedSurface()
        defer { window.close() }
        let controller = BaseTerminalController(Tako.App(), surfaceTree: .init(view: view))
        controller.focusedSurface = view
        view.core.feed(bytes: Data("controller-reset-marker".utf8))

        #expect(controller.validateMenuItem(menuItem(#selector(BaseTerminalController.resetTerminal(_:)))))
        controller.resetTerminal(self)

        #expect(!view.core.bufferText().contains("controller-reset-marker"))
    }
}

// MARK: - Find

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

@Suite(.serialized)
@MainActor
struct SurfaceBindingActionTests {
    @Test func unsupportedActionsReportFailureAndTheirMenuItemIsDisabled() {
        let (view, window) = hostedSurface()
        defer { window.close() }

        for action in [
            "inspector:toggle", "toggle_tab_overview", "toggle_window_decorations",
            "show_gtk_inspector", "toggle_readonly", "resize_split:up,20", "no_such_action", "",
        ] {
            #expect(!view.performBindingAction(action), "\(action)")
            #expect(!Tako.SurfaceView.isBindingActionSupported(action), "\(action)")
        }
        // Known, but nothing implements it outside a terminal window.
        #expect(Tako.SurfaceView.isBindingActionSupported("equalize_splits"))
        #expect(!view.performBindingAction("equalize_splits"))

        let controller = BaseTerminalController(Tako.App(), surfaceTree: .init(view: view))
        controller.focusedSurface = view
        #expect(!controller.validateMenuItem(menuItem(#selector(BaseTerminalController.toggleTerminalInspector(_:)))))
        #expect(controller.validateMenuItem(menuItem(#selector(BaseTerminalController.increaseFontSize(_:)))))
        // Nothing in the responder chain takes the Read-only menu item's
        // action, so AppKit disables it.
        #expect(!view.responds(to: NSSelectorFromString("toggleReadonly:")))
        #expect(!controller.responds(to: NSSelectorFromString("toggleReadonly:")))
    }

    @Test func appleScriptPerformReportsTheRealOutcome() throws {
        let (view, window) = hostedSurface()
        defer { window.close() }
        let model = try #require(view.surfaceModel)

        #expect(model.perform(action: "increase_font_size:1"))
        #expect(view.theme.fontSize == 14)
        #expect(!model.perform(action: "inspector:toggle"))
    }

    @Test func controllerActionsGoToTheWindowsController() {
        let (view, window) = hostedSurface()
        defer { window.close() }
        let controller = BaseTerminalController(Tako.App(), surfaceTree: .init(view: view))
        controller.focusedSurface = view
        controller.window = window
        window.windowController = controller

        let log = NotificationLog(Tako.Notification.didEqualizeSplits, object: view)
        defer { log.stop() }

        #expect(view.performBindingAction("equalize_splits"))
        #expect(log.names == [Tako.Notification.didEqualizeSplits])
        // The menu's own amount only.
        #expect(!view.performBindingAction("resize_split:up,11"))

        // The command palette goes through the same dispatch.
        controller.performAction("increase_font_size:2", on: view)
        #expect(view.theme.fontSize == 15)
        controller.increaseFontSize(self)
        #expect(view.theme.fontSize == 16)
        controller.decreaseFontSize(self)
        controller.resetFontSize(self)
        #expect(view.theme.fontSize == 13)
    }

    @Test func textActionsWriteTheirBytesToTheShell() {
        let (view, window) = hostedSurface()
        defer { window.close() }
        view.selfTestCapturing = true
        defer { view.selfTestCapturing = false }

        func sent(_ action: String) -> String? {
            let before = view.selfTestBytes.count
            guard view.performBindingAction(action) else { return nil }
            return String(decoding: view.selfTestBytes[before...], as: UTF8.self)
        }
        #expect(sent("text:hi\\n") == "hi\n")
        #expect(sent("text:a\\tb\\r\\\\\\x41\\e") == "a\tb\r\\A\u{1b}")
        #expect(sent("text:with:colon") == "with:colon")
        #expect(sent("csi:2J") == "\u{1b}[2J")
        #expect(sent("esc:d") == "\u{1b}d")
        #expect(sent("text:\\q") == nil)
        #expect(sent("text:\\xZZ") == nil)
        #expect(sent("text") == nil)
    }

    @Test func scrollActionsMoveTheViewport() {
        let (view, window) = hostedSurface()
        defer { window.close() }
        feedLines(view, count: 200)
        let rows = view.rows

        #expect(view.performBindingAction("scroll_to_top"))
        #expect(view.viewportOffset == view.scrollbackLength)
        #expect(view.performBindingAction("scroll_to_bottom"))
        #expect(view.viewportOffset == 0)
        #expect(view.performBindingAction("scroll_page_up"))
        #expect(view.viewportOffset == rows)
        #expect(view.performBindingAction("scroll_page_lines:-3"))
        #expect(view.viewportOffset == rows + 3)
        #expect(view.performBindingAction("scroll_page_lines:2"))
        #expect(view.viewportOffset == rows + 1)
        #expect(view.performBindingAction("scroll_page_down"))
        #expect(view.viewportOffset == 1)
        #expect(!view.performBindingAction("scroll_page_lines:0"))
        #expect(!view.performBindingAction("scroll_page_lines"))
    }

    @Test func clipboardSelectionAndClearActions() {
        let (view, window) = hostedSurface()
        defer { window.close() }
        view.core.feed(bytes: Data("clear-marker".utf8))

        #expect(!view.performBindingAction("copy_to_clipboard"))
        #expect(view.performBindingAction("select_all"))
        #expect(view.core.hasSelection())
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        #expect(view.performBindingAction("copy_to_clipboard"))
        #expect(NSPasteboard.general.string(forType: .string)?.contains("clear-marker") == true)
        #expect(view.performBindingAction("paste_from_clipboard"))
        NSPasteboard.general.clearContents()
        #expect(!view.performBindingAction("paste_from_clipboard"))

        #expect(view.performBindingAction("clear_screen"))
        #expect(!view.core.bufferText().contains("clear-marker"))
    }
}
