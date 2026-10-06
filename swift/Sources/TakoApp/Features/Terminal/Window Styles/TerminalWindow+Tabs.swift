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
import SwiftUI
import TakoKit

extension TerminalWindow {
    @discardableResult
    func beginInlineTabTitleEdit(for targetWindow: NSWindow) -> Bool {
        tabTitleEditor.beginEditing(for: targetWindow)
    }

    @objc func renameTabFromContextMenu(_ sender: NSMenuItem) {
        let targetWindow = sender.representedObject as? NSWindow ?? self
        if beginInlineTabTitleEdit(for: targetWindow) {
            return
        }

        guard let targetController = targetWindow.windowController as? BaseTerminalController else { return }
        targetController.promptTabTitle()
    }

        super.removeTitlebarAccessoryViewController(at: index)
    }

    // MARK: Tab Bar

    /// This identifier is attached to the tab bar view controller when we detect it being
    /// added.
    static let tabBarIdentifier: NSUserInterfaceItemIdentifier = .init("_takoTabBar")

    var hasMoreThanOneTabs: Bool {
        /// accessing ``tabGroup?.windows`` here
        /// will cause other edge cases, be careful
        (tabbedWindows?.count ?? 0) > 1
    }

    func isTabBar(_ childViewController: NSTitlebarAccessoryViewController) -> Bool {
        if childViewController.identifier == nil {
            // The good case
            if childViewController.view.contains(className: "NSTabBar") {
                return true
            }

            // When a new window is attached to an existing tab group, AppKit adds
            // an empty NSView as an accessory view and adds the tab bar later. If
            // we're at the bottom and are a single NSView we assume its a tab bar.
            if childViewController.layoutAttribute == .bottom &&
                childViewController.view.className == "NSView" &&
                childViewController.view.subviews.isEmpty {
                return true
            }

            return false
        }

        // View controllers should be tagged with this as soon as possible to
        // increase our accuracy. We do this manually.
        return childViewController.identifier == Self.tabBarIdentifier
    }

    func tabBarDidAppear() {
        // Remove our reset zoom accessory. For some reason having a SwiftUI
        // titlebar accessory causes our content view scaling to be wrong.
        // Removing it fixes it, we just need to remember to add it again later.
        if let idx = titlebarAccessoryViewControllers.firstIndex(of: resetZoomAccessory) {
            removeTitlebarAccessoryViewController(at: idx)
        }

        // We don't need to do this with the update accessory. I don't know why but
        // everything works fine.
    }

    func tabBarDidDisappear() {
        if styleMask.contains(.titled) {
            if titlebarAccessoryViewControllers.firstIndex(of: resetZoomAccessory) == nil {
                addTitlebarAccessoryViewController(resetZoomAccessory)
            }
}

// MARK: - Tab Context Menu

extension TerminalWindow {
    private static let closeTabsOnRightMenuItemIdentifier = NSUserInterfaceItemIdentifier("com.tako-core.terminal.closeTabsOnTheRightMenuItem")
    private static let changeTitleMenuItemIdentifier = NSUserInterfaceItemIdentifier("com.tako-core.terminal.changeTitleMenuItem")
    private static let tabColorSeparatorIdentifier = NSUserInterfaceItemIdentifier("com.tako-core.terminal.tabColorSeparator")

    private static let tabColorPaletteIdentifier = NSUserInterfaceItemIdentifier("com.tako-core.terminal.tabColorPalette")

    func configureTabContextMenuIfNeeded(_ menu: NSMenu) {
        guard isTabContextMenu(menu) else { return }

        // Get the target from an existing menu item. The native tab context menu items
        // target the specific window/controller that was right-clicked, not the focused one.
        // We need to use that same target so validation and action use the correct tab.
        let targetController = menu.items
            .first { $0.action == NSSelectorFromString("performClose:") }
            .flatMap { $0.target as? NSWindow }
            .flatMap { $0.windowController as? TerminalController }

        // Close tabs to the right
        let item = NSMenuItem(title: "Close Tabs to the Right", action: #selector(TerminalController.closeTabsOnTheRight(_:)), keyEquivalent: "")
        item.identifier = Self.closeTabsOnRightMenuItemIdentifier
        item.target = targetController
        item.setImageIfDesired(systemSymbolName: "xmark")
        if menu.insertItem(item, after: NSSelectorFromString("performCloseOtherTabs:")) == nil,
           menu.insertItem(item, after: NSSelectorFromString("performClose:")) == nil {
            menu.addItem(item)
        }

        // Other close items should have the xmark to match Safari on macOS 26
        for menuItem in menu.items {
            if menuItem.action == NSSelectorFromString("performClose:") ||
                menuItem.action == NSSelectorFromString("performCloseOtherTabs:") {
                menuItem.setImageIfDesired(systemSymbolName: "xmark")
            }
        }

        appendTabModifierSection(to: menu, target: targetController)
    }

    /// Whether this window currently counts as "key" for tab-context-menu
    /// purposes. Tests substitute this: a non-interactive test host cannot
    /// reliably grant this process real key-window status via
    /// `makeKeyAndOrderFront`, which would make `configureTabContextMenuIfNeeded`'s
    /// body permanently unreachable from a test host.
    struct System {
        var isKeyWindow: (TerminalWindow) -> Bool = { $0 === NSApp.keyWindow }
    }

    static var system = System()

    private func isTabContextMenu(_ menu: NSMenu) -> Bool {
        guard Self.system.isKeyWindow(self) else { return false }

        // These selectors must all exist for it to be a tab context menu.
        let requiredSelectors: Set<String> = [
            "performClose:",
            "performCloseOtherTabs:",
            "moveTabToNewWindow:",
            "toggleTabOverview:"
        ]

        let selectorNames = Set(menu.items.compactMap { $0.action }.map { NSStringFromSelector($0) })
        return requiredSelectors.isSubset(of: selectorNames)
    }

    private func appendTabModifierSection(to menu: NSMenu, target: TerminalController?) {
        menu.removeItems(withIdentifiers: [
            Self.tabColorSeparatorIdentifier,
            Self.changeTitleMenuItemIdentifier,
            Self.tabColorPaletteIdentifier
        ])

        let separator = NSMenuItem.separator()
        separator.identifier = Self.tabColorSeparatorIdentifier
        menu.addItem(separator)

        // Rename Tab...
        let changeTitleItem = NSMenuItem(title: "Rename Tab...", action: #selector(TerminalWindow.renameTabFromContextMenu(_:)), keyEquivalent: "")
        changeTitleItem.identifier = Self.changeTitleMenuItemIdentifier
        changeTitleItem.target = self
        changeTitleItem.representedObject = target?.window
        changeTitleItem.setImageIfDesired(systemSymbolName: "pencil.line")
        menu.addItem(changeTitleItem)

        let paletteItem = NSMenuItem()
        paletteItem.identifier = Self.tabColorPaletteIdentifier
        paletteItem.view = makeTabColorPaletteView(
            selectedColor: (target?.window as? TerminalWindow)?.tabColor ?? .none
        ) { [weak target] color in
            (target?.window as? TerminalWindow)?.tabColor = color
        }
        menu.addItem(paletteItem)
    }
}

private func makeTabColorPaletteView(
    selectedColor: TerminalTabColor,
    selectionHandler: @escaping (TerminalTabColor) -> Void
) -> NSView {
    let hostingView = NSHostingView(rootView: TabColorMenuView(
        selectedColor: selectedColor,
        onSelect: selectionHandler
    ))
    hostingView.frame.size = hostingView.intrinsicContentSize
    return hostingView
}

// MARK: - Inline Tab Title Editing

extension TerminalWindow: TabTitleEditorDelegate {
    func tabTitleEditor(
        _ editor: TabTitleEditor,
        canRenameTabFor targetWindow: NSWindow
    ) -> Bool {
        targetWindow.windowController is BaseTerminalController
    }

    func tabTitleEditor(
        _ editor: TabTitleEditor,
        titleFor targetWindow: NSWindow
    ) -> String {
        guard let targetController = targetWindow.windowController as? BaseTerminalController else {
            return targetWindow.title
        }

        return targetController.titleOverride ?? targetWindow.title
    }

    func tabTitleEditor(
        _ editor: TabTitleEditor,
        didCommitTitle editedTitle: String,
        for targetWindow: NSWindow
    ) {
        guard let targetController = targetWindow.windowController as? BaseTerminalController else { return }
        targetController.titleOverride = editedTitle.isEmpty ? nil : editedTitle
    }

    func tabTitleEditor(
        _ editor: TabTitleEditor,
        performFallbackRenameFor targetWindow: NSWindow
    ) {
        guard let targetController = targetWindow.windowController as? BaseTerminalController else { return }
        targetController.promptTabTitle()
    }

    func tabTitleEditor(_ editor: TabTitleEditor, didFinishEditing targetWindow: NSWindow) {
        // After inline editing, the first responder is the window itself.
        // Restore focus to the terminal surface so keyboard input works.
        guard let controller = windowController as? BaseTerminalController,
              let focusedSurface = controller.focusedSurface
        else { return }
        makeFirstResponder(focusedSurface)
    }
}
