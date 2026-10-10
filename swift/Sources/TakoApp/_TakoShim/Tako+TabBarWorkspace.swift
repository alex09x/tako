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

extension Tako.TabBarView {
    func drawWorkspacePill(in ctx: CGContext) {
        guard showsWorkspacePill else { return }
        let rect = workspacePillRect
        let ws = WorkspaceStore.shared.activeWorkspace
        let attention = WorkspaceStore.shared.attentionCount(for: ws)

        // Background pill
        ctx.setFillColor(workspaceHovered ? Palette.hoverTab.cgColor : Palette.badge.cgColor)
        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()

        // Color dot
        let dotColor: NSColor
        switch ws.color?.lowercased() {
        case "red": dotColor = Tako.Brand.error
        case "green": dotColor = Tako.Brand.ok
        case "orange": dotColor = Tako.Brand.ember
        case "purple": dotColor = NSColor.systemPurple
        case "yellow": dotColor = NSColor.systemYellow
        default: dotColor = NSColor.systemBlue
        }
        ctx.setFillColor(dotColor.cgColor)
        let dotRect = CGRect(x: rect.minX + 8, y: rect.midY - 3.5, width: 7, height: 7)
        ctx.fillEllipse(in: dotRect)

        // Workspace title
        let maxTitleWidth = rect.width - 24 - (attention > 0 ? 20 : 0)
        let title = Tako.TabText.truncate(ws.name, to: maxTitleWidth, font: Fonts.badge)
        let textColor = workspaceHovered ? Palette.activeText : Palette.inactiveText
        Tako.TabText.draw(title, atX: dotRect.maxX + 6, centeredAtY: rect.midY,
                          font: Fonts.badge, color: textColor, context: ctx)

        // Attention badge if > 0
        if attention > 0 {
            let badgeRect = CGRect(x: rect.maxX - 18, y: rect.midY - 6, width: 14, height: 12)
            ctx.setFillColor(Tako.Brand.ember.cgColor)
            ctx.addPath(CGPath(roundedRect: badgeRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
            let countStr = attention > 9 ? "9+" : "\(attention)"
            Tako.TabText.draw(countStr, atX: badgeRect.minX + 3, centeredAtY: badgeRect.midY,
                              font: Fonts.timer, color: Palette.bar, context: ctx)
        }
    }

    private static var shouldPresentNewWorkspaceDialog = false

    func showWorkspaceMenu(at point: CGPoint) {
        Self.shouldPresentNewWorkspaceDialog = false
        let menu = NSMenu()
        menu.autoenablesItems = false
        let store = WorkspaceStore.shared
        for ws in store.workspaces {
            let attention = store.attentionCount(for: ws)
            let title = attention > 0 ? "\(ws.name) (\(attention))" : ws.name
            let item = NSMenuItem(title: title, action: #selector(handleWorkspaceSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ws.id
            item.isEnabled = true
            if ws.id == store.activeWorkspaceId {
                item.state = .on
            }
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        let nextItem = NSMenuItem(title: "Next Workspace", action: #selector(handleNextWorkspace), keyEquivalent: "]")
        nextItem.keyEquivalentModifierMask = [.control, .option]
        nextItem.target = self
        nextItem.isEnabled = true
        menu.addItem(nextItem)

        let prevItem = NSMenuItem(title: "Previous Workspace", action: #selector(handlePreviousWorkspace), keyEquivalent: "[")
        prevItem.keyEquivalentModifierMask = [.control, .option]
        prevItem.target = self
        prevItem.isEnabled = true
        menu.addItem(prevItem)

        menu.addItem(NSMenuItem.separator())
        let newItem = NSMenuItem(title: "New Workspace...", action: #selector(handleNewWorkspace), keyEquivalent: "")
        newItem.target = self
        newItem.isEnabled = true
        menu.addItem(newItem)

        menu.popUp(positioning: nil, at: point, in: self)
        menu.cancelTrackingWithoutAnimation()
        for w in NSApp.windows where String(describing: type(of: w)).contains("Menu") {
            w.orderOut(nil)
        }

        if Self.shouldPresentNewWorkspaceDialog {
            Self.shouldPresentNewWorkspaceDialog = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.presentNewWorkspaceDialog()
            }
        }
    }

    @objc func handleWorkspaceSelected(_ sender: NSMenuItem) {
        let id = sender.representedObject as? UUID
        let title = sender.title
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let id {
                WorkspaceStore.shared.switchWorkspace(to: id)
            } else {
                _ = WorkspaceStore.shared.switchWorkspace(named: title)
            }
        }
    }

    @objc func handleNextWorkspace() {
        WorkspaceStore.shared.nextWorkspace()
    }

    @objc func handlePreviousWorkspace() {
        WorkspaceStore.shared.previousWorkspace()
    }

    @objc func handleNewWorkspace() {
        Self.shouldPresentNewWorkspaceDialog = true
    }

    private func presentNewWorkspaceDialog() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "New Project Workspace"
        alert.informativeText = "Enter a name for the new workspace:"
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.placeholderString = "e.g. backend, docs, tako"
        alert.accessoryView = input
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        alert.window.orderOut(nil)
        if response == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = name.isEmpty ? "Workspace \(WorkspaceStore.shared.workspaces.count + 1)" : name
            let ws = WorkspaceStore.shared.createWorkspace(name: finalName)
            DispatchQueue.main.async {
                WorkspaceStore.shared.switchWorkspace(to: ws.id)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
