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
import CoreGraphics
import Darwin
import Foundation
import TakoKit
import Testing
@testable import Tako

@MainActor
extension SurfaceViewCoverageTests {
    @Test func pasteWritesTheGeneralPasteboardStringToTheShell() {
        withSavedGeneralPasteboard {
            let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            defer { view.close() }

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("pasted-from-general-pasteboard", forType: .string)
            view.paste(nil)

            #expect(waitUntil(timeout: 8) { view.visibleText.contains("pasted-from-general-pasteboard") })
        }
    }

    @Test func pasteWithAnEmptyPasteboardDoesNothing() {
        withSavedGeneralPasteboard {
            let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            defer { view.close() }
            NSPasteboard.general.clearContents()
            let before = view.visibleText

            view.paste(nil)

            // `guard let text = ... else { return }` returns before touching
            // the pty at all, synchronously, so the grid is unchanged.
            #expect(view.visibleText == before)
        }
    }

    @Test func pasteTextEncodesAndWritesDirectly() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        view.pasteText("direct-paste-text-call\n")

        #expect(waitUntil(timeout: 8) { view.visibleText.contains("direct-paste-text-call") })
    }

    @Test func focusDidChangeUpdatesThePublishedFocusFlag() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        #expect(view.focused)
        view.focusDidChange(false)
        #expect(!view.focused)
        view.focusDidChange(true)
        #expect(view.focused)
    }

    @Test func updateThemeReplacesTheInheritedTheme() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        var theme = TerminalTheme()
        theme.background = CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)

        view.updateTheme(theme)

        #expect(view.theme.background == theme.background)
    }

    /// A surface places the IME's marked text and a link's underline where
    /// the renderer draws the cell: top-anchored below the padding, the
    /// inverse of cellAt. It used to count rows up from the bottom, which put
    /// them a row and a half away from the text.
    @Test func cellOriginIsWhereTheCellIsDrawn() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        let layout = view.gridLayout
        let origin = view.cellOrigin(row: 1, col: 2)
        #expect(origin.x == layout.left + 2 * view.cellWidth)
        #expect(abs(origin.y - (view.bounds.height - layout.top - 2 * view.cellHeight)) < 0.001)
        let hit = view.cellAt(NSPoint(x: origin.x + 1, y: origin.y + view.cellHeight / 2))
        #expect(hit.row == 1)
        #expect(hit.col == 2)
    }

    @Test func toggleReadonlyFlipsBothWays() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        #expect(!view.readonly)
        view.toggleReadonly(nil)
        #expect(view.readonly)
        view.toggleReadonly(nil)
        #expect(!view.readonly)
    }

    @Test func unknownBindingActionsReportFailure() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        #expect(view.performBindingAction("whatever") == false)
        view.highlight()
    }

    @Test func closeTerminatesThePtyAndEventuallyReportsProcessExited() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.close()
        #expect(waitUntil { view.processExited })
    }

    @Test func encodeThenDecodeKeepsTheIdentityWithANewShell() throws {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        let data = try JSONEncoder().encode(view)
        let decoded = try JSONDecoder().decode(Tako.SurfaceView.self, from: data)
        defer { decoded.close() }

        #expect(decoded.restoredID == String(describing: view.id))
        // The identity carries over, so a restored window refocuses the right
        // pane and finds its saved screen; the PTY is a new one.
        #expect(decoded.id == view.id)
        #expect(decoded !== view)
    }

    @Test func requiredCoderInitAlwaysFails() {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.finishEncoding()
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archiver.encodedData) else {
            Issue.record("could not build an unarchiver")
            return
        }
        #expect(Tako.SurfaceView(coder: unarchiver) == nil)
    }

    @Test func cachedContentsRecomputeOnlyAfterInvalidation() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        view.core.feed(bytes: Data("cached-contents-marker".utf8))
        _ = view.core.takeOutput()

        let first = view.cachedVisibleContents.get()
        #expect(first.contains("cached-contents-marker"))
        #expect(view.cachedVisibleContents.get() == first)
        view.cachedVisibleContents.invalidate()
        // The surface runs a real login shell whose banner can land at any
        // moment, so after invalidation only require a fresh read of the
        // same screen, not byte equality with the cached one.
        #expect(view.cachedVisibleContents.get().contains("cached-contents-marker"))

        let fullScreen = view.cachedScreenContents.get()
        #expect(fullScreen.contains("cached-contents-marker"))
    }

    @Test func visibleTextJoinsEveryVisibleRow() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        view.core.feed(bytes: Data("visible-text-marker".utf8))
        _ = view.core.takeOutput()
        #expect(view.visibleText.contains("visible-text-marker"))
    }

    @Test func refreshSearchHitRowsReconcilesCurrentSearchMatch() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        view.core.feed(bytes: Data("alpha\r\nbeta\r\ngamma\r\n".utf8))
        _ = view.core.takeOutput()

        view.startSearch(needle: "alpha")
        view.runSearch("alpha")
        #expect(view.currentSearchMatch != nil)
        #expect(view.searchState?.total == 1)

        // Change search state needle to match multiple lines
        view.searchState?.needle = "a"
        view.refreshSearchHitRows()
        #expect(view.currentSearchMatch != nil)
        #expect((view.searchState?.total ?? 0) > 1)

        // Search for nonexistent string
        view.searchState?.needle = "nonexistent_string_xyz"
        view.refreshSearchHitRows()
        #expect(view.currentSearchMatch == nil)
        #expect(view.searchState?.total == 0)
    }

    @Test func writeToShellSplitsBetweenSelfTestCaptureAndTheRealPty() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        view.selfTestCapturing = true
        view.writeToShell([0x61, 0x62, 0x63])
        #expect(view.selfTestBytes == [0x61, 0x62, 0x63])
        view.selfTestCapturing = false

        view.writeToShell(Array("echo write-to-shell-real\n".utf8))
        #expect(waitUntil(timeout: 8) { view.visibleText.contains("write-to-shell-real") })
    }

    @Test func viewDidMoveToWindowInstallsTheTabBarControllerWithoutCrashing() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)

        window.contentView = view
        #expect(!view.isFirstResponderSurface)
        window.makeFirstResponder(view)
        #expect(view.isFirstResponderSurface)

        // Moving to a second window rebinds; removing from any window clears
        // the binding. Neither must crash.
        let otherWindow = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.contentView = view
        view.removeFromSuperview()
    }

    @Test func titleDidChangeMirrorsTheInheritedTitleAndClearsUserSetFlag() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        view.isUserSetTitle = true

        view.title = "a live title"

        #expect(view.titleText == "a live title")
        #expect(!view.isUserSetTitle)
    }
}

}
