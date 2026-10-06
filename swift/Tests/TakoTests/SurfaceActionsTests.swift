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

// The actions a surface carries out when a menu item, a keybinding, the
// command palette or AppleScript asks for them by name, and the ones it
// refuses. Each test hosts a real surface in an offscreen window.
//
// The surface starts a login shell like the app does. It is closed straight
// away: the tests feed the engine directly, and a prompt arriving part-way
// through would make what is on screen depend on the shell.

@MainActor
func settle(_ seconds: TimeInterval = 0.2) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

@MainActor
func hostedSurface(theme: TerminalTheme = TerminalTheme()) -> (Tako.SurfaceView, NSWindow) {
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
func menuItem(_ action: Selector) -> NSMenuItem {
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
func feedLines(_ view: Tako.SurfaceView, count: Int, extra: [Int: String] = [:]) {
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
