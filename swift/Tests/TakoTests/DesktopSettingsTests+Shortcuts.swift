/*
 * tako — Desktop settings tests: the shortcut recorder and its window lifecycle
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

extension DesktopSettingsTests {
    @Test func recorderEscapeCancelsAndConflictNeedsExplicitReassign() throws {
        let sandbox = try Sandbox()
        let file = KeybindConfigFile(configPath: sandbox.config.path)
        let recorder = DesktopShortcutRecorder(configFile: file)

        recorder.begin("new_window", installMonitor: false)
        #expect(recorder.handle(keyCode: 53, modifiers: []))
        #expect(recorder.state == .idle)
        #expect(file.customOverrides.isEmpty)

        recorder.begin("new_window", installMonitor: false)
        #expect(recorder.handle(keyCode: 40, modifiers: []))
        #expect(recorder.lastError != nil)
        #expect(recorder.state == .recording(action: "new_window"))
        recorder.handle(keyCode: 40, modifiers: [.control, .option])
        #expect(recorder.state == .idle)
        #expect(file.customOverrides["new_window"] == "ctrl+opt+k")

        recorder.begin("new_tab", installMonitor: false)
        recorder.handle(keyCode: 40, modifiers: [.control, .option])
        guard case .conflict(_, let trigger, let holder) = recorder.state else {
            Issue.record("expected conflict, got \(recorder.state)"); return
        }
        #expect(trigger == "ctrl+opt+k" && holder.id == "new_window")
        recorder.cancel()
        #expect(file.customOverrides["new_window"] == "ctrl+opt+k")
        #expect(file.customOverrides["new_tab"] == nil)

        recorder.begin("new_tab", installMonitor: false)
        recorder.handle(keyCode: 40, modifiers: [.control, .option])
        recorder.confirmReassign()
        #expect(file.customOverrides["new_tab"] == "ctrl+opt+k")
        #expect(file.customOverrides["new_window"] == nil)
        #expect(recorder.isCustom("new_tab"))

        #expect(recorder.reset("new_tab"))
        #expect(!recorder.isCustom("new_tab"))
        recorder.begin("new_window", installMonitor: false)
        recorder.handle(keyCode: 40, modifiers: [.control, .option])
        #expect(recorder.resetAll())
        #expect(file.customOverrides.isEmpty)
    }

    /// Reference keys: ⌫ returns the default; in a conflict Enter reassigns
    /// and Esc cancels; every outcome is written to the status line.
    @Test func recorderBackspaceResetsAndConflictTakesEnterOrEscape() throws {
        let sandbox = try Sandbox()
        let file = KeybindConfigFile(configPath: sandbox.config.path)
        let recorder = DesktopShortcutRecorder(configFile: file)
        recorder.begin("new_window", installMonitor: false)
        recorder.handle(keyCode: 40, modifiers: [.control, .option])
        #expect(file.customOverrides["new_window"] == "ctrl+opt+k")

        recorder.begin("new_window", installMonitor: false)
        #expect(recorder.handle(keyCode: 51, modifiers: []))
        #expect(recorder.state == .idle && file.customOverrides["new_window"] == nil)
        #expect(recorder.status?.contains("Restored the default") == true)

        // ⇧⌘D belongs to «Разделить вниз» by default.
        recorder.begin("new_split:right", installMonitor: false)
        recorder.handle(keyCode: 2, modifiers: [.command, .shift])
        guard case .conflict(_, _, let holder) = recorder.state else { Issue.record("no conflict: \(recorder.state)"); return }
        #expect(holder.title == "Split Down")
        #expect(recorder.status?.contains("Enter to reassign") == true)
        #expect(recorder.handle(keyCode: 0, modifiers: []), "other keys are swallowed while asking")
        #expect(recorder.handle(keyCode: 53, modifiers: []))
        #expect(recorder.state == .idle && file.customOverrides.isEmpty)

        recorder.begin("new_split:right", installMonitor: false)
        recorder.handle(keyCode: 2, modifiers: [.command, .shift])
        #expect(recorder.handle(keyCode: 36, modifiers: []))
        #expect(recorder.state == .idle)
        #expect(file.customOverrides["new_split:right"] == "shift+cmd+d")
    }

    @Test func recorderDetectsConflictWithBuiltinDefault() throws {
        let sandbox = try Sandbox()
        let recorder = DesktopShortcutRecorder(configFile: KeybindConfigFile(configPath: sandbox.config.path))
        let copy = try #require(KeybindRegistry.defaultShortcut(for: "copy_to_clipboard"))
        #expect(DesktopKeysCopy.trigger(for: copy) == "cmd+c")
        recorder.begin("new_window", installMonitor: false)
        recorder.handle(keyCode: 8, modifiers: [.command])
        guard case .conflict(_, _, let holder) = recorder.state else {
            Issue.record("expected default conflict, got \(recorder.state)"); return
        }
        #expect(holder.id == "copy_to_clipboard")
        recorder.cancel()
        #expect(recorder.display(for: "copy_to_clipboard") == "⌘C")
    }

    /// Closing a host with its traffic light while a shortcut is being
    /// recorded closes its settings: the controller leaves `active`, the
    /// recorder is idle and its key monitor is gone, so another window's
    /// keys pass again. The other window's settings are untouched.
    @Test func closingTheHostWhileRecordingEndsItsSettingsAndKeyMonitor() throws {
        let sandbox = try Sandbox()
        func host() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900))
            return window
        }
        let first = host(), second = host()
        defer { second.close() }
        let closing = try #require(DesktopSettingsController.show(in: first, section: .keys, configPath: sandbox.config.path))
        let staying = try #require(DesktopSettingsController.show(in: second, section: .keys, configPath: sandbox.config.path))

        closing.model.recorder.begin("new_window")
        #expect(closing.model.recorder.isMonitoring)
        #expect(closing.model.recorder.state == .recording(action: "new_window"))

        first.close()
        #expect(DesktopSettingsController.current(in: first) == nil, "active no longer holds the closed host's settings")
        #expect(closing.model.recorder.state == .idle)
        #expect(!closing.model.recorder.isMonitoring, "no monitor left swallowing other windows' keys")
        #expect(closing.overlay.superview == nil)

        #expect(DesktopSettingsController.current(in: second) === staying)
        #expect(staying.overlay.superview != nil)
        // The second window's own recording still works and ends normally.
        staying.model.recorder.begin("new_tab")
        #expect(staying.model.recorder.isMonitoring)
        staying.close()
        #expect(!staying.model.recorder.isMonitoring)
    }
}
