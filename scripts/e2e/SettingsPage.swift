/*
 * tako — Guarded real input on the Settings window for e2e journeys
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import ApplicationServices
import Foundation

/// The Settings window, driven like a person drives it: the owned window
/// moved into the visible frame and raised, page controls scrolled into view
/// with the wheel, then clicked. Every wheel event, click and menu item goes
/// to a point Tako owns, by the window list and by the actual AX recipient;
/// otherwise the step fails without posting. Nothing is pressed through AX.
struct SettingsPage {
    let d: Driver
    init(_ d: Driver) { self.d = d }

    func frame(_ e: AXUIElement) -> CGRect? {
        guard let p: AXValue = d.attribute(e, kAXPositionAttribute), let s: AXValue = d.attribute(e, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p, .cgPoint, &pos); AXValueGetValue(s, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    /// The owned Settings window inside the display's visible frame, raised.
    func placeWindow() {
        guard let root = d.element(withIdentifier: "DesktopSettingsRoot"), let window: AXUIElement = d.attribute(root, kAXWindowAttribute),
              let screen = NSScreen.main, let sizeVal: AXValue = d.attribute(window, kAXSizeAttribute) else { return }
        var size = CGSize.zero
        AXValueGetValue(sizeVal, .cgSize, &size)
        let visible = screen.visibleFrame, top = screen.frame.maxY
        var origin = CGPoint(x: visible.minX + 20, y: max(top - visible.maxY, top - visible.minY - size.height - 20))
        if let value = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        usleep(400_000)
    }

    /// The element whose identifier is exactly `id`. Driver.element also takes
    /// one whose identifier merely contains it, so `…-font-size` found the
    /// stepper's `…-font-size-decrease` and `…Palette-1` could find `…Palette-15`.
    func exact(_ id: String) -> AXUIElement? {
        func find(_ e: AXUIElement, depth: Int) -> AXUIElement? {
            if (d.attribute(e, "AXIdentifier") as String?) == id { return e }
            guard depth > 0 else { return nil }
            for child in (d.attribute(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                if let hit = find(child, depth: depth - 1) { return hit }
            }
            return nil
        }
        // Only under the panel: walking whole windows also walks the terminals' trees.
        guard let root = d.element(withIdentifier: "DesktopSettingsRoot") else { return nil }
        return find(root, depth: 30)
    }

    private func guardOwned(_ point: CGPoint) throws {
        guard let owner = d.topmostOwner(at: point), owner == d.pid else {
            throw Failure("\(point) not owned by Tako (owner \(String(describing: d.topmostOwner(at: point))), pid \(d.pid))")
        }
        try d.requireAXOwnedTarget(at: point)
    }

    /// A control taller than the visible page (the theme Configuration
    /// editor) is in view once its top is visible and its middle, where a
    /// click lands, is clear of the footer.
    private func placement(_ id: String) throws -> (below: Bool, above: Bool, page: CGRect, floor: CGFloat, rect: CGRect, tall: Bool) {
        guard let e = exact(id), let rect = frame(e),
              let pageEl = d.element(withIdentifier: "DesktopSettingsPage"), let page = frame(pageEl) else {
            throw Failure("no frame for \(id) or the settings page")
        }
        let floor = min(page.maxY, d.element(withIdentifier: "DesktopSettingsFooter").flatMap(frame)?.minY ?? page.maxY)
        let tall = rect.height > floor - page.minY - 8
        return ((tall ? rect.midY : rect.maxY) > floor - 4, rect.minY < page.minY + 4, page, floor, rect, tall)
    }

    /// Wheel-scrolls a page control clear of the footer; fails if it cannot.
    func bringIntoView(_ id: String) throws {
        for _ in 0..<30 {
            let at = try placement(id)
            guard at.below || at.above else { return }
            var point = CGPoint(x: at.page.minX + at.page.width * 0.3, y: max(at.page.minY + 10, at.floor - 30))
            // Never wheel inside the control: a text editor would scroll its own text, not the page.
            if at.rect.contains(point) { point.x = at.page.minX + 6 }
            try guardOwned(point)
            CGEvent(mouseEventSource: d.source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            try d.requireAXOwnedTarget(at: point)
            let step: Int32 = at.tall ? 3 : 8
            let wheel = CGEvent(scrollWheelEvent2Source: d.source, units: .line, wheelCount: 1,
                                wheel1: at.below ? -step : step, wheel2: 0, wheel3: 0)
            wheel?.location = point
            wheel?.post(tap: .cghidEventTap)
            usleep(250_000)
            print("  scroll \(id) at \(point): control y \(exact(id).flatMap(frame).map { $0.minY } ?? -1)")
        }
        let at = try placement(id)
        if at.below || at.above {
            let rect = exact(id).flatMap(frame).map { "\($0)" } ?? "?"
            throw Failure("\(id) is still outside the clickable page after scrolling: control \(rect), page \(at.page), floor \(at.floor)")
        }
    }

    /// Controls on the scrolling page; the section list, Close and the draft
    /// footer's Save/Undo and its error line are window chrome. Theme cards,
    /// the theme filter and the draft editor's fields are on the page.
    private func onPage(_ id: String) -> Bool {
        id.hasPrefix("DesktopSetting-") || id.hasPrefix("DesktopSettingReset-")
            || (id.hasPrefix("DesktopTheme") && !["DesktopThemeSave", "DesktopThemeCancel", "DesktopThemeError"].contains(id))
    }

    /// A lazy grid (the ANSI colors) makes its later rows only once they are
    /// scrolled near: wheel the page down until the control exists.
    private func scrollUntilPresent(_ id: String) throws {
        for _ in 0..<20 {
            if d.wait(for: { exact(id) != nil }, timeout: 0.5) { return }
            guard let pageEl = d.element(withIdentifier: "DesktopSettingsPage"), let page = frame(pageEl) else { return }
            let floor = min(page.maxY, d.element(withIdentifier: "DesktopSettingsFooter").flatMap(frame)?.minY ?? page.maxY)
            let point = CGPoint(x: page.minX + page.width * 0.3, y: max(page.minY + 10, floor - 30))
            try guardOwned(point)
            CGEvent(mouseEventSource: d.source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            try d.requireAXOwnedTarget(at: point)
            let wheel = CGEvent(scrollWheelEvent2Source: d.source, units: .line, wheelCount: 1, wheel1: -8, wheel2: 0, wheel3: 0)
            wheel?.location = point
            wheel?.post(tap: .cghidEventTap)
            usleep(250_000)
            print("  scroll toward \(id) at \(point)")
        }
    }

    private func element(_ id: String) throws -> AXUIElement {
        if onPage(id) { try scrollUntilPresent(id) }
        guard d.wait(for: { exact(id) != nil }, timeout: 5), let e = exact(id) else {
            throw Failure("no control \(id)")
        }
        // As the sidebar settings journey: AX scrolls it near, the wheel brings it clear of the footer.
        if onPage(id) {
            AXUIElementPerformAction(e, "AXScrollToVisible" as CFString)
            usleep(300_000)
            try bringIntoView(id)
        }
        return exact(id) ?? e
    }

    func click(_ id: String) throws {
        do { try d.clickElement(try element(id)); print("control \(id): clicked") }
        catch { print("control \(id): FAILED \(error)"); throw error }
    }

    /// The control's AX value ("" when it has none).
    func value(_ id: String) -> String {
        exact(id).flatMap { d.attribute($0, kAXValueAttribute) as String? } ?? ""
    }

    /// Clicks a text field or editor, selects its text and types `text`
    /// as keys; Return commits a single-line field.
    func enter(_ id: String, _ text: String, submit: Bool = true) throws {
        try click(id)
        d.key(Key.a, .maskCommand)
        try d.type(text)
        if submit { d.key(Key.returnKey) }
        usleep(300_000)
        print("field \(id): entered \(text.debugDescription)")
    }

    /// Opens a long pop-up menu by a real click, then picks `title` the way a
    /// person does in a long list: typing its name selects it, Return chooses it.
    func choose(menu id: String, typing title: String) throws {
        do {
            try d.clickElement(try element(id))
            guard d.wait(for: { d.openMenuItem(titled: title) != nil }, timeout: 5) else { throw Failure("menu \(id) shows no item \(title)") }
            try d.type(title)
            d.key(Key.returnKey)
            guard d.wait(for: { d.openMenuItem(titled: title) == nil }, timeout: 5) else { throw Failure("menu \(id) did not close on \(title)") }
            usleep(300_000)
            print("menu \(id) → \(title): typed and chosen")
        } catch { print("menu \(id) → \(title): FAILED \(error)"); throw error }
    }

    /// Opens a pop-up menu by a real click and picks an item by a real click.
    func choose(menu id: String, item title: String) throws {
        do {
            try d.clickElement(try element(id))
            guard d.wait(for: { d.openMenuItem(titled: title) != nil }, timeout: 5), let item = d.openMenuItem(titled: title),
                  let rect = frame(item) else { throw Failure("menu \(id) shows no item \(title)") }
            try d.click(at: CGPoint(x: rect.midX, y: rect.midY))
            usleep(300_000)
            print("menu \(id) → \(title): chosen")
        } catch { print("menu \(id) → \(title): FAILED \(error)"); throw error }
    }
}
