/*
 * tako — Native settings: menu shortcuts stop at the open panel
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation
import Testing
@testable import Tako

/// At the window's key-equivalent boundary, offscreen: what the window
/// claims never reaches the menu; what it declines does. No menu or owner
/// config is touched.
extension DesktopSettingsTests {
    /// A responder standing in for the terminal that had the keyboard.
    final class TerminalStandIn: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    func keyHost() -> (NSWindow, TerminalStandIn) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900))
        let terminal = TerminalStandIn(frame: content.bounds)
        content.addSubview(terminal)
        window.contentView = content
        window.makeFirstResponder(terminal)
        return (window, terminal)
    }

    func key(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    /// Cmd+D and Cmd+T are taken by the open Settings, so the menu's Split
    /// Right and New Tab never act on the terminal underneath; without
    /// Settings the window declines them and the menu would get them.
    @Test func terminalCommandsStopAtOpenSettings() throws {
        let sandbox = try Sandbox()
        let (window, _) = keyHost()
        defer { window.close() }
        let splitRight = try key("d", 2, .command, in: window), newTab = try key("t", 17, .command, in: window)
        #expect(!window.performKeyEquivalent(with: splitRight), "control: nothing claims Cmd+D without Settings")
        let controller = try #require(DesktopSettingsController.show(in: window, section: .general, configPath: sandbox.config.path))
        defer { controller.close() }
        #expect(window.performKeyEquivalent(with: splitRight))
        #expect(window.performKeyEquivalent(with: newTab))
        #expect(DesktopSettingsController.current(in: window) === controller, "a contained shortcut leaves Settings open")
    }

    /// Editing and the app's own commands go on to the menu (the window
    /// declines them); Control or Option alone are left to the field.
    @Test func editingAndAppCommandsStillReachTheMenu() throws {
        let sandbox = try Sandbox()
        let (window, _) = keyHost()
        defer { window.close() }
        let controller = try #require(DesktopSettingsController.show(in: window, section: .general, configPath: sandbox.config.path))
        defer { controller.close() }
        let passing: [(String, UInt16, NSEvent.ModifierFlags)] = [
            ("a", 0, .command), ("c", 8, .command), ("x", 7, .command), ("v", 9, .command), ("z", 6, .command),
            ("z", 6, [.command, .shift]), ("q", 12, .command), ("h", 4, .command), ("h", 4, [.command, .option]),
            ("m", 46, .command), (",", 43, .command), ("f", 3, .control), ("b", 11, .option)]
        for (character, code, flags) in passing {
            #expect(!window.performKeyEquivalent(with: try key(character, code, flags, in: window)), "\(flags) \(character)")
        }
        // A Cyrillic layout still copies: the key code decides, not the letter.
        #expect(!window.performKeyEquivalent(with: try key("с", 8, .command, in: window)))
        #expect(DesktopSettingsController.current(in: window) === controller)
    }

    /// Cmd+W closes Settings and gives the keyboard back to the terminal;
    /// the window and its tab stay.
    @Test func commandWClosesOnlySettings() throws {
        let sandbox = try Sandbox()
        let (window, terminal) = keyHost()
        defer { window.close() }
        let controller = try #require(DesktopSettingsController.show(in: window, section: .general, configPath: sandbox.config.path))
        #expect(window.firstResponder !== terminal, "Settings took the keyboard")
        #expect(window.performKeyEquivalent(with: try key("w", 13, .command, in: window)))
        #expect(DesktopSettingsController.current(in: window) == nil)
        #expect(controller.overlay.superview == nil)
        #expect(window.firstResponder === terminal)
        #expect(terminal.superview != nil, "the terminal under Settings is still there")
        // With Settings gone, Cmd+W is the window's again.
        #expect(!window.performKeyEquivalent(with: try key("w", 13, .command, in: window)))
    }

    /// Recording still works with Settings containing shortcuts: a contained
    /// Cmd+D does not disturb it, and the recorder takes the chord itself.
    @Test func recordingStaysUsableWhileShortcutsAreContained() throws {
        let sandbox = try Sandbox()
        let (window, _) = keyHost()
        defer { window.close() }
        let controller = try #require(DesktopSettingsController.show(in: window, section: .keys, configPath: sandbox.config.path))
        defer { controller.close() }
        let recorder = controller.model.recorder
        recorder.begin("new_tab", installMonitor: false)
        #expect(window.performKeyEquivalent(with: try key("d", 2, .command, in: window)))
        #expect(recorder.state == .recording(action: "new_tab"))
        recorder.handle(keyCode: 2, modifiers: [.command])
        guard case .conflict(let action, _, let holder) = recorder.state else {
            Issue.record("expected the Cmd+D conflict, got \(recorder.state)"); return
        }
        #expect(action == "new_tab" && holder.id == "new_split:right")
        recorder.cancel()
    }
}
