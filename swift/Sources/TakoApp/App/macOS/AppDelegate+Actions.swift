/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Cocoa
import SwiftUI
import TakoKit

extension AppDelegate {
    // MARK: - IB Actions

    @IBAction func openConfig(_ sender: Any?) {
        tako.openConfig()
    }

    @IBAction func reloadConfig(_ sender: Any?) {
        tako.reloadConfig()
    }

    @IBAction func newWindow(_ sender: Any?) {
        _ = TerminalController.newWindow(tako)
    }

    @IBAction func newTab(_ sender: Any?) {
        _ = TerminalController.newTab(
            tako,
            from: TerminalController.preferredParent?.window
        )
    }

    @IBAction func closeAllWindows(_ sender: Any?) {
        TerminalController.closeAllWindows()
        AboutController.shared.hide()
    }

    @IBAction func showAbout(_ sender: Any?) {
        AboutController.shared.show()
    }

    @IBAction func showWhatsNew(_ sender: Any?) {
        WhatsNewNotice.showWhatsNew(force: true, theme: tako.config.theme)
    }

    func setupWhatsNewMenuItem() {
        guard let takoMenu = NSApp.mainMenu?.items.first?.submenu,
              !takoMenu.items.contains(where: { $0.action == #selector(showWhatsNew) })
        else { return }
        let item = NSMenuItem(title: "What's New in Tako…", action: #selector(showWhatsNew), keyEquivalent: "")
        item.target = self
        item.setImageIfDesired(systemSymbolName: "sparkles")
        takoMenu.insertItem(item, at: min(1, takoMenu.items.count))
    }

    @IBAction func checkForUpdates(_ sender: Any?) {
        AppUpdater.shared.checkForUpdates(silent: false)
    }

    @IBAction func installCommandLineTool(_ sender: Any?) {
        CommandLineTool.installFromMenu(theme: tako.config.theme)
    }

    func setupCommandLineToolMenuItem() {
        guard let takoMenu = NSApp.mainMenu?.items.first?.submenu,
              !takoMenu.items.contains(where: { $0.action == #selector(installCommandLineTool) })
        else { return }
        let item = NSMenuItem(title: "Install takoctl Command…", action: #selector(installCommandLineTool), keyEquivalent: "")
        item.target = self
        item.setImageIfDesired(systemSymbolName: "terminal")
        takoMenu.insertItem(item, at: min(2, takoMenu.items.count))
    }

    func setupUpdateMenuItem() {
        guard let takoMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        if takoMenu.items.contains(where: { $0.action == #selector(checkForUpdates) }) {
            return
        }
        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updateItem.target = self
        updateItem.setImageIfDesired(systemSymbolName: "arrow.trianglehead.2.clockwise.rotate.90")
        takoMenu.insertItem(updateItem, at: min(1, takoMenu.items.count))
    }

    func setupPromptNavigationMenuItems() {
        guard let mainMenu = NSApp.mainMenu else { return }

        // Setup in Edit menu: "Select Command Output"
        if menuSelectCommandOutput == nil,
           let editMenu = mainMenu.items.first(where: { $0.title == "Edit" })?.submenu {
            let item = NSMenuItem(
                title: "Select Command Output",
                action: #selector(BaseTerminalController.selectCommandOutput(_:)),
                keyEquivalent: ""
            )
            item.target = nil
            if let selectAllIdx = editMenu.items.firstIndex(where: { $0.action == #selector(NSStandardKeyBindingResponding.selectAll(_:)) }) {
                editMenu.insertItem(item, at: selectAllIdx + 1)
            } else {
                editMenu.addItem(item)
            }
            self.menuSelectCommandOutput = item
        }

        // Setup in View menu: "Jump to Previous Mark" & "Jump to Next Mark"
        if (menuJumpToPreviousPrompt == nil || menuJumpToNextPrompt == nil),
           let viewMenu = mainMenu.items.first(where: { $0.title == "View" })?.submenu {
            if menuJumpToPreviousPrompt == nil {
                let prevItem = NSMenuItem(
                    title: "Jump to Previous Mark",
                    action: #selector(BaseTerminalController.jumpToPreviousPrompt(_:)),
                    keyEquivalent: ""
                )
                prevItem.target = nil
                prevItem.setImageIfDesired(systemSymbolName: "arrow.up.to.line")
                viewMenu.addItem(prevItem)
                self.menuJumpToPreviousPrompt = prevItem
            }
            if menuJumpToNextPrompt == nil {
                let nextItem = NSMenuItem(
                    title: "Jump to Next Mark",
                    action: #selector(BaseTerminalController.jumpToNextPrompt(_:)),
                    keyEquivalent: ""
                )
                nextItem.target = nil
                nextItem.setImageIfDesired(systemSymbolName: "arrow.down.to.line")
                viewMenu.addItem(nextItem)
                self.menuJumpToNextPrompt = nextItem
            }
        }
    }

    func setupNotificationMenuItems() {
        guard let mainMenu = NSApp.mainMenu else { return }

        // Setup in Window menu
        if let windowMenu = mainMenu.items.first(where: { $0.title == "Window" })?.submenu {
            windowMenu.addItem(NSMenuItem.separator())

            let centerItem = NSMenuItem(
                title: "Notification Center",
                action: #selector(BaseTerminalController.toggleNotificationCenter(_:)),
                keyEquivalent: "n"
            )
            centerItem.keyEquivalentModifierMask = [.command, .option]
            centerItem.target = nil
            centerItem.setImageIfDesired(systemSymbolName: "bell")
            windowMenu.addItem(centerItem)

            let jumpItem = NSMenuItem(
                title: "Jump to Latest Unread",
                action: #selector(BaseTerminalController.jumpToLatestUnread(_:)),
                keyEquivalent: "N"
            )
            jumpItem.keyEquivalentModifierMask = [.command, .shift]
            jumpItem.target = nil
            jumpItem.setImageIfDesired(systemSymbolName: "arrow.right.circle")
            windowMenu.addItem(jumpItem)

            let markReadItem = NSMenuItem(
                title: "Mark Read",
                action: #selector(BaseTerminalController.markFocusedPaneRead(_:)),
                keyEquivalent: ""
            )
            markReadItem.target = nil
            markReadItem.setImageIfDesired(systemSymbolName: "checkmark")
            windowMenu.addItem(markReadItem)

            let markAllReadItem = NSMenuItem(
                title: "Mark All Read",
                action: #selector(BaseTerminalController.markAllRead(_:)),
                keyEquivalent: "U"
            )
            markAllReadItem.keyEquivalentModifierMask = [.command, .shift]
            markAllReadItem.target = nil
            markAllReadItem.setImageIfDesired(systemSymbolName: "checkmark.circle")
            windowMenu.addItem(markAllReadItem)
        }
    }

    func setupSidebarMenuItem() {
        guard let mainMenu = NSApp.mainMenu else { return }

        if let viewMenu = mainMenu.items.first(where: { $0.title == "View" })?.submenu {
            viewMenu.addItem(NSMenuItem.separator())

            let sidebarItem = NSMenuItem(
                title: "Session Sidebar",
                action: #selector(BaseTerminalController.toggleSessionSidebar(_:)),
                keyEquivalent: "s"
            )
            sidebarItem.keyEquivalentModifierMask = [.command, .option]
            sidebarItem.target = nil
            sidebarItem.setImageIfDesired(systemSymbolName: "sidebar.left")
            viewMenu.addItem(sidebarItem)
        }
    }

    func setupPaneOverviewMenuItem() {
        guard let mainMenu = NSApp.mainMenu else { return }

        if let viewMenu = mainMenu.items.first(where: { $0.title == "View" })?.submenu {
            let overviewItem = NSMenuItem(
                title: "Pane Overview",
                action: #selector(BaseTerminalController.togglePaneOverview(_:)),
                keyEquivalent: "O"
            )
            overviewItem.keyEquivalentModifierMask = [.command, .shift]
            overviewItem.target = nil
            overviewItem.setImageIfDesired(systemSymbolName: "square.grid.2x2")
            viewMenu.addItem(overviewItem)
        }
    }

    func setupAttentionMenuItems() {
        guard let mainMenu = NSApp.mainMenu else { return }

        if let windowMenu = mainMenu.items.first(where: { $0.title == "Window" })?.submenu {
            windowMenu.addItem(NSMenuItem.separator())

            let nextAttentionItem = NSMenuItem(
                title: "Next Attention",
                action: #selector(BaseTerminalController.jumpToNextAttention(_:)),
                keyEquivalent: "]"
            )
            nextAttentionItem.keyEquivalentModifierMask = [.command, .option]
            nextAttentionItem.target = nil
            nextAttentionItem.setImageIfDesired(systemSymbolName: "arrow.down.right.circle")
            windowMenu.addItem(nextAttentionItem)

            let prevAttentionItem = NSMenuItem(
                title: "Previous Attention",
                action: #selector(BaseTerminalController.jumpToPreviousAttention(_:)),
                keyEquivalent: "["
            )
            prevAttentionItem.keyEquivalentModifierMask = [.command, .option]
            prevAttentionItem.target = nil
            prevAttentionItem.setImageIfDesired(systemSymbolName: "arrow.up.left.circle")
            windowMenu.addItem(prevAttentionItem)

            let goBackItem = NSMenuItem(
                title: "Go Back to Previous Pane",
                action: #selector(BaseTerminalController.goBackToPreviousPane(_:)),
                keyEquivalent: "b"
            )
            goBackItem.keyEquivalentModifierMask = [.command, .option]
            goBackItem.target = nil
            goBackItem.setImageIfDesired(systemSymbolName: "arrow.uturn.backward.circle")
            windowMenu.addItem(goBackItem)

            let muteItem = NSMenuItem(
                title: "Mute Attention",
                action: #selector(BaseTerminalController.toggleAttentionMute(_:)),
                keyEquivalent: "m"
            )
            muteItem.keyEquivalentModifierMask = [.command, .option]
            muteItem.target = nil
            muteItem.setImageIfDesired(systemSymbolName: "bell.slash")
            windowMenu.addItem(muteItem)
        }
    }

    func setupWorkspaceMenuItems() {
        guard let mainMenu = NSApp.mainMenu else { return }

        if let windowMenu = mainMenu.items.first(where: { $0.title == "Window" })?.submenu {
            windowMenu.addItem(NSMenuItem.separator())

            let nextWorkspaceItem = NSMenuItem(
                title: "Next Workspace",
                action: #selector(nextWorkspace(_:)),
                keyEquivalent: "]"
            )
            nextWorkspaceItem.keyEquivalentModifierMask = [.control, .option]
            nextWorkspaceItem.target = nil
            nextWorkspaceItem.setImageIfDesired(systemSymbolName: "chevron.right.2")
            windowMenu.addItem(nextWorkspaceItem)

            let prevWorkspaceItem = NSMenuItem(
                title: "Previous Workspace",
                action: #selector(previousWorkspace(_:)),
                keyEquivalent: "["
            )
            prevWorkspaceItem.keyEquivalentModifierMask = [.control, .option]
            prevWorkspaceItem.target = nil
            prevWorkspaceItem.setImageIfDesired(systemSymbolName: "chevron.left.2")
            windowMenu.addItem(prevWorkspaceItem)

            let newWorkspaceItem = NSMenuItem(
                title: "New Workspace…",
                action: #selector(newWorkspace(_:)),
                keyEquivalent: "n"
            )
            newWorkspaceItem.keyEquivalentModifierMask = [.control, .option]
            newWorkspaceItem.target = nil
            newWorkspaceItem.setImageIfDesired(systemSymbolName: "plus.rectangle.on.folder")
            windowMenu.addItem(newWorkspaceItem)
        }
    }

    @IBAction func exportDiagnostics(_ sender: Any?) {
        DiagnosticsExporter.exportToFile()
    }

    func setupDiagnosticsMenuItem() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let helpMenu = mainMenu.items.first(where: { $0.title == "Help" || $0.submenu?.title == "Help" })?.submenu ?? NSApp.helpMenu
        guard let helpMenu,
              !helpMenu.items.contains(where: { $0.action == #selector(exportDiagnostics) })
        else { return }
        let item = NSMenuItem(title: "Export Diagnostics…", action: #selector(exportDiagnostics), keyEquivalent: "")
        item.target = self
        item.setImageIfDesired(systemSymbolName: "stethoscope")
        helpMenu.addItem(NSMenuItem.separator())
        helpMenu.addItem(item)
    }

    @IBAction func jumpToNextAttention(_ sender: Any?) {
        guard let controller = NSApp.keyWindow?.windowController as? BaseTerminalController ??
                TerminalController.all.first else { return }
        controller.jumpToNextAttention(sender)
    }

    @IBAction func jumpToPreviousAttention(_ sender: Any?) {
        guard let controller = NSApp.keyWindow?.windowController as? BaseTerminalController ??
                TerminalController.all.first else { return }
        controller.jumpToPreviousAttention(sender)
    }

    @IBAction func goBackToPreviousPane(_ sender: Any?) {
        guard let controller = NSApp.keyWindow?.windowController as? BaseTerminalController ??
                TerminalController.all.first else { return }
        controller.goBackToPreviousPane(sender)
    }

    @IBAction func toggleAttentionMute(_ sender: Any?) {
        guard let controller = NSApp.keyWindow?.windowController as? BaseTerminalController ??
                TerminalController.all.first else { return }
        controller.toggleAttentionMute(sender)
    }

    @IBAction func togglePaneOverview(_ sender: Any?) {
        guard let controller = NSApp.keyWindow?.windowController as? BaseTerminalController ??
                TerminalController.all.first else { return }
        controller.togglePaneOverview(sender)
    }

    @IBAction func toggleSessionSidebar(_ sender: Any?) {
        guard let controller = NSApp.keyWindow?.windowController as? BaseTerminalController ??
                TerminalController.all.first else { return }
        controller.toggleSessionSidebar(sender)
    }

    @IBAction func toggleNotificationCenter(_ sender: Any?) {
        guard let controller = NSApp.keyWindow?.windowController as? BaseTerminalController ??
                TerminalController.all.first else { return }
        controller.toggleNotificationCenter(sender)
    }

    @IBAction func jumpToLatestUnread(_ sender: Any?) {
        guard let controller = NSApp.keyWindow?.windowController as? BaseTerminalController ??
                TerminalController.all.first else { return }
        controller.jumpToLatestUnread(sender)
    }

    @IBAction func markFocusedPaneRead(_ sender: Any?) {
        guard let controller = NSApp.keyWindow?.windowController as? BaseTerminalController ??
                TerminalController.all.first else { return }
        controller.markFocusedPaneRead(sender)
    }

    @IBAction func markAllRead(_ sender: Any?) {
        NotificationStore.shared.markAllRead()
    }

}
