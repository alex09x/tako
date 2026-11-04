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

final class TabBarChildAccessibilityElement: NSAccessibilityElement {
    var onPerformPress: (() -> Bool)?

    override func accessibilityPerformPress() -> Bool {
        onPerformPress?() ?? false
    }
}

extension Tako.TabBarView {
    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .tabGroup
    }

    override func accessibilityLabel() -> String? {
        "Tabs"
    }

    override func accessibilityIdentifier() -> String {
        "tab-bar"
    }

    override func isAccessibilityEnabled() -> Bool { true }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard let children = accessibilityChildren() as? [NSAccessibilityElement] else {
            return self
        }
        for child in children {
            if child.accessibilityFrame().contains(point) {
                return child
            }
        }
        return self
    }

    override func accessibilityChildren() -> [Any]? {
        guard let window else {
            cachedAccessibilityChildren = []
            return []
        }
        layoutTabs()
        var elements: [NSAccessibilityElement] = []
        var previous: [String: TabBarChildAccessibilityElement] = [:]
        for case let child as TabBarChildAccessibilityElement in cachedAccessibilityChildren {
            if let id = child.accessibilityIdentifier() { previous[id] = child }
        }
        func element(_ id: String) -> TabBarChildAccessibilityElement {
            let child = previous[id] ?? TabBarChildAccessibilityElement()
            child.setAccessibilityParent(self)
            child.setAccessibilityIdentifier(id)
            child.setAccessibilityEnabled(true)
            return child
        }

        if showsWorkspacePill {
            let ws = WorkspaceStore.shared.activeWorkspace
            let wsElem = element("workspace-pill")
            wsElem.setAccessibilityRole(.button)
            wsElem.setAccessibilityLabel("Workspace: \(ws.name)")
            wsElem.setAccessibilityTitle(ws.name)
            wsElem.setAccessibilityValue(ws.name)
            wsElem.setAccessibilityIdentifier("workspace-pill")
            let localRect = workspacePillRect
            let windowRect = convert(localRect, to: nil)
            wsElem.setAccessibilityFrame(window.convertToScreen(windowRect))
            wsElem.onPerformPress = { [weak self] in
                guard let self else { return false }
                self.showWorkspaceMenu(at: CGPoint(x: self.workspacePillRect.midX, y: self.workspacePillRect.midY))
                return true
            }
            elements.append(wsElem)
        }

        for tab in tabs {
            let tabElem = element("tab-\(tab.index)")
            tabElem.setAccessibilityRole(.radioButton)
            let title = titleFor(tab.window)
            tabElem.setAccessibilityTitle(title)
            tabElem.setAccessibilityLabel(title)
            tabElem.setAccessibilityIdentifier("tab-\(tab.index)")
            tabElem.setAccessibilityValue((tab.isActive ? 1 : 0) as NSNumber)
            tabElem.setAccessibilityHelp(paintedPillDots[ObjectIdentifier(tab.window)].map { "dot:\($0)" })
            let localRect = pillRect(for: tab)
            let windowRect = convert(localRect, to: nil)
            tabElem.setAccessibilityFrame(window.convertToScreen(windowRect))
            let tabWindow = tab.window
            tabElem.onPerformPress = { [weak self] in
                self?.group?.select(tabWindow)
                return true
            }
            elements.append(tabElem)
        }

        let plusElem = element("new-tab-button")
        plusElem.setAccessibilityRole(.button)
        plusElem.setAccessibilityLabel("New Tab")
        plusElem.setAccessibilityTitle("New Tab")
        plusElem.setAccessibilityIdentifier("new-tab-button")
        let plusWindowRect = convert(plusRect, to: nil)
        plusElem.setAccessibilityFrame(window.convertToScreen(plusWindowRect))
        plusElem.onPerformPress = { [weak self] in
            NSApp.sendAction(#selector(TerminalController.newTab(_:)), to: nil, from: self)
            return true
        }
        elements.append(plusElem)

        cachedAccessibilityChildren = elements
        return elements
    }
}
