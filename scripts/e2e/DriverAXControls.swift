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
        let onScreen = onScreenWindows()
        for window in (onScreen.isEmpty ? windows() : onScreen) {
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
        guard let window = activeWindow() else { return [] }
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
        let normTitle = title.replacingOccurrences(of: "…", with: "...")
        let matching = descendants(of: axApp, role: kAXMenuItemRole as String).filter {
            guard let raw: String = attribute($0, kAXTitleAttribute) else { return false }
            let t = raw.replacingOccurrences(of: "…", with: "...")
            guard t == normTitle || t.starts(with: normTitle) else { return false }
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

    private func axFrame(_ elem: AXUIElement) -> CGRect? {
        guard let posVal: AXValue = attribute(elem, kAXPositionAttribute),
              let sizeVal: AXValue = attribute(elem, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posVal, .cgPoint, &pos)
        AXValueGetValue(sizeVal, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    func clickOpenMenuItem(titled title: String) throws {
        guard wait(for: { self.openMenuItem(titled: title) != nil }, timeout: 5) else {
            let allItems = descendants(of: axApp, role: kAXMenuItemRole as String).map { (elem: AXUIElement) -> String in
                let t: String = self.attribute(elem, kAXTitleAttribute) ?? "nil"
                let r = self.axFrame(elem) ?? .zero
                return "\(t) (\(r.width)x\(r.height) at \(r.origin.x),\(r.origin.y))"
            }
            throw Failure("open menu item '\(title)' not found (found menu items: \(allItems))")
        }
        guard let item = openMenuItem(titled: title) else {
            throw Failure("open menu item '\(title)' not found")
        }
        press(item)
        if let f = axFrame(item) {
            try? click(at: CGPoint(x: f.midX, y: f.midY))
        }
        usleep(500_000)
    }

    func clickWorkspacePill(in window: AXUIElement? = nil) throws {
        if let window { _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
        guard let bar: AXUIElement = attribute(axApp, kAXMenuBarAttribute) else {
            throw Failure("Workspace menu bar not accessible")
        }
        for top in (attribute(bar, kAXChildrenAttribute) as [AXUIElement]?) ?? []
        where (attribute(top, kAXTitleAttribute) as String?) == "Workspace" {
            if let f = axFrame(top) {
                let center = CGPoint(x: f.midX, y: f.midY)
                traceClick(at: center, expected: window ?? activeWindow(), target: top)
                try click(at: center)
                usleep(600_000)
                return
            }
            if AXUIElementPerformAction(top, kAXPressAction as CFString) == .success {
                usleep(600_000)
                return
            }
        }
        throw Failure("Workspace menu bar item not found")
    }

    func clickPlusButton(in window: AXUIElement? = nil) throws {
        let win = window ?? activeWindow()
        let roots = (win.map { [$0] } ?? onScreenWindows()) + windows()
        for id in ["SessionSidebarNewSession", "SessionSidebarHeaderNewSession"] {
            for root in roots {
                if let elem = element(withIdentifier: id, root: root),
                   let f = axFrame(elem), f.width > 4, f.height > 4 {
                    try click(at: CGPoint(x: f.midX, y: f.midY))
                    usleep(1_000_000)
                    return
                }
            }
        }
        throw Failure("SessionSidebarNewSession button not found in window")
    }

    static func filterActiveWorkspaceRows<T>(
        headers: [(id: String, isActive: Bool, y: CGFloat)],
        rows: [(id: String, elem: T, pos: CGPoint)],
        allowedPaneIds: Set<String>? = nil
    ) -> [T] {
        let sortedHeaders = headers.sorted { $0.y < $1.y }
        var scoped = rows.sorted { $0.pos.y == $1.pos.y ? $0.pos.x < $1.pos.x : $0.pos.y < $1.pos.y }
        if let idx = sortedHeaders.firstIndex(where: \.isActive) {
            let minY = sortedHeaders[idx].y
            let maxY = (idx + 1 < sortedHeaders.count) ? sortedHeaders[idx + 1].y : .greatestFiniteMagnitude
            scoped = scoped.filter { $0.pos.y > minY && $0.pos.y < maxY }
        } else if let firstInactive = sortedHeaders.first {
            scoped = scoped.filter { $0.pos.y < firstInactive.y }
        }
        if let allowed = allowedPaneIds, !allowed.isEmpty {
            let groupScoped = scoped.filter {
                allowed.contains(String($0.id.dropFirst("session-tab-".count)).lowercased())
            }
            if !groupScoped.isEmpty { scoped = groupScoped }
        }
        return scoped.map(\.elem)
    }

    private func activeGroupPaneIds(selectedRowId: String?) -> Set<String>? {
        let ctl = "\(appURL.path)/Contents/MacOS/takoctl --bundle-id \(bundleID)"
        guard let js = try? exec("\(ctl) tree --json"), let data = js.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let wins = ((obj["result"] as? [String: Any]) ?? obj)["windows"] as? [[String: Any]] else { return nil }
        let selectedPane = selectedRowId.map { String($0.dropFirst("session-tab-".count)).lowercased() }
        for w in wins {
            let panes = ((w["tabs"] as? [[String: Any]]) ?? []).flatMap { ($0["panes"] as? [[String: Any]]) ?? [] }
            let ids = Set(panes.compactMap { ($0["id"] as? String)?.lowercased() })
            let hasFocused = panes.contains { ($0["focused"] as? Bool) == true }
            if let sel = selectedPane, ids.contains(sel) { return ids }
            if selectedPane == nil && hasFocused { return ids }
        }
        return nil
    }

    private func sidebarSessionRows(in window: AXUIElement? = nil) -> [AXUIElement] {
        let win = window ?? activeWindow()
        let onScreen = onScreenWindows()
        let roots = win.map { [$0] } ?? (onScreen.isEmpty ? windows() : onScreen)
        for root in roots {
            var headersById: [String: (isActive: Bool, y: CGFloat, area: CGFloat)] = [:]
            var rowsById: [String: (elem: AXUIElement, pos: CGPoint, isSelected: Bool, area: CGFloat)] = [:]
            func walk(_ node: AXUIElement, depth: Int) {
                if let id: String = attribute(node, "AXIdentifier"),
                   let posVal: AXValue = attribute(node, kAXPositionAttribute),
                   let sizeVal: AXValue = attribute(node, kAXSizeAttribute) {
                    var pos = CGPoint.zero, size = CGSize.zero
                    AXValueGetValue(posVal, .cgPoint, &pos)
                    AXValueGetValue(sizeVal, .cgSize, &size)
                    let area = size.width * size.height
                    if size.width > 10 && size.height > 10 {
                        let val = (attribute(node, kAXValueAttribute) as String?) ?? ""
                        if id.hasPrefix("SessionSidebarWorkspace-"), headersById[id].map({ area > $0.area }) ?? true {
                            headersById[id] = (val == "active", pos.y, area)
                        } else if id.hasPrefix("session-tab-"), rowsById[id].map({ area > $0.area }) ?? true {
                            rowsById[id] = (node, pos, val == "selected", area)
                        }
                    }
                }
                guard depth > 0 else { return }
                for child in (attribute(node, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                    walk(child, depth: depth - 1)
                }
            }
            walk(root, depth: 28)
            if !rowsById.isEmpty {
                let selectedId = rowsById.first(where: { $0.value.isSelected })?.key
                let allowed = onScreen.count > 1 ? activeGroupPaneIds(selectedRowId: selectedId) : nil
                return Self.filterActiveWorkspaceRows(
                    headers: headersById.map { ($0.key, $0.value.isActive, $0.value.y) },
                    rows: rowsById.map { ($0.key, $0.value.elem, $0.value.pos) },
                    allowedPaneIds: allowed
                )
            }
        }
        return []
    }

    func tabElement(index: Int, in window: AXUIElement? = nil) -> AXUIElement? {
        let rows = sidebarSessionRows(in: window)
        return rows.indices.contains(index) ? rows[index] : nil
    }

    func tabClickPoint(index: Int, in window: AXUIElement? = nil) throws -> CGPoint {
        guard let tab = tabElement(index: index, in: window) else {
            throw Failure("session-tab[\(index)] accessibility element not found")
        }
        guard let tabPos: AXValue = attribute(tab, kAXPositionAttribute),
              let tabSize: AXValue = attribute(tab, kAXSizeAttribute) else {
            throw Failure("cannot get frame for session-tab[\(index)]")
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(tabPos, .cgPoint, &pos)
        AXValueGetValue(tabSize, .cgSize, &size)
        return CGPoint(x: pos.x + min(40, size.width / 3), y: pos.y + size.height / 2)
    }

    func clickTab(index: Int, in window: AXUIElement? = nil) throws {
        let clickPoint = try tabClickPoint(index: index, in: window)
        if ProcessInfo.processInfo.environment["TAKO_E2E_TRACE_CLICKS"] == "1" {
            traceClick(at: clickPoint, expected: window ?? activeWindow(),
                       target: tabElement(index: index, in: window))
        }
        try click(at: clickPoint)
        usleep(600_000)
    }

    func tabCount() -> Int {
        guard !windows().isEmpty else { return 0 }
        return max(sidebarSessionRows().count, 1)
    }

    func paintedTabDot(index: Int, in window: AXUIElement? = nil) -> String? {
        guard let tab = tabElement(index: index, in: window) else { return nil }
        if let help: String = attribute(tab, kAXHelpAttribute), help.hasPrefix("dot:") {
            return help
        }
        for child in (attribute(tab, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            if let help: String = attribute(child, kAXHelpAttribute), help.hasPrefix("dot:") {
                return help
            }
        }
        return attribute(tab, kAXHelpAttribute)
    }

    func assertInTerminalDialog(title: String, bodyContains: String? = nil) throws {
        let liveWins = onScreenWindows()
        guard !liveWins.isEmpty else {
            throw Failure("no live on-screen host windows found for dialog '\(title)'")
        }
        for w in liveWins where !descendants(of: w, role: "AXSheet").isEmpty {
            throw Failure("dialog '\(title)' attached a native AXSheet instead of TerminalDialogView")
        }
        var matched = false
        for w in liveWins {
            for elem in descendants(of: w, role: kAXGroupRole as String) + descendants(of: w, role: kAXStaticTextRole as String) {
                let id: String? = attribute(elem, "AXIdentifier")
                if id == "terminal-dialog-view" || id == "terminal-dialog-body" {
                    let lbl = (attribute(elem, kAXTitleAttribute) as String?) ?? (attribute(elem, kAXDescriptionAttribute) as String?) ?? ""
                    let val = (attribute(elem, kAXValueAttribute) as String?) ?? ""
                    if lbl.contains(title) || val.contains(title) {
                        if let sub = bodyContains, !val.contains(sub) && !lbl.contains(sub) { continue }
                        matched = true
                        break
                    }
                }
            }
            if matched { break }
        }
        guard matched else {
            throw Failure("positive TerminalDialogView witness not found for title '\(title)'")
        }
    }
}
