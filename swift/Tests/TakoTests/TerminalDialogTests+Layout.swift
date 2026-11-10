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
import Testing
@testable import Tako

/// The desktop card's own layout: its look, the body wrapped to the card's
/// real width, and the field of a text question kept clear of the buttons.
extension TerminalDialogTests {
    /// The card is a desktop sheet, not a box of terminal cells: its corners
    /// are rounded (the corner pixel is the dimmed backdrop, not the panel),
    /// its middle is the shell’s opaque panel, and the buttons are desktop
    /// buttons inside it.
    @Test func theCardIsARoundedPanelInTheShellsColours() async throws {
        let window = window()
        let asked = Task { await TerminalDialogView.ask(in: window, title: "Close Terminal?",
                                                        message: "A process is running.", confirm: "Close",
                                                        theme: nil) }
        while TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        let dialog = TerminalDialogView.pending(in: window)!
        dialog.layoutSubtreeIfNeeded()
        let bitmap = try #require(dialog.bitmapImageRepForCachingDisplay(in: dialog.bounds))
        dialog.cacheDisplay(in: dialog.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / dialog.bounds.width
        func pixel(_ point: NSPoint) -> NSColor? {
            bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB)
        }
        func close(_ a: NSColor?, _ b: NSColor) -> Bool {
            guard let a, let b = b.usingColorSpace(.sRGB) else { return false }
            return abs(a.redComponent - b.redComponent) < 0.08 && abs(a.greenComponent - b.greenComponent) < 0.08
                && abs(a.blueComponent - b.blueComponent) < 0.08
        }
        let card = dialog.cardRect, panel = TerminalDialogView.Palette.card
        #expect(close(pixel(NSPoint(x: card.midX, y: card.maxY - 8)), panel), "the panel’s own colour")
        #expect((pixel(NSPoint(x: card.minX + 1, y: card.minY + 1))?.alphaComponent ?? 1) < 0.9, "a square corner")
        #expect((pixel(NSPoint(x: card.midX, y: card.midY))?.alphaComponent ?? 0) > 0.99, "the panel is opaque")
                let button = try #require(dialog.buttons.last)
        #expect(button.frame.height == TerminalDialogView.buttonHeight)
        #expect(card.width >= TerminalDialogView.minimumWidth)
        #expect(card.contains(button.frame))
        dialog.withdraw()
        _ = await asked.value
    }

    /// Callers wrap by character count; in a proportional font and a narrow
    /// window that bounds nothing. The card wraps again to its real width:
    /// nothing is drawn outside it, no character is lost, and what does not
    /// fit is reached by scrolling.
    @Test func aNarrowWindowWrapsWideTextInsideTheCardAndKeepsAllOfIt() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let wide = String(repeating: "W", count: 56)
        var lines = TUIText.plain(wide, width: 56)
        lines.append(TUIText.Line(indent: 2, runs: [.init(text: "see ", kind: .plain), .init(text: "/a/very/long/path/" + wide, kind: .code),
                                                     .init(text: " and then some more words to wrap around", kind: .bold)]))
        lines += (1...40).map { TUIText.Line(runs: [.init(text: "line \($0)", kind: .plain)]) }
        let asked = Task { await TerminalDialogView.choose(in: window, title: "Notes", lines: lines,
                                                           choices: [.init(title: "OK", kind: .primary)],
                                                           cancelIndex: 0, theme: nil) }
        while TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        let dialog = TerminalDialogView.pending(in: window)!
        dialog.layoutSubtreeIfNeeded()

        let card = dialog.cardRect, layout = dialog.bodyLayout
        #expect(card.minX >= 0 && card.maxX <= 640 && card.maxY <= 400, "the card left its window")
        let left = dialog.bodyOrigin(row: 0).x
        for row in layout.rows {
            #expect(left + dialog.width(of: row) <= card.maxX - TerminalDialogView.padding, "a row runs past the card")
        }
        #expect(layout.rows.count > lines.count, "the wide lines were not wrapped")
        func text(_ lines: [TUIText.Line]) -> String { lines.flatMap(\.runs).map(\.text).joined() }
        #expect(text(layout.rows) == text(lines), "wrapping lost or changed text")
        #expect(layout.rows[layout.starts[1]].runs.first?.kind == .plain && layout.rows[layout.starts[1]].indent == 2)
        #expect(layout.rows.flatMap(\.runs).contains { $0.kind == .code } && layout.rows.flatMap(\.runs).contains { $0.kind == .bold })

