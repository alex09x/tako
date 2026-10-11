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
import ApplicationServices
import Foundation

// MARK: - Accessibility UI Controls (Buttons, Text Fields, Menus, Tabs, Pills)

extension Driver {
    func press(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    /// A button with this title anywhere in Tako's visible windows or sheets.
    func button(titled title: String, depth: Int = 24) -> AXUIElement? {
        for window in windows() {
            let hidden: Bool? = attribute(window, "AXHidden")
            let minimized: Bool? = attribute(window, "AXMinimized")
            if hidden == true || minimized == true { continue }
            for btn in descendants(of: window, role: kAXButtonRole as String, depth: depth) {
                let axTitle: String? = attribute(btn, kAXTitleAttribute)
                let axDesc: String? = attribute(btn, kAXDescriptionAttribute)
                let axLabel: String? = attribute(btn, "AXLabel")
                let axId: String? = attribute(btn, "AXIdentifier")
                if axTitle == title || axDesc == title || axLabel == title || axId == title ||
                   axTitle?.contains(title) == true || axDesc?.contains(title) == true || axLabel?.contains(title) == true || axId?.contains(title) == true ||
                   elementContainsText(btn, target: title, depth: 3) {
                    return btn
                }
            }
        }
        return nil
    }

    func clickButton(titled title: String) throws {
        guard let btn = button(titled: title) else {
            throw Failure("button titled '\(title)' not found")
        }
        guard let btnPos: AXValue = attribute(btn, kAXPositionAttribute),
              let btnSize: AXValue = attribute(btn, kAXSizeAttribute) else {
            throw Failure("cannot get frame for button '\(title)'")
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(btnPos, .cgPoint, &pos)
        AXValueGetValue(btnSize, .cgSize, &size)
        let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
        try click(at: center)
        usleep(400_000)
    }

    /// A text field with this identifier or description anywhere in Tako's windows.
    func textField(identifier: String, depth: Int = 24) -> AXUIElement? {
        for window in windows() {
            for tf in descendants(of: window, role: kAXTextFieldRole as String, depth: depth) {
                let axId: String? = attribute(tf, "AXIdentifier")
                let axDesc: String? = attribute(tf, kAXDescriptionAttribute)
                let axTitle: String? = attribute(tf, kAXTitleAttribute)
                let axLabel: String? = attribute(tf, "AXLabel")
                if axId == identifier || axDesc == identifier || axTitle == identifier || axLabel == identifier ||
                   axId?.contains(identifier) == true || axDesc?.contains(identifier) == true {
                    return tf
                }
            }
        }
        return nil
    }

    func textFields() -> [String] {
        guard let window = windows().first else { return [] }
        return descendants(of: window, role: kAXTextFieldRole as String).compactMap {
            attribute($0, kAXValueAttribute) as String?
        }
    }

    func element(withIdentifier identifier: String, root: AXUIElement? = nil, depth: Int = 24) -> AXUIElement? {
        let roots = root.map { [$0] } ?? windows()
        for r in roots {
            if let found = findElementById(r, identifier: identifier, depth: depth) {
                return found
            }
        }
        return nil
    }

    private func findElementById(_ element: AXUIElement, identifier: String, depth: Int) -> AXUIElement? {
        let axId: String? = attribute(element, "AXIdentifier")
        if axId == identifier || axId?.contains(identifier) == true { return element }
        guard depth > 0 else { return nil }
        for child in (attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            if let match = findElementById(child, identifier: identifier, depth: depth - 1) {
                return match
            }
        }
        return nil
    }

    @discardableResult
    func pressMenu(title: String) -> Bool {
        guard let bar: AXUIElement = attribute(axApp, kAXMenuBarAttribute) else { return false }
        for top in (attribute(bar, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            for menu in (attribute(top, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                for item in (attribute(menu, kAXChildrenAttribute) as [AXUIElement]?) ?? []
                where (attribute(item, kAXTitleAttribute) as String?) == title {
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    func pressMenuItem(titledPrefix prefix: String) -> Bool {
        for item in descendants(of: axApp, role: kAXMenuItemRole as String) {
            let title: String? = attribute(item, kAXTitleAttribute)
            if title?.starts(with: prefix) == true {
                return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    func pressQuitMenuItem() -> Bool {
        pressMenuItem(titledPrefix: "Quit")
    }

    func menuItemEnabled(_ title: String) -> Bool? {
        guard let bar: AXUIElement = attribute(axApp, kAXMenuBarAttribute) else { return nil }
        for top in (attribute(bar, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            for menu in (attribute(top, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                for item in (attribute(menu, kAXChildrenAttribute) as [AXUIElement]?) ?? []
                where (attribute(item, kAXTitleAttribute) as String?) == title {
                    return attribute(item, kAXEnabledAttribute)
                }
            }
        }
        return nil
    }

    func openMenuItem(titled title: String) -> AXUIElement? {
        let matching = descendants(of: axApp, role: kAXMenuItemRole as String).filter {
            let t: String? = attribute($0, kAXTitleAttribute)
            guard t == title || t?.starts(with: title) == true else { return false }
            if let sizeVal: AXValue = attribute($0, kAXSizeAttribute) {
                var s = CGSize.zero
                AXValueGetValue(sizeVal, .cgSize, &s)
                return s.width > 10 && s.height > 10
            }
            return true
        }
        // Prefer menu items in open popup menus (y > 30) over menu bar items (y <= 30)
        if let popupItem = matching.reversed().first(where: {
            guard let posVal: AXValue = attribute($0, kAXPositionAttribute) else { return false }
            var pt = CGPoint.zero
            AXValueGetValue(posVal, .cgPoint, &pt)
            return pt.y > 30
        }) {
            return popupItem
        }
        return matching.last ?? matching.first
    }

    func clickOpenMenuItem(titled title: String) throws {
        guard wait(for: { self.openMenuItem(titled: title) != nil }, timeout: 5) else {
            let allItems = descendants(of: axApp, role: kAXMenuItemRole as String).map { (elem: AXUIElement) -> String in
                let t: String = self.attribute(elem, kAXTitleAttribute) ?? "nil"
                var s = CGSize.zero
                if let sizeVal: AXValue = self.attribute(elem, kAXSizeAttribute) {
                    AXValueGetValue(sizeVal, .cgSize, &s)
                }
                var p = CGPoint.zero
                if let posVal: AXValue = self.attribute(elem, kAXPositionAttribute) {
                    AXValueGetValue(posVal, .cgPoint, &p)
                }
                return "\(t) (\(s.width)x\(s.height) at \(p.x),\(p.y))"
            }
            throw Failure("open menu item '\(title)' not found (found menu items: \(allItems))")
        }
        guard let item = openMenuItem(titled: title) else {
            throw Failure("open menu item '\(title)' not found")
        }
        press(item)
        if let itemPos: AXValue = attribute(item, kAXPositionAttribute),
           let itemSize: AXValue = attribute(item, kAXSizeAttribute) {
            var pos = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(itemPos, .cgPoint, &pos)
            AXValueGetValue(itemSize, .cgSize, &size)
            let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
            try? click(at: center)
        }
        usleep(500_000)
    }

    func clickWorkspacePill(in window: AXUIElement? = nil) throws {
        let win = window ?? activeWindow()
        let roots = win.map { [$0] } ?? onScreenWindows()
        for root in roots {
            let candidates = descendants(of: root, role: kAXButtonRole as String)
                + descendants(of: root, role: kAXPopUpButtonRole as String)
            for elem in candidates {
                if let id: String = attribute(elem, "AXIdentifier"), id == "workspace-pill" {
                    if let btnPos: AXValue = attribute(elem, kAXPositionAttribute),
                       let btnSize: AXValue = attribute(elem, kAXSizeAttribute) {
                        var pos = CGPoint.zero
                        var size = CGSize.zero
                        AXValueGetValue(btnPos, .cgPoint, &pos)
                        AXValueGetValue(btnSize, .cgSize, &size)
                        let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
                        try click(at: center)
                        usleep(600_000)
                        return
                    }
                }
            }
            if let elem = element(withIdentifier: "workspace-pill", root: root) {
                if let btnPos: AXValue = attribute(elem, kAXPositionAttribute),
                   let btnSize: AXValue = attribute(elem, kAXSizeAttribute) {
                    var pos = CGPoint.zero
                    var size = CGSize.zero
                    AXValueGetValue(btnPos, .cgPoint, &pos)
                    AXValueGetValue(btnSize, .cgSize, &size)
                    let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
                    try click(at: center)
                    usleep(600_000)
                    return
                }
            }
        }
        for root in windows() {
            if let elem = element(withIdentifier: "workspace-pill", root: root) {
                if let btnPos: AXValue = attribute(elem, kAXPositionAttribute),
                   let btnSize: AXValue = attribute(elem, kAXSizeAttribute) {
                    var pos = CGPoint.zero
                    var size = CGSize.zero
                    AXValueGetValue(btnPos, .cgPoint, &pos)
                    AXValueGetValue(btnSize, .cgSize, &size)
                    let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
                    try click(at: center)
                    usleep(600_000)
                    return
                }
            }
        }
        throw Failure("workspace-pill button not found in window")
    }

    func clickPlusButton(in window: AXUIElement? = nil) throws {
        let win = window ?? activeWindow()
        let roots = win.map { [$0] } ?? onScreenWindows()
        for root in roots {
            for elem in descendants(of: root, role: kAXButtonRole as String) {
                if let id: String = attribute(elem, "AXIdentifier"), id == "new-tab-button" {
                    if let btnPos: AXValue = attribute(elem, kAXPositionAttribute),
                       let btnSize: AXValue = attribute(elem, kAXSizeAttribute) {
                        var pos = CGPoint.zero
                        var size = CGSize.zero
                        AXValueGetValue(btnPos, .cgPoint, &pos)
                        AXValueGetValue(btnSize, .cgSize, &size)
                        let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
                        try click(at: center)
                        usleep(1_000_000)
                        return
                    }
                }
            }
        }
        throw Failure("new-tab-button not found in window")
    }

    func tabElement(index: Int, in window: AXUIElement? = nil) -> AXUIElement? {
        let win = window ?? activeWindow()
        let targetId = "tab-\(index)"
        let roots = win.map { [$0] } ?? onScreenWindows()
        for root in roots {
            for elem in descendants(of: root, role: kAXRadioButtonRole as String) {
                if let id: String = attribute(elem, "AXIdentifier"), id == targetId {
                    return elem
                }
            }
        }
        return nil
    }

    func tabClickPoint(index: Int, in window: AXUIElement? = nil) throws -> CGPoint {
        guard let tab = tabElement(index: index, in: window) else {
            throw Failure("tab-\(index) accessibility element not found")
        }
        guard let tabPos: AXValue = attribute(tab, kAXPositionAttribute),
              let tabSize: AXValue = attribute(tab, kAXSizeAttribute) else {
            throw Failure("cannot get frame for tab-\(index)")
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(tabPos, .cgPoint, &pos)
        AXValueGetValue(tabSize, .cgSize, &size)
        return CGPoint(x: pos.x + min(25, size.width / 3), y: pos.y + size.height / 2)
    }

    func clickTab(index: Int, in window: AXUIElement? = nil) throws {
        let clickPoint = try tabClickPoint(index: index, in: window)
        try click(at: clickPoint)
        usleep(600_000)
    }

    func tabCount() -> Int {
        guard let window = windows().first else { return 0 }
        let groups = descendants(of: window, role: kAXTabGroupRole as String)
        let tabs = groups.flatMap { descendants(of: $0, role: kAXRadioButtonRole as String, depth: 2) }
        return max(tabs.count, 1)
    }
}
