/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Testing
import Foundation
import AppKit
@testable import Tako

@MainActor
extension TabTitleEditorTests {
    @Test func handleMouseDownDoubleClickOnTabBeginsInlineEditingAsynchronously() async {
        guard let harness = TabTitleEditorHarness.make() else {
            Issue.record("Could not build a real native tab bar on this machine")
            return
        }
        defer { harness.tearDown() }

        guard let tabButton = harness.tabButton(for: harness.first), let buttonWindow = tabButton.window else {
            Issue.record("Expected a hosted tab button")
            return
        }
        let centerInView = NSPoint(x: tabButton.bounds.midX, y: tabButton.bounds.midY)
        let locationInWindow = tabButton.convert(centerInView, to: nil)

        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: buttonWindow.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 2,
            pressure: 1)

        guard let event else {
            Issue.record("Expected to synthesize a mouse event")
            return
        }

        let handled = harness.editor.handleMouseDown(event)
        #expect(handled)

        await waitAsync { findInjectedEditor(in: tabButton, owner: harness.editor) != nil }
        #expect(findInjectedEditor(in: tabButton, owner: harness.editor) != nil)
    }

    @Test func handleMouseDownIgnoresSingleClicks() {
        guard let harness = TabTitleEditorHarness.make() else {
            Issue.record("Could not build a real native tab bar on this machine")
            return
        }
        defer { harness.tearDown() }

        guard let tabButton = harness.tabButton(for: harness.first), let buttonWindow = tabButton.window else {
            Issue.record("Expected a hosted tab button")
            return
        }
        let locationInWindow = tabButton.convert(NSPoint(x: tabButton.bounds.midX, y: tabButton.bounds.midY), to: nil)

        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: buttonWindow.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1)

        guard let event else {
            Issue.record("Expected to synthesize a mouse event")
            return
        }
        #expect(!harness.editor.handleMouseDown(event))
    }

    @Test func handleMouseDownIgnoresNonLeftMouseDownEvents() {
        guard let harness = TabTitleEditorHarness.make() else {
            Issue.record("Could not build a real native tab bar on this machine")
            return
        }
        defer { harness.tearDown() }

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.first.windowNumber,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0)

        guard let event else {
            Issue.record("Expected to synthesize a key event")
            return
        }
        #expect(!harness.editor.handleMouseDown(event))
    }

    @Test func handleRightMouseDownReturnsFalseWithoutActiveEditor() {
        guard let harness = TabTitleEditorHarness.make() else {
            Issue.record("Could not build a real native tab bar on this machine")
            return
        }
        defer { harness.tearDown() }

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.first.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1)
        guard let event else {
            Issue.record("Expected to synthesize a mouse event")
            return
        }
        #expect(!harness.editor.handleRightMouseDown(event))
    }

    @Test func handleRightMouseDownIgnoresNonRightMouseDownEvents() {
        guard let harness = TabTitleEditorHarness.make() else {
            Issue.record("Could not build a real native tab bar on this machine")
            return
        }
        defer { harness.tearDown() }

        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.first.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1)
        guard let event else {
            Issue.record("Expected to synthesize a mouse event")
            return
        }
        #expect(!harness.editor.handleRightMouseDown(event))
    }

    @Test func finishEditingWithoutActiveEditorIsANoOp() {
        guard let harness = TabTitleEditorHarness.make() else {
            Issue.record("Could not build a real native tab bar on this machine")
            return
        }
        defer { harness.tearDown() }

        harness.editor.finishEditing(commit: true)
        #expect(harness.delegate.committedTitle == nil)
        #expect(harness.delegate.finishedWindows.isEmpty)
    }
}
