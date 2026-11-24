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
        // A Cyrillic layout still copies and opens Settings: the key code
        // decides, not the letter ("с" on C, "б" on the comma key).
        #expect(!window.performKeyEquivalent(with: try key("с", 8, .command, in: window)))
        #expect(!window.performKeyEquivalent(with: try key("б", 43, .command, in: window)))
        #expect(DesktopSettingsController.current(in: window) === controller)
    }

    /// A Command key event as AppKit delivers it without a menu: offered as
    /// a key equivalent first, then, unclaimed, to the first responder.
    func deliver(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags, in window: NSWindow) throws {
        let event = try key(characters, keyCode, flags, in: window)
        if !window.performKeyEquivalent(with: event) { window.firstResponder?.keyDown(with: event) }
    }

    /// Cmd+Left/Right (also with Shift) and Cmd+Delete edit a focused text
    /// view in Settings exactly as they do in a bare window: Settings claims
    /// terminal shortcuts, not the editor's own line editing. Measured by the
    /// caret, the selection and the text, not by a Bool.
    @Test func lineEditingKeysReachAFocusedEditorInSettings() throws {
        let sandbox = try Sandbox()
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!), right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        let arrow: NSEvent.ModifierFlags = [.command, .numericPad, .function]
        func edit(in window: NSWindow, parent: NSView) throws -> [String] {
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
            parent.addSubview(editor)
            editor.string = "alpha beta"
            #expect(window.makeFirstResponder(editor))
            var seen: [String] = []
            editor.setSelectedRange(NSRange(location: 5, length: 0))
            try deliver(left, 123, arrow, in: window)
            seen.append("left \(editor.selectedRange().location)")
            try deliver(right, 124, arrow, in: window)
            seen.append("right \(editor.selectedRange().location)")
            editor.setSelectedRange(NSRange(location: 6, length: 0))
            try deliver(right, 124, arrow.union(.shift), in: window)
            seen.append("shift-right \(editor.selectedRange().location)+\(editor.selectedRange().length)")
            editor.setSelectedRange(NSRange(location: 6, length: 0))
            try deliver("\u{7f}", 51, .command, in: window)
            seen.append("delete \(editor.string.debugDescription)")
            return seen
        }
        let (bare, _) = keyHost()
        defer { bare.close() }
        let baseline = try edit(in: bare, parent: try #require(bare.contentView))
        #expect(baseline == ["left 0", "right 10", "shift-right 6+4", "delete \"beta\""], "AppKit's own line editing")

        let (window, _) = keyHost()
        defer { window.close() }
        let controller = try #require(DesktopSettingsController.show(in: window, section: .general, configPath: sandbox.config.path))
        defer { controller.close() }
        let inside = try edit(in: window, parent: controller.overlay.panel)
        #expect(inside == baseline, "inside open Settings \(inside), bare window \(baseline)")
        // With the editor focused, terminal shortcuts are still contained, and
        // an arrow is the editor's only while the editor has the keyboard.
        #expect(window.performKeyEquivalent(with: try key("d", 2, .command, in: window)))
        window.makeFirstResponder(controller.overlay)
        #expect(window.performKeyEquivalent(with: try key(left, 123, arrow, in: window)), "no field focused: contained")
    }

    /// Stands in for a menu command a user bound to Cmd+Left.
    final class MenuSpy: NSObject {
        var fired = 0
        @objc func newTab(_ sender: Any?) { fired += 1 }
    }

    /// AppKit's order for a Command key: the window's key equivalents, then
    /// the menu (here a private one, never the app's), then the first responder.
    func deliver(_ event: NSEvent, in window: NSWindow, menu: NSMenu) {
        if window.performKeyEquivalent(with: event) { return }
        if menu.performKeyEquivalent(with: event) { return }
        window.firstResponder?.keyDown(with: event)
    }

    /// A menu shortcut on a line-editing chord (a user can bind Cmd+Left to
    /// New Tab) does not fire over a focused Settings field, whose caret
    /// moves instead; in a bare window the same menu does fire.
    @Test func aMenuShortcutOnALineEditingChordStaysOutOfAFocusedSettingsField() throws {
        let sandbox = try Sandbox()
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let arrow: NSEvent.ModifierFlags = [.command, .numericPad, .function]
        let spy = MenuSpy(), menu = NSMenu()
        let item = NSMenuItem(title: "New Tab", action: #selector(MenuSpy.newTab(_:)), keyEquivalent: left)
        item.keyEquivalentModifierMask = .command
        item.target = spy
        menu.addItem(item)

        let (bare, _) = keyHost()
        defer { bare.close() }
        deliver(try key(left, 123, arrow, in: bare), in: bare, menu: menu)
        #expect(spy.fired == 1, "control: the private menu takes Cmd+Left in a bare window")

        let (window, _) = keyHost()
        defer { window.close() }
        let controller = try #require(DesktopSettingsController.show(in: window, section: .general, configPath: sandbox.config.path))
        defer { controller.close() }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        controller.overlay.panel.addSubview(editor)
        editor.string = "alpha beta"
        #expect(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        deliver(try key(left, 123, arrow, in: window), in: window, menu: menu)
        #expect(spy.fired == 1, "the menu shortcut did not fire over the focused field")
        #expect(editor.selectedRange().location == 0, "the field moved its caret instead")
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
