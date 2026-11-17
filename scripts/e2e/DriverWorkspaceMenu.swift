/*
 * tako — Owned real input into the app's Workspace menu
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import ApplicationServices

extension Driver {
    func clickWorkspacePill(in window: AXUIElement? = nil) throws {
        if let window { _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
        if let root = window ?? activeWindow(),
           let pill = descendants(of: root, role: kAXButtonRole as String).first(where: {
               (attribute($0, "AXIdentifier") as String?) == "workspace-pill"
           }) {
            try clickElement(pill)
            return
        }
        // The permanent-sidebar design has no window tab-bar pill. Use its
        // current application-menu entry. CGWindowList has no app-owned window
        // for a menu-bar item: prove the exact AX owner AND actual input hit
        // instead. Ordinary window clicks retain both ownership checks.
        guard let bar: AXUIElement = attribute(axApp, kAXMenuBarAttribute),
              let item = ((attribute(bar, kAXChildrenAttribute) as [AXUIElement]?) ?? []).first(where: {
                  (attribute($0, kAXTitleAttribute) as String?) == "Workspace"
              }) else { throw Failure("no Workspace menu-bar item") }
        try clickOwnedMenuBarItem(item, title: "Workspace")
    }

    /// AXPress on a closed menu's stale child can report success without
    /// delivering its command. Open the owning menu and click the visible item.
    func clickApplicationMenuCommand(titledPrefix prefix: String) throws {
        guard let bar: AXUIElement = attribute(axApp, kAXMenuBarAttribute),
              let top = ((attribute(bar, kAXChildrenAttribute) as [AXUIElement]?) ?? []).first(where: { candidate in
                  descendants(of: candidate, role: kAXMenuItemRole as String).contains {
                      (attribute($0, kAXTitleAttribute) as String?)?.hasPrefix(prefix) == true
                  }
              }), let title: String = attribute(top, kAXTitleAttribute) else {
            throw Failure("no application menu contains \(prefix)")
        }
        try clickOwnedMenuBarItem(top, title: title)
        var command: AXUIElement?
        guard wait(for: {
            command = self.descendants(of: top, role: kAXMenuItemRole as String).first {
                (self.attribute($0, kAXTitleAttribute) as String?)?.hasPrefix(prefix) == true
                    && self.axFrame($0).map { $0.width > 10 && $0.height > 10 } == true
            }
            return command != nil
        }, timeout: 5), let command else { throw Failure("\(prefix) has no open-menu hit target") }
        try clickElement(command)
    }

    private func clickOwnedMenuBarItem(_ item: AXUIElement, title: String) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              (attribute(item, kAXTitleAttribute) as String?) == title,
              (attribute(item, kAXRoleAttribute) as String?) == kAXMenuBarItemRole as String,
              let frame = axFrame(item) else {
            throw Failure("no frontmost app-owned \(title) menu item: expected pid \(pid), front pid \(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0), title \(String(describing: attribute(item, kAXTitleAttribute) as String?)), role \(String(describing: attribute(item, kAXRoleAttribute) as String?)), frame \(String(describing: axFrame(item))); \(debugFocusState())")
        }
        var owner: pid_t = 0
        guard AXUIElementGetPid(item, &owner) == .success, owner == pid else {
            throw Failure("\(title) menu item is not owned by this fixture")
        }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        try requireAXOwnedTarget(at: point)
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                 mouseCursorPosition: point, mouseButton: .left),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else {
            throw Failure("could not create \(title) menu mouse events")
        }
        move.post(tap: .cghidEventTap)
        usleep(30_000)
        try requireAXOwnedTarget(at: point)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw Failure("fixture lost foreground before the \(title) menu press")
        }
        print("\(title) menu: AX item and actual hit owned by fixture pid \(pid)")
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
        usleep(600_000)
    }
}
