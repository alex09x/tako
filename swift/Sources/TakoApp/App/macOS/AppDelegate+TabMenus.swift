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
import TakoKit

@MainActor
extension AppDelegate {
    // MARK: - Tab Navigation & Reordering Menus

    func setupTabNavigationMenuItems() {
        guard let mainMenu = NSApp.mainMenu else { return }
        guard menuPreviousTab == nil else { return }

        guard let windowMenu = mainMenu.items.first(where: { $0.title == "Window" })?.submenu else { return }

        let insertIndex = windowMenu.items.firstIndex(where: { $0.title == "Zoom Split" }) ?? 0

        let prevTab = NSMenuItem(
            title: "Select Previous Tab",
            action: #selector(TerminalController.previousTab(_:)),
            keyEquivalent: ""
        )
        prevTab.target = nil
        prevTab.setImageIfDesired(systemSymbolName: "chevron.left")
        windowMenu.insertItem(prevTab, at: insertIndex)
        self.menuPreviousTab = prevTab

        let nextTab = NSMenuItem(
            title: "Select Next Tab",
            action: #selector(TerminalController.nextTab(_:)),
            keyEquivalent: ""
        )
        nextTab.target = nil
        nextTab.setImageIfDesired(systemSymbolName: "chevron.right")
        windowMenu.insertItem(nextTab, at: insertIndex + 1)
        self.menuNextTab = nextTab

        let moveLeft = NSMenuItem(
            title: "Move Tab Backward",
            action: #selector(TerminalController.moveTabLeft(_:)),
            keyEquivalent: ""
        )
        moveLeft.target = nil
        moveLeft.setImageIfDesired(systemSymbolName: "arrow.left.square")
        windowMenu.insertItem(moveLeft, at: insertIndex + 2)
        self.menuMoveTabLeft = moveLeft

        let moveRight = NSMenuItem(
            title: "Move Tab Forward",
            action: #selector(TerminalController.moveTabRight(_:)),
            keyEquivalent: ""
        )
        moveRight.target = nil
        moveRight.setImageIfDesired(systemSymbolName: "arrow.right.square")
        windowMenu.insertItem(moveRight, at: insertIndex + 3)
        self.menuMoveTabRight = moveRight

        let selectTabItem = NSMenuItem(title: "Select Tab", action: nil, keyEquivalent: "")
        let selectTabSubmenu = NSMenu(title: "Select Tab")
        selectTabItem.submenu = selectTabSubmenu

        let selectors: [Selector] = [
            #selector(TerminalController.gotoTab1(_:)),
            #selector(TerminalController.gotoTab2(_:)),
            #selector(TerminalController.gotoTab3(_:)),
            #selector(TerminalController.gotoTab4(_:)),
            #selector(TerminalController.gotoTab5(_:)),
            #selector(TerminalController.gotoTab6(_:)),
            #selector(TerminalController.gotoTab7(_:)),
            #selector(TerminalController.gotoTab8(_:)),
            #selector(TerminalController.gotoTab9(_:)),
        ]

        var tabItems: [NSMenuItem] = []
        for (idx, sel) in selectors.enumerated() {
            let item = NSMenuItem(
                title: idx == 8 ? "Select Last Tab" : "Select Tab \(idx + 1)",
                action: sel,
                keyEquivalent: ""
            )
            item.target = nil
            selectTabSubmenu.addItem(item)
            tabItems.append(item)
        }
        self.menuGotoTabs = tabItems
        windowMenu.insertItem(selectTabItem, at: insertIndex + 4)
        windowMenu.insertItem(NSMenuItem.separator(), at: insertIndex + 5)
    }

    func syncTabShortcuts(_ config: Tako.Config) {
        if let zoom = self.menuZoomSplit ?? NSApp.mainMenu?.items.first(where: { $0.title == "Window" })?.submenu?.items.first(where: { $0.title == "Zoom Split" }) {
            self.menuZoomSplit = zoom
            syncMenuShortcut(config, action: "toggle_split_zoom", menuItem: zoom)
        }
        syncMenuShortcut(config, action: "goto_tab:previous", menuItem: self.menuPreviousTab)
        syncMenuShortcut(config, action: "goto_tab:next", menuItem: self.menuNextTab)
        syncMenuShortcut(config, action: "move_tab:-1", menuItem: self.menuMoveTabLeft)
        syncMenuShortcut(config, action: "move_tab:1", menuItem: self.menuMoveTabRight)
        for (idx, item) in menuGotoTabs.enumerated() {
            syncMenuShortcut(config, action: "goto_tab:\(idx + 1)", menuItem: item)
        }
    }

    // MARK: - Dedicated Workspace Menu

    func setupWorkspaceTopLevelMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }

        let wsMenu: NSMenu
        if let existing = mainMenu.items.first(where: { $0.title == "Workspace" })?.submenu {
            wsMenu = existing
            wsMenu.removeAllItems()
        } else {
            wsMenu = NSMenu(title: "Workspace")
            let wsMenuItem = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
            wsMenuItem.submenu = wsMenu
            if let windowIdx = mainMenu.items.firstIndex(where: { $0.title == "Window" }) {
                mainMenu.insertItem(wsMenuItem, at: windowIdx)
            } else {
                mainMenu.addItem(wsMenuItem)
            }
        }

        let newWs = NSMenuItem(title: "New Workspace…", action: #selector(newWorkspace(_:)), keyEquivalent: "n")
        newWs.keyEquivalentModifierMask = [.control, .option]
        newWs.target = nil
        newWs.setImageIfDesired(systemSymbolName: "plus.rectangle.on.folder")
        wsMenu.addItem(newWs)

        let nextWs = NSMenuItem(title: "Next Workspace", action: #selector(nextWorkspace(_:)), keyEquivalent: "]")
        nextWs.keyEquivalentModifierMask = [.control, .option]
        nextWs.target = nil
        nextWs.setImageIfDesired(systemSymbolName: "chevron.right.2")
        wsMenu.addItem(nextWs)

        let prevWs = NSMenuItem(title: "Previous Workspace", action: #selector(previousWorkspace(_:)), keyEquivalent: "[")
        prevWs.keyEquivalentModifierMask = [.control, .option]
        prevWs.target = nil
        prevWs.setImageIfDesired(systemSymbolName: "chevron.left.2")
        wsMenu.addItem(prevWs)

        wsMenu.addItem(NSMenuItem.separator())

        let store = WorkspaceStore.shared
        for ws in store.workspaces {
            let attention = store.attentionCount(for: ws)
            let title = attention > 0 ? "\(ws.name) (\(attention))" : ws.name
            let item = NSMenuItem(title: title, action: #selector(selectWorkspaceFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ws.id
            if ws.id == store.activeWorkspaceId {
                item.state = .on
            }
            wsMenu.addItem(item)
        }
    }

    @objc func selectWorkspaceFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID {
            WorkspaceStore.shared.switchWorkspace(to: id)
        }
    }

    // MARK: - Fallback Tab Responders

    private var activeTerminalController: TerminalController? {
        (NSApp.keyWindow?.windowController as? TerminalController) ?? TerminalController.all.first
    }

    @IBAction func gotoTab1(_ sender: Any?) { activeTerminalController?.gotoTab1(sender) }
    @IBAction func gotoTab2(_ sender: Any?) { activeTerminalController?.gotoTab2(sender) }
    @IBAction func gotoTab3(_ sender: Any?) { activeTerminalController?.gotoTab3(sender) }
    @IBAction func gotoTab4(_ sender: Any?) { activeTerminalController?.gotoTab4(sender) }
    @IBAction func gotoTab5(_ sender: Any?) { activeTerminalController?.gotoTab5(sender) }
    @IBAction func gotoTab6(_ sender: Any?) { activeTerminalController?.gotoTab6(sender) }
    @IBAction func gotoTab7(_ sender: Any?) { activeTerminalController?.gotoTab7(sender) }
    @IBAction func gotoTab8(_ sender: Any?) { activeTerminalController?.gotoTab8(sender) }
    @IBAction func gotoTab9(_ sender: Any?) { activeTerminalController?.gotoTab9(sender) }

    @IBAction func previousTab(_ sender: Any?) { activeTerminalController?.previousTab(sender) }
    @IBAction func nextTab(_ sender: Any?) { activeTerminalController?.nextTab(sender) }
    @IBAction func moveTabLeft(_ sender: Any?) { activeTerminalController?.moveTabLeft(sender) }
    @IBAction func moveTabRight(_ sender: Any?) { activeTerminalController?.moveTabRight(sender) }

    @IBAction func splitZoom(_ sender: Any?) { activeTerminalController?.splitZoom(sender ?? self) }
    @IBAction func splitMoveFocusPrevious(_ sender: Any?) { activeTerminalController?.splitMoveFocusPrevious(sender ?? self) }
    @IBAction func splitMoveFocusNext(_ sender: Any?) { activeTerminalController?.splitMoveFocusNext(sender ?? self) }
    @IBAction func splitMoveFocusAbove(_ sender: Any?) { activeTerminalController?.splitMoveFocusAbove(sender ?? self) }
    @IBAction func splitMoveFocusBelow(_ sender: Any?) { activeTerminalController?.splitMoveFocusBelow(sender ?? self) }
    @IBAction func splitMoveFocusLeft(_ sender: Any?) { activeTerminalController?.splitMoveFocusLeft(sender ?? self) }
    @IBAction func splitMoveFocusRight(_ sender: Any?) { activeTerminalController?.splitMoveFocusRight(sender ?? self) }
    @IBAction func equalizeSplits(_ sender: Any?) { activeTerminalController?.equalizeSplits(sender ?? self) }
    @IBAction func moveSplitDividerUp(_ sender: Any?) { activeTerminalController?.moveSplitDividerUp(sender ?? self) }
    @IBAction func moveSplitDividerDown(_ sender: Any?) { activeTerminalController?.moveSplitDividerDown(sender ?? self) }
    @IBAction func moveSplitDividerLeft(_ sender: Any?) { activeTerminalController?.moveSplitDividerLeft(sender ?? self) }
    @IBAction func moveSplitDividerRight(_ sender: Any?) { activeTerminalController?.moveSplitDividerRight(sender ?? self) }
}