        // The whole body is reachable: End shows the last row, Home the first.
        #expect(dialog.maxOffset > 0)
        dialog.keyDown(with: key(119))
        #expect(dialog.scrollOffset == dialog.maxOffset)
        #expect(dialog.scrollOffset + dialog.visibleRows == layout.rows.count)
        dialog.keyDown(with: key(115))
        #expect(dialog.scrollOffset == 0)
        // What takoctl and VoiceOver read is the caller's text, unwrapped.
        #expect(dialog.accessibilityValue() as? String == lines.map { String(repeating: " ", count: $0.indent) + $0.runs.map(\.text).joined() }.joined(separator: "\n"))
        dialog.withdraw()
        _ = await asked.value
    }

    /// The field of a text question stays on its own row, inside the card,
    /// when the label above it wraps.
    @Test func theTextFieldFollowsAWrappedLabelAndStaysInsideTheCard() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 400))
        let label = "A label that is far too long for a narrow window and therefore has to wrap onto more rows"
        let asked = Task { await TerminalDialogView.askText(in: window, title: "Rename", label: label,
                                                            value: "old", hint: nil, confirm: "Save", theme: nil) }
        while TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        let dialog = TerminalDialogView.pending(in: window)!
        dialog.layoutSubtreeIfNeeded()
        let field = dialog.field!, layout = dialog.bodyLayout, card = dialog.cardRect
        #expect(layout.starts[1] > 1, "the label did not wrap")
        #expect(field.frame.minY >= dialog.bodyOrigin(row: dialog.visibleRows).y, "the field sits on the label")
        #expect(card.contains(field.frame))
        field.stringValue = "new"
        #expect(dialog.press("Save"))
        #expect(await asked.value == "new")
    }

    /// In a short window a long label scrolls; the field keeps its slot
    /// between the body and the buttons, never over them, at any size --
    /// so a click on Cancel or Save reaches the button, and the whole label
    /// stays reachable.
    @Test func aLongLabelInAShortWindowNeverPutsTheFieldOverTheButtons() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        window.contentView = content
        let label = String(repeating: "W", count: 115)
        let asked = Task { await TerminalDialogView.askText(in: window, title: "Rename", label: label,
                                                            value: "old", hint: "Empty gives the title back.",
                                                            confirm: "Save", theme: nil) }
        while TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        let dialog = TerminalDialogView.pending(in: window)!

        func check(_ size: NSSize, _ label: Comment) {
            content.setFrameSize(size)
            dialog.frame = content.bounds
            dialog.layoutSubtreeIfNeeded()
            let field = dialog.field!, card = dialog.cardRect
            #expect(card.contains(field.frame), label)
            #expect(field.frame.minY >= dialog.bodyOrigin(row: dialog.visibleRows).y, label)
            for button in dialog.buttons {
                #expect(!field.frame.intersects(button.frame), "the field covers \(button.title): \(label)")
                let center = dialog.convert(NSPoint(x: button.frame.midX, y: button.frame.midY), to: content)
                #expect(dialog.hitTest(center) === button, "a click on \(button.title) misses it: \(label)")
            }
            // The whole label is reachable: End shows its last row, Home its first.
            dialog.keyDown(with: key(119))
            #expect(dialog.scrollOffset + dialog.visibleRows == dialog.bodyLayout.rows.count, label)
            dialog.keyDown(with: key(115))
            #expect(dialog.scrollOffset == 0, label)
        }
        check(NSSize(width: 420, height: 240), "420x240")
        #expect(dialog.bodyLayout.rows.count > dialog.visibleRows, "the label does not scroll at 420x240")
        check(NSSize(width: 420, height: 160), "420x160")
        check(NSSize(width: 300, height: 600), "300x600")
        check(NSSize(width: 900, height: 240), "900x240")
        #expect(dialog.field?.stringValue == "old")
        #expect(dialog.press("Save"))
        #expect(await asked.value == "old")
    }
}
