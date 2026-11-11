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

    private func guardOwned(_ point: CGPoint) throws {
        guard let owner = d.topmostOwner(at: point), owner == d.pid else {
            throw Failure("\(point) not owned by Tako (owner \(String(describing: d.topmostOwner(at: point))), pid \(d.pid))")
        }
        try d.requireAXOwnedTarget(at: point)
    }

    private func placement(_ id: String) throws -> (below: Bool, above: Bool, page: CGRect, floor: CGFloat) {
        guard let e = d.element(withIdentifier: id), let rect = frame(e),
              let pageEl = d.element(withIdentifier: "DesktopSettingsPage"), let page = frame(pageEl) else {
            throw Failure("no frame for \(id) or the settings page")
        }
        let floor = min(page.maxY, d.element(withIdentifier: "DesktopSettingsFooter").flatMap(frame)?.minY ?? page.maxY)
        return (rect.maxY > floor - 4, rect.minY < page.minY + 4, page, floor)
    }

    /// Wheel-scrolls a page control clear of the footer; fails if it cannot.
    func bringIntoView(_ id: String) throws {
        for _ in 0..<16 {
            let at = try placement(id)
            guard at.below || at.above else { return }
            let point = CGPoint(x: at.page.minX + at.page.width * 0.3, y: max(at.page.minY + 10, at.floor - 30))
            try guardOwned(point)
            CGEvent(mouseEventSource: d.source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            try d.requireAXOwnedTarget(at: point)
            let wheel = CGEvent(scrollWheelEvent2Source: d.source, units: .line, wheelCount: 1,
                                wheel1: at.below ? -4 : 4, wheel2: 0, wheel3: 0)
            wheel?.location = point
            wheel?.post(tap: .cghidEventTap)
            usleep(250_000)
            print("  scroll \(id) at \(point): control y \(d.element(withIdentifier: id).flatMap(frame).map { $0.minY } ?? -1)")
        }
        let at = try placement(id)
        if at.below || at.above {
            let rect = d.element(withIdentifier: id).flatMap(frame).map { "\($0)" } ?? "?"
            throw Failure("\(id) is still outside the clickable page after scrolling: control \(rect), page \(at.page), floor \(at.floor)")
        }
    }

    private func element(_ id: String) throws -> AXUIElement {
        guard d.wait(for: { d.element(withIdentifier: id) != nil }, timeout: 5), let e = d.element(withIdentifier: id) else {
            throw Failure("no control \(id)")
        }
        // Only controls on the scrolling page are scrolled to; the section list and Close are window chrome.
        // As the sidebar settings journey: AX scrolls it near, the wheel brings it clear of the footer.
        if id.hasPrefix("DesktopSetting-") || id.hasPrefix("DesktopSettingReset-") {
            AXUIElementPerformAction(e, "AXScrollToVisible" as CFString)
            usleep(300_000)
            try bringIntoView(id)
        }
        return d.element(withIdentifier: id) ?? e
    }

    func click(_ id: String) throws {
        do { try d.clickElement(try element(id)); print("control \(id): clicked") }
        catch { print("control \(id): FAILED \(error)"); throw error }
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
