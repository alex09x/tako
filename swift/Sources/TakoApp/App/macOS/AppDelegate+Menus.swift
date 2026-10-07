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

// MARK: - Menu

extension AppDelegate {
    /// This is called for the dock right-click menu.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        return dockMenu
    }

    func reloadDockMenu() {
        let newWindow = NSMenuItem(title: "New Window", action: #selector(newWindow), keyEquivalent: "")
        let newTab = NSMenuItem(title: "New Tab", action: #selector(newTab), keyEquivalent: "")

        dockMenu.removeAllItems()
        dockMenu.addItem(newWindow)
        dockMenu.addItem(newTab)
    }

    /// Setup all the images for our menu items.
    func setupMenuImages() {
        // Note: This COULD Be done all in the xib file, but I find it easier to
        // modify this stuff as code.
        self.menuAbout?.setImageIfDesired(systemSymbolName: "info.circle")
        self.menuOpenConfig?.setImageIfDesired(systemSymbolName: "gear")
        self.menuReloadConfig?.setImageIfDesired(systemSymbolName: "arrow.trianglehead.2.clockwise.rotate.90")
        self.menuSecureInput?.setImageIfDesired(systemSymbolName: "lock.display")
        self.menuNewWindow?.setImageIfDesired(systemSymbolName: "macwindow.badge.plus")
        self.menuNewTab?.setImageIfDesired(systemSymbolName: "macwindow")
        self.menuSplitRight?.setImageIfDesired(systemSymbolName: "rectangle.righthalf.inset.filled")
        self.menuSplitLeft?.setImageIfDesired(systemSymbolName: "rectangle.leadinghalf.inset.filled")
        self.menuSplitUp?.setImageIfDesired(systemSymbolName: "rectangle.tophalf.inset.filled")
        self.menuSplitDown?.setImageIfDesired(systemSymbolName: "rectangle.bottomhalf.inset.filled")
        self.menuClose?.setImageIfDesired(systemSymbolName: "xmark")
        self.menuPasteSelection?.setImageIfDesired(systemSymbolName: "doc.on.clipboard.fill")
        self.menuIncreaseFontSize?.setImageIfDesired(systemSymbolName: "textformat.size.larger")
        self.menuResetFontSize?.setImageIfDesired(systemSymbolName: "textformat.size")
        self.menuDecreaseFontSize?.setImageIfDesired(systemSymbolName: "textformat.size.smaller")
        self.menuCommandPalette?.setImageIfDesired(systemSymbolName: "filemenu.and.selection")
        self.menuQuickTerminal?.setImageIfDesired(systemSymbolName: "apple.terminal")
        self.menuChangeTabTitle?.setImageIfDesired(systemSymbolName: "pencil.line")
        self.menuTerminalInspector?.setImageIfDesired(systemSymbolName: "scope")
        self.menuReadonly?.setImageIfDesired(systemSymbolName: "eye.fill")
        self.menuSetAsDefaultTerminal?.setImageIfDesired(systemSymbolName: "star.fill")
        self.menuToggleFullScreen?.setImageIfDesired(systemSymbolName: "square.arrowtriangle.4.outward")
        self.menuToggleVisibility?.setImageIfDesired(systemSymbolName: "eye")
        self.menuZoomSplit?.setImageIfDesired(systemSymbolName: "arrow.up.left.and.arrow.down.right")
        self.menuPreviousSplit?.setImageIfDesired(systemSymbolName: "chevron.backward.2")
        self.menuNextSplit?.setImageIfDesired(systemSymbolName: "chevron.forward.2")
        self.menuEqualizeSplits?.setImageIfDesired(systemSymbolName: "inset.filled.topleft.topright.bottomleft.bottomright.rectangle")
        self.menuSelectSplitLeft?.setImageIfDesired(systemSymbolName: "arrow.left")
        self.menuSelectSplitRight?.setImageIfDesired(systemSymbolName: "arrow.right")
        self.menuSelectSplitAbove?.setImageIfDesired(systemSymbolName: "arrow.up")
        self.menuSelectSplitBelow?.setImageIfDesired(systemSymbolName: "arrow.down")
        self.menuMoveSplitDividerUp?.setImageIfDesired(systemSymbolName: "arrow.up.to.line")
        self.menuMoveSplitDividerDown?.setImageIfDesired(systemSymbolName: "arrow.down.to.line")
        self.menuMoveSplitDividerLeft?.setImageIfDesired(systemSymbolName: "arrow.left.to.line")
        self.menuMoveSplitDividerRight?.setImageIfDesired(systemSymbolName: "arrow.right.to.line")
        self.menuFloatOnTop?.setImageIfDesired(systemSymbolName: "square.filled.on.square")
        self.menuFindParent?.setImageIfDesired(systemSymbolName: "text.page.badge.magnifyingglass")
    }

    /// Sync all of our menu item keyboard shortcuts with the Tako configuration.
    @MainActor func syncMenuShortcuts(_ config: Tako.Config) {
        guard tako.readiness == .ready else { return }

        setupPromptNavigationMenuItems()
        setupTabNavigationMenuItems()

        menuShortcutManager.reset()

        syncMenuShortcut(config, action: "open_config", menuItem: self.menuOpenConfig)
        syncMenuShortcut(config, action: "reload_config", menuItem: self.menuReloadConfig)
        syncMenuShortcut(config, action: "quit", menuItem: self.menuQuit)

        syncMenuShortcut(config, action: "new_window", menuItem: self.menuNewWindow)
        syncMenuShortcut(config, action: "new_tab", menuItem: self.menuNewTab)
        syncMenuShortcut(config, action: "close_surface", menuItem: self.menuClose)
        syncMenuShortcut(config, action: "close_tab", menuItem: self.menuCloseTab)
        syncMenuShortcut(config, action: "close_window", menuItem: self.menuCloseWindow)
        syncMenuShortcut(config, action: "close_all_windows", menuItem: self.menuCloseAllWindows)
        syncMenuShortcut(config, action: "new_split:right", menuItem: self.menuSplitRight)
        syncMenuShortcut(config, action: "new_split:left", menuItem: self.menuSplitLeft)
        syncMenuShortcut(config, action: "new_split:down", menuItem: self.menuSplitDown)
        syncMenuShortcut(config, action: "new_split:up", menuItem: self.menuSplitUp)

        syncMenuShortcut(config, action: "undo", menuItem: self.menuUndo)
        syncMenuShortcut(config, action: "redo", menuItem: self.menuRedo)
        syncMenuShortcut(config, action: "copy_to_clipboard", menuItem: self.menuCopy)
        syncMenuShortcut(config, action: "paste_from_clipboard", menuItem: self.menuPaste)
        syncMenuShortcut(config, action: "paste_from_selection", menuItem: self.menuPasteSelection)
        syncMenuShortcut(config, action: "select_all", menuItem: self.menuSelectAll)
        syncMenuShortcut(config, action: "select_command_output", menuItem: self.menuSelectCommandOutput)
        syncMenuShortcut(config, action: "start_search", menuItem: self.menuFind)
        syncMenuShortcut(config, action: "find_all", menuItem: self.menuFindAll)
        syncMenuShortcut(config, action: "end_search", menuItem: self.menuHideFindBar)
        syncMenuShortcut(config, action: "search_selection", menuItem: self.menuSelectionForFind)
        syncMenuShortcut(config, action: "scroll_to_selection", menuItem: self.menuScrollToSelection)
        syncMenuShortcut(config, action: "navigate_search:next", menuItem: self.menuFindNext)
        syncMenuShortcut(config, action: "navigate_search:previous", menuItem: self.menuFindPrevious)
        syncMenuShortcut(config, action: "jump_to_prompt:previous", menuItem: self.menuJumpToPreviousPrompt)
        syncMenuShortcut(config, action: "jump_to_prompt:next", menuItem: self.menuJumpToNextPrompt)

        syncMenuShortcut(config, action: "toggle_split_zoom", menuItem: self.menuZoomSplit)
        syncMenuShortcut(config, action: "goto_split:previous", menuItem: self.menuPreviousSplit)
        syncMenuShortcut(config, action: "goto_split:next", menuItem: self.menuNextSplit)
        syncMenuShortcut(config, action: "goto_split:up", menuItem: self.menuSelectSplitAbove)
        syncMenuShortcut(config, action: "goto_split:down", menuItem: self.menuSelectSplitBelow)
        syncMenuShortcut(config, action: "goto_split:left", menuItem: self.menuSelectSplitLeft)
        syncMenuShortcut(config, action: "goto_split:right", menuItem: self.menuSelectSplitRight)
        syncMenuShortcut(config, action: "resize_split:up,10", menuItem: self.menuMoveSplitDividerUp)
        syncMenuShortcut(config, action: "resize_split:down,10", menuItem: self.menuMoveSplitDividerDown)
        syncMenuShortcut(config, action: "resize_split:right,10", menuItem: self.menuMoveSplitDividerRight)
        syncMenuShortcut(config, action: "resize_split:left,10", menuItem: self.menuMoveSplitDividerLeft)
        syncMenuShortcut(config, action: "equalize_splits", menuItem: self.menuEqualizeSplits)
        syncMenuShortcut(config, action: "reset_window_size", menuItem: self.menuReturnToDefaultSize)

        syncMenuShortcut(config, action: "increase_font_size:1", menuItem: self.menuIncreaseFontSize)
        syncMenuShortcut(config, action: "decrease_font_size:1", menuItem: self.menuDecreaseFontSize)
        syncMenuShortcut(config, action: "reset_font_size", menuItem: self.menuResetFontSize)
        syncMenuShortcut(config, action: "prompt_surface_title", menuItem: self.menuChangeTitle)
        syncMenuShortcut(config, action: "prompt_tab_title", menuItem: self.menuChangeTabTitle)
        syncMenuShortcut(config, action: "toggle_quick_terminal", menuItem: self.menuQuickTerminal)
        syncMenuShortcut(config, action: "toggle_visibility", menuItem: self.menuToggleVisibility)
        syncMenuShortcut(config, action: "toggle_window_float_on_top", menuItem: self.menuFloatOnTop)
        syncMenuShortcut(config, action: "inspector:toggle", menuItem: self.menuTerminalInspector)
        syncMenuShortcut(config, action: "toggle_command_palette", menuItem: self.menuCommandPalette)

        syncMenuShortcut(config, action: "toggle_secure_input", menuItem: self.menuSecureInput)

        // This menu item is NOT synced with the configuration because it disables macOS
        // global fullscreen keyboard shortcut. The shortcut in the Tako config will continue
        // to work but it won't be reflected in the menu item.
        //
        // syncMenuShortcut(config, action: "toggle_fullscreen", menuItem: self.menuToggleFullScreen)

        syncTabShortcuts(config)

        // Dock menu
        reloadDockMenu()
    }

    @MainActor func syncMenuShortcut(_ config: Tako.Config, action: String, menuItem: NSMenuItem?) {
        menuShortcutManager.syncMenuShortcut(config, action: action, menuItem: menuItem)
    }

    @MainActor func performTakoBindingMenuKeyEquivalent(with event: NSEvent) -> Bool {
        menuShortcutManager.performTakoBindingMenuKeyEquivalent(with: event)
    }
}

// MARK: Floating Windows

extension AppDelegate {
    func syncFloatOnTopMenu(_ window: NSWindow?) {
        guard let window = (window ?? NSApp.keyWindow) as? TerminalWindow else {
            // If some other window became key we always turn this off
            self.menuFloatOnTop?.state = .off
            return
        }

        self.menuFloatOnTop?.state = window.level == .floating ? .on : .off
    }

    @IBAction func floatOnTop(_ menuItem: NSMenuItem) {
        menuItem.state = menuItem.state == .on ? .off : .on
        guard let window = NSApp.keyWindow else { return }
        window.level = menuItem.state == .on ? .floating : .normal
    }

    @IBAction func useAsDefault(_ sender: NSMenuItem) {
        let ud = UserDefaults.tako
        let key = TerminalWindow.defaultLevelKey
        if menuFloatOnTop?.state == .on {
            ud.set(NSWindow.Level.floating, forKey: key)
        } else {
            ud.removeObject(forKey: key)
        }
    }

    @IBAction func setAsDefaultTerminal(_ sender: NSMenuItem) {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .unixExecutable) { error in
            guard let error else { return }
            Task { @MainActor in
                let alert = NSAlert()
                alert.messageText = "Failed to Set Default Terminal"
                alert.informativeText = """
                Tako could not be set as the default terminal application.

                Error: \(error.localizedDescription)
                """
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}

// MARK: NSMenuItemValidation

@MainActor
extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(setAsDefaultTerminal(_:)):
            return NSWorkspace.shared.defaultTerminal != Bundle.main.bundleURL

        case #selector(floatOnTop(_:)),
            #selector(useAsDefault(_:)):
            // Float on top items only active if the key window is a primary
            // terminal window (not quick terminal).
            return NSApp.keyWindow is TerminalWindow

        case #selector(undo(_:)):
            if undoManager.canUndo {
                item.title = "Undo \(undoManager.undoActionName)"
            } else {
                item.title = "Undo"
            }
            return undoManager.canUndo

        case #selector(redo(_:)):
            if undoManager.canRedo {
                item.title = "Redo \(undoManager.redoActionName)"
            } else {
                item.title = "Redo"
            }
            return undoManager.canRedo

        case #selector(jumpToLatestUnread(_:)):
            return NotificationStore.shared.latestUnread() != nil

        case #selector(toggleSessionSidebar(_:)):
            return true

        case #selector(BaseTerminalController.togglePaneOverview(_:)):
            return true

        case #selector(markAllRead(_:)):
            return NotificationStore.shared.totalUnreadCount() > 0

        case #selector(BaseTerminalController.jumpToNextAttention(_:)),
             #selector(BaseTerminalController.jumpToPreviousAttention(_:)):
            return AttentionManager.shared.hasAnyUnseenAttention()

        case #selector(BaseTerminalController.goBackToPreviousPane(_:)):
            return AttentionManager.shared.canGoBack

        case #selector(BaseTerminalController.toggleAttentionMute(_:)):
            let focused = (NSApp.keyWindow?.windowController as? BaseTerminalController)?.focusedSurface
            guard let surface = focused else { return false }
            item.title = surface.isAttentionMuted ? "Unmute Attention" : "Mute Attention"
            item.state = surface.isAttentionMuted ? .on : .off
            return true

        case #selector(nextWorkspace(_:)),
             #selector(previousWorkspace(_:)):
            return WorkspaceStore.shared.workspaces.count > 1

        case #selector(newWorkspace(_:)):
            return true

        default:
            return true
        }
    }
}
