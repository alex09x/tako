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

/// The workspace pill's list: a pick switches at once and the list is gone
/// in the same moment -- no blink, no fade.
@Suite(.serialized) @MainActor
struct WorkspacePickerTests {
    private final class Picks { var all: [String] = [] }

    private func parent() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func rows(_ picks: Picks) -> [Tako.WorkspacePicker.Row] {
        [Tako.WorkspacePicker.Row(title: "Default", color: .systemTeal, isCurrent: true, action: { picks.all.append("Default") }),
         Tako.WorkspacePicker.Row(title: "Legal", color: .systemPurple, attention: 2, action: { picks.all.append("Legal") }),
         Tako.WorkspacePicker.Row(title: "New Workspace...", color: nil, action: { picks.all.append("new") })]
    }

    private func key(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    @Test func itListsTheWorkspacesAsMenuItemsUnderThePill() {
        let window = parent()
        defer { window.close() }
        let picks = Picks()
        let anchor = NSRect(x: 220, y: 560, width: 90, height: 22)
        let picker = Tako.WorkspacePicker.show(rows: rows(picks), below: anchor, in: window)
        defer { picker.dismiss() }
        #expect(picker.rowViews.map { $0.accessibilityTitle() } == ["Default", "Legal (2)", "New Workspace..."])
        #expect(picker.rowViews.allSatisfy { $0.accessibilityRole() == .menuItem })
        #expect(picker.rowViews.first?.accessibilityValue() as? String == "current")
        #expect(abs(picker.frame.maxY - (anchor.minY - 4)) < 0.5 && abs(picker.frame.minX - anchor.minX) < 0.5, "under the pill")
        #expect(picker.animationBehavior == .none)
        #expect(!picker.canBecomeKey, "it never takes the key window from the one it opened in")
        #expect(Tako.WorkspacePicker.shown === picker)
    }

    @Test func aPickRunsItsActionWithTheListAlreadyGone() {
        let window = parent()
        defer { window.close() }
        let picks = Picks()
        var listUpWhenPicked: Bool?
        var rowsWithCheck = rows(picks)
        let legal = rowsWithCheck[1].action
        rowsWithCheck[1].action = { listUpWhenPicked = Tako.WorkspacePicker.shown != nil; legal() }
        let picker = Tako.WorkspacePicker.show(rows: rowsWithCheck, below: .zero, in: window)
        #expect(picker.rowViews[1].accessibilityPerformPress())
        #expect(picks.all == ["Legal"])
        #expect(listUpWhenPicked == false)
        #expect(!picker.isVisible)
        #expect(Tako.WorkspacePicker.shown == nil)
        picker.choose(0)
        #expect(picks.all == ["Legal"], "a list that is gone picks nothing more")
    }

    @Test func theKeyboardMovesPicksAndCloses() {
        let window = parent()
        defer { window.close() }
        let picks = Picks()
        let picker = Tako.WorkspacePicker.show(rows: rows(picks), below: .zero, in: window)
        #expect(picker.handle(key(125)))      // down
        #expect(picker.highlighted == 0)
        #expect(picker.handle(key(125)))
        #expect(picker.highlighted == 1)
        #expect(picker.handle(key(126)))      // up
        #expect(picker.highlighted == 0)
        #expect(picker.handle(key(126)))      // wraps to the last
        #expect(picker.highlighted == 2)
        #expect(!picker.handle(key(0)), "other keys go on to the terminal")
        #expect(picker.handle(key(36)))       // return
        #expect(picks.all == ["new"])

        let again = Tako.WorkspacePicker.show(rows: rows(picks), below: .zero, in: window)
        #expect(again.handle(key(53)))        // escape
        #expect(!again.isVisible)
        #expect(picks.all == ["new"])
    }

    @Test func aClickOnItsPillOnlyCloses() {
        let window = parent()
        defer { window.close() }
        let anchor = NSRect(x: 220, y: 560, width: 90, height: 22)
        let picker = Tako.WorkspacePicker.show(rows: rows(Picks()), below: anchor, in: window)
        defer { picker.dismiss() }
        #expect(picker.closesOnly(clickAt: NSPoint(x: anchor.midX, y: anchor.midY)), "the pill would open it again")
        #expect(!picker.closesOnly(clickAt: NSPoint(x: anchor.maxX + 40, y: anchor.midY)), "a click elsewhere goes on")
    }

    @Test func oneListAtATime() {
        let window = parent()
        defer { window.close() }
        let picks = Picks()
        let first = Tako.WorkspacePicker.show(rows: rows(picks), below: .zero, in: window)
        let second = Tako.WorkspacePicker.show(rows: rows(picks), below: .zero, in: window)
        defer { second.dismiss() }
        #expect(!first.isVisible)
        #expect(Tako.WorkspacePicker.shown === second)
    }
}
