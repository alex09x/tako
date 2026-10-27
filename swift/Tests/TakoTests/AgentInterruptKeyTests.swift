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

/// Escape or Ctrl-C in a pane whose agent's hooks say it works ends that
/// status: Claude Code and Antigravity fire no hook when stopped that way.
@Suite @MainActor
struct AgentInterruptKeyTests {
    private typealias Key = Tako.InterruptKeystroke

    @Test func escapeAndBareCtrlCInterruptAndNothingElseDoes() {
        #expect(Key.isInterrupt(keyCode: 53, character: "\u{1b}", modifiers: []))
        #expect(Key.isInterrupt(keyCode: 53, character: "\u{1b}", modifiers: [.shift]))
        #expect(Key.isInterrupt(keyCode: 8, character: "c", modifiers: [.control]))
        #expect(Key.isInterrupt(keyCode: 8, character: "C", modifiers: [.control]))
        // Caps Lock and the function key are not chords.
        #expect(Key.isInterrupt(keyCode: 8, character: "c", modifiers: [.control, .capsLock, .function]))
        #expect(!Key.isInterrupt(keyCode: 8, character: "c", modifiers: []))
        #expect(!Key.isInterrupt(keyCode: 8, character: "c", modifiers: [.command]))
        #expect(!Key.isInterrupt(keyCode: 8, character: "c", modifiers: [.control, .shift]))
        #expect(!Key.isInterrupt(keyCode: 8, character: "c", modifiers: [.control, .option]))
        #expect(!Key.isInterrupt(keyCode: 8, character: "c", modifiers: [.control, .command]))
        #expect(!Key.isInterrupt(keyCode: 2, character: "d", modifiers: [.control]))
        #expect(!Key.isInterrupt(keyCode: 36, character: "\r", modifiers: []))
    }

    @Test func ctrlCIsFoundOnARussianLayoutAndNotMistakenOnDvorak() {
        // Russian: the C key gives "с" (Cyrillic), its position decides.
        #expect(Key.isInterrupt(keyCode: 8, character: "с", modifiers: [.control]))
        #expect(Key.isInterrupt(keyCode: 8, character: nil, modifiers: [.control]))
        // Dvorak: C sits elsewhere and the C position gives "j" -- Ctrl-J is not a stop.
        #expect(Key.isInterrupt(keyCode: 34, character: "c", modifiers: [.control]))
        #expect(!Key.isInterrupt(keyCode: 8, character: "j", modifiers: [.control]))
    }

    @Test(arguments: [Tako.PaneStatus.working, .running, .needsApproval, .waitingForInput])
    func anAgentStoppedByTheKeyIsIdle(_ status: Tako.PaneStatus) {
        let crab = Tako.CrabTracker()
        crab.setStatus(status, text: "Thinking...")
        crab.progressReported(state: 3, value: nil)
        crab.userInterrupted()
        #expect(crab.paneStatus == .idle)
        #expect(crab.statusText == nil)
        #expect(crab.progressState == .none)
    }

    @Test(arguments: [Tako.PaneStatus.done, .error, .disconnected, .idle])
    func anOutcomeIsNotTakenBackByTheKey(_ status: Tako.PaneStatus) {
        let crab = Tako.CrabTracker()
        crab.setStatus(status, text: nil)
        crab.userInterrupted()
        #expect(crab.paneStatus == status)
    }

    @Test func aPaneNoAgentReportsOnIsLeftAlone() {
        let crab = Tako.CrabTracker()
        crab.userInterrupted()
        #expect(crab.paneStatus == .idle)
    }

    @Test func theNextHookAfterAFalseStopSetsWorkingAgain() {
        let crab = Tako.CrabTracker()
        crab.setStatus(.working, text: "Thinking...")
        crab.userInterrupted()
        crab.setStatus(.working, text: "Thinking...")
        #expect(crab.paneStatus == .working)
    }

    private func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    @Test func escapeTypedIntoThePaneEndsItsAgentsWorkingStatus() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        view.selfTestCapturing = true
        defer { view.close() }
        view.crab.setStatus(.working, text: "Thinking...")
        view.keyDown(with: key(0, "a"))
        #expect(view.crab.paneStatus == .working, "typing while it works keeps it working")
        view.keyDown(with: key(53, "\u{1b}"))
        #expect(view.crab.paneStatus == .idle)

        view.crab.setStatus(.working, text: "Thinking...")
        view.keyDown(with: key(8, "с", [.control]))
        #expect(view.crab.paneStatus == .idle, "Ctrl-C on the Russian layout")
    }
}
