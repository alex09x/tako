import AppKit
import Foundation
import SwiftUI
import TakoKit
import Testing
@testable import Tako

// Coverage for swift/Sources/TakoApp/Features/ClipboardConfirmation:
// ClipboardConfirmationController (window lifecycle for each request kind)
// and ClipboardConfirmationView (hosted rendering, both buttons, and the
// cursor-unhide/rehide onAppear/onDisappear pair).

private final class RecordingClipboardDelegate: ClipboardConfirmationViewDelegate {
    var lastAction: ClipboardConfirmationView.Action?
    var lastRequest: Tako.ClipboardRequest?
    func clipboardConfirmationComplete(_ action: ClipboardConfirmationView.Action, _ request: Tako.ClipboardRequest) {
        lastAction = action
        lastRequest = request
    }
}

@MainActor
@Suite
struct ClipboardConfirmationControllerCoverageTests {
    @Test func windowNibNameIsClipboardConfirmation() {
        let delegate = RecordingClipboardDelegate()
        let controller = ClipboardConfirmationController(
            surface: tako_surface_t(), contents: "hi", request: .paste, state: nil, delegate: delegate)
        #expect(controller.windowNibName == "ClipboardConfirmation")
    }

    @Test(arguments: [
        (Tako.ClipboardRequest.paste, "Warning: Potentially Unsafe Paste"),
        (.osc_52_read, "Authorize Clipboard Access"),
        (.osc_52_write(nil), "Authorize Clipboard Access"),
    ])
    func windowDidLoadTitlesTheWindowPerRequestKind(request: Tako.ClipboardRequest, expectedTitle: String) {
        let delegate = RecordingClipboardDelegate()
        let controller = ClipboardConfirmationController(
            surface: tako_surface_t(), contents: "clipboard payload", request: request, state: nil, delegate: delegate)
        let window = makePanelWindow()
        controller.window = window
        controller.windowDidLoad()

        #expect(window.title == expectedTitle)
        #expect(window.contentView != nil)
        #expect(String(describing: type(of: window.contentView!)).contains("NSHostingView"))
    }
}

@Suite
@MainActor
struct ClipboardConfirmationViewCoverageTests {
    /// AX inspection and `.keyboardShortcut` dispatch are both unavailable
    /// in this bare-NSWindow harness (see PanelTestSupport.swift): the
    /// paste vs. osc-52 button titles are instead pinned directly by
    /// `actionTextCoversEveryActionRequestCombination` below, and this only
    /// proves the two request kinds actually render distinct pixels.
    @Test func pasteAndOscRequestsRenderDifferentPixels() {
        let window = makePanelWindow(size: NSSize(width: 480, height: 260))
        let hosting = hostPanel(
            ClipboardConfirmationView(contents: "rm -rf /tmp/marker", request: .paste, delegate: nil),
            in: window)
        hosting.layoutSubtreeIfNeeded()
        let pasteSnapshot = panelSnapshot(hosting)

        hosting.rootView = ClipboardConfirmationView(contents: "rm -rf /tmp/marker", request: .osc_52_read, delegate: nil)
        hosting.layoutSubtreeIfNeeded()
        let oscSnapshot = panelSnapshot(hosting)

        #expect(!panelBitmapsEqual(pasteSnapshot, oscSnapshot))
    }

    @Test func actionTextCoversEveryActionRequestCombination() {
        #expect(ClipboardConfirmationView.Action.text(.cancel, .paste) == "Cancel")
        #expect(ClipboardConfirmationView.Action.text(.cancel, .osc_52_read) == "Deny")
        #expect(ClipboardConfirmationView.Action.text(.cancel, .osc_52_write(nil)) == "Deny")
        #expect(ClipboardConfirmationView.Action.text(.confirm, .paste) == "Paste")
        #expect(ClipboardConfirmationView.Action.text(.confirm, .osc_52_read) == "Allow")
        #expect(ClipboardConfirmationView.Action.text(.confirm, .osc_52_write(nil)) == "Allow")
    }

    @Test func onAppearUnhidesAndOnDisappearRehidesTheCursor() {
        // Start from a known, fully-hidden baseline so the view's onAppear
        // branch (cursorHiddenCount == 0 -> explicit extra unhide) and its
        // onDisappear re-hide loop both run against a deterministic count.
        while !Cursor.isVisible { _ = Cursor.unhide() }
        Cursor.hide()
        Cursor.hide()
        #expect(!Cursor.isVisible)

        let window = makePanelWindow(size: NSSize(width: 480, height: 260))
        let controller = NSHostingController(
            rootView: ClipboardConfirmationView(contents: "payload", request: .paste, delegate: nil))
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        #expect(waitUntilPanel(timeout: 2) { Cursor.isVisible })

        window.contentViewController = nil
        window.close()
        #expect(waitUntilPanel(timeout: 2) { !Cursor.isVisible })

        // Restore a clean slate for any later test in this process.
        while !Cursor.isVisible { _ = Cursor.unhide() }
    }

    /// When the cursor was already visible on appear, `unhideCompletely()`
    /// returns 0, taking the extra explicit `Cursor.unhide()` branch that
    /// `onAppearUnhidesAndOnDisappearRehidesTheCursor` never reaches.
    @Test func onAppearWithAnAlreadyVisibleCursorTakesTheExtraUnhideBranch() {
        while !Cursor.isVisible { _ = Cursor.unhide() }
        #expect(Cursor.isVisible)

        let window = makePanelWindow(size: NSSize(width: 480, height: 260))
        window.contentViewController = NSHostingController(
            rootView: ClipboardConfirmationView(contents: "payload", request: .paste, delegate: nil))
        window.makeKeyAndOrderFront(nil)

        // Nothing to wait on observably beyond "still visible and did not
        // crash" -- the branch's own effect (an extra NSCursor.unhide() call
        // while already at zero) is intentionally a harmless no-op.
        #expect(waitUntilPanel(timeout: 2) { Cursor.isVisible })

        window.contentViewController = nil
        window.close()
        while !Cursor.isVisible { _ = Cursor.unhide() }
    }
}
