/*
 * tako — Desktop Settings controls for private real-input scenarios
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import ApplicationServices
import AppKit

/// The desktop Settings Keys page, by real clicks and keys.
struct DesktopKeys {
    let d: Driver
    var config: String { (try? String(contentsOfFile: d.path("config"), encoding: .utf8)) ?? "" }

    /// The element whose identifier is exactly `id` (Driver.element also
    /// matches identifiers that merely contain it, and every row's Record
    /// button contains "DesktopShortcutRecord").
    func exact(_ id: String) -> AXUIElement? {
        d.windows().lazy.compactMap { find([id], under: $0, depth: 30) }.first
    }

    /// The first element under `root` whose identifier is exactly one of `ids`.
    func find(_ ids: Set<String>, under root: AXUIElement, depth: Int) -> AXUIElement? {
        if let id = d.attribute(root, "AXIdentifier") as String?, ids.contains(id) { return root }
        guard depth > 0 else { return nil }
        for child in (d.attribute(root, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            if let hit = find(ids, under: child, depth: depth - 1) { return hit }
        }
        return nil
    }

    /// The action's own Record or Reset control, looked up only inside its
    /// row (`DesktopShortcut-<action>`): an unselected row names it
    /// `DesktopShortcut<kind>-<action>`, the selected one plain
    /// `DesktopShortcut<kind>`, which is never taken from another row.
    func control(_ kind: String, of action: String) -> AXUIElement? {
        guard let row = exact("DesktopShortcut-\(action)") else { return nil }
        return find(["DesktopShortcut\(kind)-\(action)", "DesktopShortcut\(kind)"], under: row, depth: 12)
    }

    func clickControl(_ kind: String, of action: String) throws {
        try clickLaidOut("the \(kind) control of the \(action) row") { control(kind, of: action) }
    }

    func hasFrame(_ e: AXUIElement) -> Bool {
        (d.attribute(e, kAXPositionAttribute) as AXValue?) != nil && (d.attribute(e, kAXSizeAttribute) as AXValue?) != nil
    }

    /// Scrolls the control into view and clicks it once it has a frame:
    /// SwiftUI can report a control in the tree a moment before it is laid out.
    func clickLaidOut(_ what: String, _ find: () -> AXUIElement?) throws {
        guard d.wait(for: { find() != nil }, timeout: 5), let e = find() else { throw Failure("no \(what)") }
        AXUIElementPerformAction(e, "AXScrollToVisible" as CFString)
        guard d.wait(for: { find().map(hasFrame) == true }, timeout: 3), let laidOut = find() else {
            throw Failure("\(what) has no AX position/size")
        }
        usleep(300_000)
        print("click \(what)")
        try d.clickElement(find() ?? laidOut)
        usleep(300_000)
    }

    var isOpen: Bool { exact("DesktopSettingsRoot") != nil }

    func open() throws {
        d.key(Key.comma, .maskCommand)
        guard d.wait(for: { isOpen }, timeout: 5) else { throw Failure("Cmd+, did not open Settings (no DesktopSettingsRoot)") }
        SettingsPage(d).placeWindow()
    }

    /// The owned window holding Settings, moved to the top left of the
    /// display's visible frame and raised, and proved fully inside it, just
    /// before Close. A notification alert sits at the right of the test
    /// Mac's screen: at SettingsPage's bottom-left placement Close ended up
    /// under it, while at the top left the page's own controls do. Nothing
    /// foreign is moved or dismissed, and clicks keep their ownership guards.
    func placeTopLeft() throws {
        guard let root = exact("DesktopSettingsRoot"), let window: AXUIElement = d.attribute(root, kAXWindowAttribute),
              let screen = NSScreen.screens.first, let sizeVal: AXValue = d.attribute(window, kAXSizeAttribute) else {
            throw Failure("no owned Settings window to place")
        }
        var size = CGSize.zero
        AXValueGetValue(sizeVal, .cgSize, &size)
        // AX coordinates run down from the top of the primary display.
        let visible = screen.visibleFrame, top = screen.frame.maxY
        let area = CGRect(x: visible.minX, y: top - visible.maxY, width: visible.width, height: visible.height)
        let margin = max(0, min(20, (area.height - size.height) / 2, (area.width - size.width) / 2))
        var origin = CGPoint(x: area.minX + margin, y: area.minY + margin)
        if let value = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        usleep(400_000)
        guard let posVal: AXValue = d.attribute(window, kAXPositionAttribute) else { throw Failure("Settings window has no position") }
        var pos = CGPoint.zero
        AXValueGetValue(posVal, .cgPoint, &pos)
        let frame = CGRect(origin: pos, size: size)
        print("settings window placed at \(frame) in visible \(area)")
        guard area.insetBy(dx: -1, dy: -1).contains(frame) else {
            throw Failure("the Settings window \(frame) is not fully inside the visible frame \(area)")
        }
    }

    func click(_ id: String) throws {
        try clickLaidOut(id) { exact(id) }
    }

    /// The Keys page, filtered by real typing to the one action.
    func show(_ action: String) throws {
        try click("DesktopSettingsSection-keys")
        try click("DesktopShortcutFilter")
        d.key(Key.a, .maskCommand)
        try d.type(action)
        guard d.wait(for: { exact("DesktopShortcut-\(action)") != nil }, timeout: 5) else {
            throw Failure("the Keys filter did not show \(action)")
        }
    }

    /// Clicks the action's shortcut, which selects it and starts recording.
    func record(_ action: String) throws {
        try clickControl("Record", of: action)
        func label() -> String? {
            control("Record", of: action).flatMap { d.attribute($0, "AXLabel") as String? ?? d.attribute($0, kAXDescriptionAttribute) as String? }
        }
        guard d.wait(for: { label() == "Recording Shortcut" }, timeout: 5) else {
            throw Failure("\(action) did not start recording")
        }
    }

    func close() throws {
        try placeTopLeft()
        try click("DesktopSettingsClose")
        guard d.wait(for: { !isOpen }, timeout: 5) else { throw Failure("Close did not dismiss Settings") }
    }

    func binds(_ action: String) -> Bool { config.contains("=\(action)") }
}
