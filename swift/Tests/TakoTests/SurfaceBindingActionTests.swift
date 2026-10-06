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
