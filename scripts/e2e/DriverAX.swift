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

// MARK: - Accessibility Helpers

extension Driver {
    var axApp: AXUIElement { AXUIElementCreateApplication(pid) }

    func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    func setAttribute<T>(_ element: AXUIElement, _ attribute: String, value: T) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value as CFTypeRef) == .success
    }

    func windowID(for element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        if _AXUIElementGetWindow(element, &id) == .success {
            return id
        }
        return nil
    }

    func windows() -> [AXUIElement] {
        (attribute(axApp, kAXWindowsAttribute) as [AXUIElement]?) ?? []
    }

    func queryWindows() throws -> [AXUIElement] {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard err == .success, let list = value as? [AXUIElement] else {
            throw Failure("AX query for windows failed with error: \(err.rawValue)")
        }
        return list
    }

    func queryWindowIDs() throws -> [(element: AXUIElement, id: CGWindowID)] {
        let list = try queryWindows()
        var result: [(element: AXUIElement, id: CGWindowID)] = []
        for elem in list {
            guard let id = windowID(for: elem) else {
                throw Failure("Failed to resolve CGWindowID for accessible window")
            }
            result.append((elem, id))
        }
        return result
    }

    func onScreenWindowNumbers() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var result = Set<CGWindowID>()
        for info in list {
            guard let ownerPid = info[kCGWindowOwnerPID as String] as? pid_t, ownerPid == pid else { continue }
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) > 80, (bounds["Height"] ?? 0) > 80 else { continue }
            if let idNum = info[kCGWindowNumber as String] as? UInt32 {
                result.insert(CGWindowID(idNum))
            }
        }
        return result
    }

    func onScreenWindows() -> [AXUIElement] {
        let onScreen = onScreenWindowNumbers()
        return windows().filter { win in
            guard let wid = windowID(for: win) else { return false }
            return onScreen.contains(wid)
        }
    }

    func activeOnScreenWindow() -> AXUIElement? {
        let onScreen = onScreenWindowNumbers()
        guard !onScreen.isEmpty else { return nil }
        if let focused: AXUIElement = attribute(axApp, kAXFocusedWindowAttribute),
           let wid = windowID(for: focused), onScreen.contains(wid) {
            return focused
        }
        if let main: AXUIElement = attribute(axApp, kAXMainWindowAttribute),
           let wid = windowID(for: main), onScreen.contains(wid) {
            return main
        }
        for win in windows().reversed() {
            if let wid = windowID(for: win), onScreen.contains(wid) {
                return win
            }
        }
        for win in windows() {
            if let wid = windowID(for: win), onScreen.contains(wid) {
                return win
            }
        }
        return nil
    }

    func activeWindow() -> AXUIElement? {
        if let onScreen = activeOnScreenWindow() {
            return onScreen
        }
        if let focused: AXUIElement = attribute(axApp, kAXFocusedWindowAttribute) {
            return focused
        }
        if let main: AXUIElement = attribute(axApp, kAXMainWindowAttribute) {
            return main
        }
        for win in windows().reversed() {
            let hidden: Bool? = attribute(win, "AXHidden")
            let minimized: Bool? = attribute(win, "AXMinimized")
            if hidden != true && minimized != true {
                return win
            }
        }
        return windows().first
    }

    func descendants(of root: AXUIElement, role: String, depth: Int = 24) -> [AXUIElement] {
        guard depth > 0 else { return [] }
        var found: [AXUIElement] = []
        for child in (attribute(root, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            if (attribute(child, kAXRoleAttribute) as String?) == role { found.append(child) }
            found += descendants(of: child, role: role, depth: depth - 1)
        }
        return found
    }

    func hasText(containing target: String) -> Bool {
        for window in windows() {
            if elementContainsText(window, target: target, depth: 22) { return true }
        }
        return false
    }

    func elementContainsText(_ element: AXUIElement, target: String, depth: Int) -> Bool {
        let val: String? = attribute(element, kAXValueAttribute)
        let title: String? = attribute(element, kAXTitleAttribute)
        let desc: String? = attribute(element, kAXDescriptionAttribute)
        let label: String? = attribute(element, "AXLabel")
        if val?.contains(target) == true || title?.contains(target) == true ||
           desc?.contains(target) == true || label?.contains(target) == true {
            return true
        }
        guard depth > 0 else { return false }
        for child in (attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            if elementContainsText(child, target: target, depth: depth - 1) { return true }
        }
        return false
    }

    func windowFrame(_ window: AXUIElement? = nil) -> CGRect? {
        guard let win = window ?? activeWindow(),
              let position: AXValue = attribute(win, kAXPositionAttribute),
              let size: AXValue = attribute(win, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &origin)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    func terminalFrame() -> CGRect? {
        guard let window = windows().first,
              let area = descendants(of: window, role: kAXTextAreaRole as String).first,
              let position: AXValue = attribute(area, kAXPositionAttribute),
              let size: AXValue = attribute(area, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &origin)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    func focus() {
        guard let window = activeWindow() else { return }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if let area = descendants(of: window, role: kAXTextAreaRole as String).first {
            AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
    }

    func setSize(_ size: CGSize, for window: AXUIElement? = nil) {
        guard let win = window ?? activeWindow() ?? windows().first else { return }
        var value = size
        if let axValue = AXValueCreate(.cgSize, &value) {
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, axValue)
        }
        usleep(100_000)
    }

    func setPosition(_ position: CGPoint, for window: AXUIElement? = nil) {
        guard let win = window ?? activeWindow() ?? windows().first else { return }
        var value = position
        if let axValue = AXValueCreate(.cgPoint, &value) {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, axValue)
        }
        usleep(100_000)
        focus()
    }

    func topmostOwner(at point: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for info in list {
            guard let ownerPid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            let alpha = info[kCGWindowAlpha as String] as? CGFloat ?? 1.0
            guard alpha > 0.05 else { continue }
            guard layer == 0 || (ownerPid == pid && layer <= 120) else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                              width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            if rect.contains(point) { return ownerPid }
        }
        return nil
    }

    func topmostWindowInfo(at point: CGPoint) -> String {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return "none" }
        var parts: [String] = []
        for info in list {
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                              width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            if rect.contains(point) {
                let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
                let ownerPid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
                let layer = info[kCGWindowLayer as String] as? Int ?? 0
                let num = info[kCGWindowNumber as String] as? Int ?? 0
                let alpha = info[kCGWindowAlpha as String] as? CGFloat ?? 1.0
                parts.append("[\(num):\(owner)(\(ownerPid)) L\(layer) a=\(alpha) \(rect)]")
            }
        }
        return parts.joined(separator: ", ")
    }

    func debugFocusState() -> String {
        let focusedWin: AXUIElement? = attribute(axApp, kAXFocusedWindowAttribute)
        let mainWin: AXUIElement? = attribute(axApp, kAXMainWindowAttribute)
        let focusedElem: AXUIElement? = attribute(axApp, kAXFocusedUIElementAttribute)
        let fRole: String = (focusedElem.flatMap { attribute($0, kAXRoleAttribute) }) ?? "nil"
        let fId: String = (focusedElem.flatMap { attribute($0, "AXIdentifier") }) ?? "nil"
        let fTitle: String = (focusedElem.flatMap { attribute($0, kAXTitleAttribute) }) ?? "nil"
        let isAppActive = NSRunningApplication(processIdentifier: pid)?.isActive ?? false
        let pane = (try? focusedPaneId()) ?? "none"
        return "appActive: \(isAppActive), focusedWin: \(focusedWin != nil), mainWin: \(mainWin != nil), focusedElem: role=\(fRole), id=\(fId), title=\(fTitle), focusedPane: \(pane)"
    }
}
