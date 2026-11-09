/*
 * tako — Desktop settings hosted tests: real text fields in a real window
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

/// Typing into the hosted SwiftUI fields of the settings window as a person
/// does: focus the field, select all, type, press Return.
@MainActor
@Suite(.serialized)
struct DesktopSettingsHostedTests {
    private func settle(_ seconds: TimeInterval = 0.15) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// What is mounted: DesktopViewMarker identifiers under `root` (the SwiftUI
    /// accessibility tree is not built without an accessibility client).
    private func markers(_ root: NSView) -> Set<String> {
        var out = Set<String>()
        func walk(_ v: NSView) {
            if v is DesktopViewMarker.Marker, let id = v.identifier?.rawValue { out.insert(id) }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out
    }

    private func axFind(_ identifier: String, in root: NSView) -> String? {
        markers(root).contains(identifier) ? identifier : nil
    }

    private func hostedWindow(_ size: NSSize = NSSize(width: 1200, height: 900)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(origin: .zero, size: size))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// The footer observes the stores itself: a refused size shows its error
    /// at once and the saved config stays; a level's first override (written
    /// outside the editor, as a context menu does) brings «Сбросить оформление».
    @Test func footerShowsARefusedValueAndTheResetButtonAsSoonAsTheyApply() throws {
        let sandbox = try DesktopSettingsTests.Sandbox()
        try "font-size = 13\n".write(to: sandbox.config, atomically: true, encoding: .utf8)
        let window = hostedWindow()
        defer { window.close() }
        let controller = try #require(DesktopSettingsController.show(in: window, section: .terminalAppearance,
                                                                     configPath: sandbox.config.path))
        settle()
        let panel = controller.overlay.panel
        #expect(axFind("DesktopSettingsError", in: panel) == nil)
        #expect(axFind("DesktopSettingsVersion", in: panel) != nil, "mounted: \(markers(panel).sorted())")

        var editable: [NSTextField] = []
        func collect(_ v: NSView) { if let f = v as? NSTextField, f.isEditable { editable.append(f) }; v.subviews.forEach(collect) }
        collect(panel)
        let field = try #require(editable.first { $0.stringValue == "13" })
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("73", replacementRange: editor.selectedRange())
        let returnKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(returnKey)
        settle()
        #expect(try String(contentsOf: sandbox.config, encoding: .utf8).contains("font-size = 13\n"), "73 is refused")
        #expect(axFind("DesktopSettingsError", in: panel) != nil, "the refusal is shown at once")
        controller.close()

        // A workspace level: the first override arrives from outside the editor.
        let store = sandbox.scopes()
        let ws = UUID()
        let context = ScopedAppearanceContext(scope: .workspace(ws), title: "workspace «W»", store: store,
                                              globalTheme: { .takoDefault })
        let scoped = try #require(DesktopSettingsController.show(in: window, section: .terminalAppearance,
                                                                 context: context, configPath: sandbox.config.path))
        defer { scoped.close() }
        settle()
        #expect(axFind("DesktopScopeResetAll", in: scoped.overlay.panel) == nil)
        try store.setValue("#123456", for: "background", scope: .workspace(ws))
        settle()
        #expect(axFind("DesktopScopeResetAll", in: scoped.overlay.panel) != nil, "the reset appears with the first override")
        try store.reset(.workspace(ws))
        settle()
        #expect(axFind("DesktopScopeResetAll", in: scoped.overlay.panel) == nil)
    }

    /// A field below the fold that takes keyboard focus (click or Tab)
    /// scrolls itself into the page's visible area.
    @Test func focusingAFieldBelowTheFoldScrollsItIntoView() throws {
        let sandbox = try DesktopSettingsTests.Sandbox()
        try "font-size = 13\n".write(to: sandbox.config, atomically: true, encoding: .utf8)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        let controller = try #require(DesktopSettingsController.show(in: window, section: .terminalAppearance,
                                                                     configPath: sandbox.config.path))
        defer { controller.close() }
        settle()
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        var editable: [NSTextField] = []
        func collect(_ v: NSView) { if let f = v as? NSTextField, f.isEditable { editable.append(f) }; v.subviews.forEach(collect) }
        collect(content)
        let field = try #require(editable.first { $0.stringValue == "13" })
        // The page's own scroll view, not the font list's.
        var scroll = field.enclosingScrollView
        while let s = scroll, s.frame.height < 200, let outer = s.superview?.enclosingScrollView { scroll = outer }
        let page = try #require(scroll)
        func visible() -> Bool {
            let rect = field.convert(field.bounds, to: page.contentView)
            return page.contentView.bounds.contains(rect)
        }
        #expect(!visible(), "precondition: the size field starts below the fold")
        let before = page.contentView.bounds.origin.y

        #expect(window.makeFirstResponder(field))
        settle(0.3)
        #expect(visible(), "the focused field is fully inside the page's visible area")
        #expect(page.contentView.bounds.origin.y != before, "the page scrolled")
    }

    @Test func fontSizeFieldTakesTypedFractionAndReturnCommitsIt() throws {
        let sandbox = try DesktopSettingsTests.Sandbox()
        try "font-family = Menlo\nfont-size = 13\n".write(to: sandbox.config, atomically: true, encoding: .utf8)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900))
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        let controller = try #require(DesktopSettingsController.show(in: window, section: .terminalAppearance,
                                                                     configPath: sandbox.config.path))
        defer { controller.close() }
        settle()
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        // SwiftUI keeps the identifier on its AX element; the AppKit field is
        // the editable one showing the current size.
        var editable: [NSTextField] = []
        func collect(_ v: NSView) { if let f = v as? NSTextField, f.isEditable { editable.append(f) }; v.subviews.forEach(collect) }
        collect(content)
        let field = try #require(editable.first { $0.stringValue == "13" }, "fields: \(editable.map(\.stringValue))")
        #expect(field.stringValue == "13")

        #expect(window.makeFirstResponder(field))
        settle(0.05)
        let editor = try #require(window.firstResponder as? NSTextView, "typing goes to the field editor")
        editor.selectAll(nil)
        editor.insertText("13.5", replacementRange: editor.selectedRange())
        settle(0.05)
        #expect(field.stringValue == "13.5", "typed text stays in the field before Return")
        let returnKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(returnKey)
        settle()

        let config = try String(contentsOf: sandbox.config, encoding: .utf8)
        #expect(config.contains("font-size = 13.5"), "Return writes the fraction:\n\(config)")
        #expect(controller.model.scope.effectiveValue("font-size") == "13.5")
        #expect(field.stringValue == "13.5", "after Return the field shows the saved value, got \(field.stringValue)")
    }
}
