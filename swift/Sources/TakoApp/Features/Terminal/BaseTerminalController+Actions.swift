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

extension BaseTerminalController {
    // MARK: First Responder

    // `Tako.App.requestClose(surface:)` was an unimplemented stub -- Cmd+W
    // silently did nothing. `closeSurface` is the same method the working
    // AppleScript `close` command uses.
    @IBAction func close(_ sender: Any) {
        guard let surface = focusedSurface else { return }
        closeSurface(surface, withConfirmation: surface.needsConfirmClose)
    }

    @IBAction func closeWindow(_ sender: Any) {
        guard let window = window else { return }
        window.performClose(sender)
    }

    @IBAction func changeTabTitle(_ sender: Any) {
        if let targetWindow = window {
            let inlineHostWindow =
                targetWindow.tabbedWindows?
                    .first(where: { $0.tabBarView != nil }) as? TerminalWindow
                ?? (targetWindow as? TerminalWindow)

            if let inlineHostWindow, inlineHostWindow.beginInlineTabTitleEdit(for: targetWindow) {
                return
            }
        }

        promptTabTitle()
    }

    // `Tako.App.split(surface:direction:)` was an unimplemented stub --
    // routing through it here silently did nothing, which is why Cmd+D and
    // the View > Split menu items never worked. `newSplit(at:direction:)`
    // below is the same call AppleScript's working `split` command uses.
    @IBAction func splitRight(_ sender: Any) {
        guard let surface = focusedSurface else { return }
        newSplit(at: surface, direction: .right)
    }

    @IBAction func splitLeft(_ sender: Any) {
        guard let surface = focusedSurface else { return }
        newSplit(at: surface, direction: .left)
    }

    @IBAction func splitDown(_ sender: Any) {
        guard let surface = focusedSurface else { return }
        newSplit(at: surface, direction: .down)
    }

    @IBAction func splitUp(_ sender: Any) {
        guard let surface = focusedSurface else { return }
        newSplit(at: surface, direction: .up)
    }

    // `Tako.App.splitToggleZoom(surface:)` was an unimplemented stub.
    // `didToggleSplitZoom` is the real notification `takoDidToggleSplitZoom`
    // above already listens for and implements correctly.
    @IBAction func splitZoom(_ sender: Any) {
        guard let surface = focusedSurface else { return }
        NotificationCenter.default.post(name: Tako.Notification.didToggleSplitZoom, object: surface)
    }

    @IBAction func splitMoveFocusPrevious(_ sender: Any) {
        splitMoveFocus(direction: .previous)
    }

    @IBAction func splitMoveFocusNext(_ sender: Any) {
        splitMoveFocus(direction: .next)
    }

    @IBAction func splitMoveFocusAbove(_ sender: Any) {
        splitMoveFocus(direction: .up)
    }

    @IBAction func splitMoveFocusBelow(_ sender: Any) {
        splitMoveFocus(direction: .down)
    }

    @IBAction func splitMoveFocusLeft(_ sender: Any) {
        splitMoveFocus(direction: .left)
    }

    @IBAction func splitMoveFocusRight(_ sender: Any) {
        splitMoveFocus(direction: .right)
    }

    // `Tako.App.splitEqualize/splitResize/splitMoveFocus(surface:...)`
    // were unimplemented stubs. The notifications below are the real ones
    // `takoDidEqualizeSplits`/`takoDidResizeSplit`/`takoDidFocusSplit`
    // above already listen for and implement correctly.
    @IBAction func equalizeSplits(_ sender: Any) {
        guard let surface = focusedSurface else { return }
        NotificationCenter.default.post(name: Tako.Notification.didEqualizeSplits, object: surface)
    }

    private func resizeSplit(direction: Tako.SplitResizeDirection, amount: UInt16 = 10) {
        guard let surface = focusedSurface else { return }
        NotificationCenter.default.post(
            name: Tako.Notification.didResizeSplit,
            object: surface,
            userInfo: [
                Tako.Notification.ResizeSplitDirectionKey: direction,
                Tako.Notification.ResizeSplitAmountKey: amount,
            ])
    }

    @IBAction func moveSplitDividerUp(_ sender: Any) { resizeSplit(direction: .up) }
    @IBAction func moveSplitDividerDown(_ sender: Any) { resizeSplit(direction: .down) }
    @IBAction func moveSplitDividerLeft(_ sender: Any) { resizeSplit(direction: .left) }
    @IBAction func moveSplitDividerRight(_ sender: Any) { resizeSplit(direction: .right) }

    private func splitMoveFocus(direction: Tako.SplitFocusDirection) {
        guard let surface = focusedSurface else { return }
        NotificationCenter.default.post(
            name: Tako.Notification.takoFocusSplit,
            object: surface,
            userInfo: [Tako.Notification.SplitDirectionKey: direction])
    }

    @IBAction func increaseFontSize(_ sender: Any) {
        guard let surface = focusedSurface else { return }
        tako.changeFontSize(surface: surface, .increase(1))
    }

    @IBAction func decreaseFontSize(_ sender: Any) {
        guard let surface = focusedSurface else { return }
        tako.changeFontSize(surface: surface, .decrease(1))
    }

    @IBAction func resetFontSize(_ sender: Any) {
        guard let surface = focusedSurface else { return }
        tako.changeFontSize(surface: surface, .reset)
    }

    /// There is no terminal inspector in this port. The menu item is
    /// disabled (see `validateMenuItem`), so this is never reached from it.
    @IBAction func toggleTerminalInspector(_ sender: Any?) {
        NSSound.beep()
    }

    @IBAction func toggleFindAll(_ sender: Any?) {
        findAllIsShowing.toggle()
        if findAllIsShowing {
            // The panel's field takes the keys; see toggleCommandPalette.
            _ = focusedSurface?.resignFirstResponder()
        }
    }

    @IBAction func toggleNotificationCenter(_ sender: Any?) {
        notificationCenterIsShowing.toggle()
        if notificationCenterIsShowing {
            _ = focusedSurface?.resignFirstResponder()
        }
    }

    @IBAction func jumpToLatestUnread(_ sender: Any?) {
        guard let latest = NotificationStore.shared.latestUnread() else {
            NSSound.beep()
            return
        }
        notificationCenterIsShowing = false
        if let target = Self.surface(withID: latest.surfaceId) {
            NotificationCenter.default.post(name: Tako.Notification.takoPresentTerminal, object: target)
            NotificationStore.shared.markRead(surfaceId: latest.surfaceId)
        } else {
            NotificationStore.shared.markNotificationRead(id: latest.id)
        }
    }

    @IBAction func markFocusedPaneRead(_ sender: Any?) {
        guard let focused = focusedSurface else { return }
        NotificationStore.shared.markRead(surfaceId: focused.id)
    }

    @IBAction func markAllRead(_ sender: Any?) {
        NotificationStore.shared.markAllRead()
    }

    @IBAction func toggleSessionSidebar(_ sender: Any?) {
        sessionSidebarIsShowing.toggle()
    }

    @IBAction func togglePaneOverview(_ sender: Any?) {
        paneOverviewIsShowing.toggle()
        if paneOverviewIsShowing {
            _ = focusedSurface?.resignFirstResponder()
        }
    }

    // MARK: - Attention Navigation (B7)

    @IBAction func jumpToNextAttention(_ sender: Any?) {
        guard let target = AttentionManager.shared.nextAttentionSurface(from: focusedSurface) else {
            NSSound.beep()
            return
        }
        if let focused = focusedSurface {
            AttentionManager.shared.recordJump(from: focused.id)
        }
        NotificationCenter.default.post(name: Tako.Notification.takoPresentTerminal, object: target)
        AttentionManager.shared.markSeen(surfaceId: target.id)
        NotificationStore.shared.markRead(surfaceId: target.id)
    }

    @IBAction func jumpToPreviousAttention(_ sender: Any?) {
        guard let target = AttentionManager.shared.previousAttentionSurface(from: focusedSurface) else {
            NSSound.beep()
            return
        }
        if let focused = focusedSurface {
            AttentionManager.shared.recordJump(from: focused.id)
        }
        NotificationCenter.default.post(name: Tako.Notification.takoPresentTerminal, object: target)
        AttentionManager.shared.markSeen(surfaceId: target.id)
        NotificationStore.shared.markRead(surfaceId: target.id)
    }

    @IBAction func goBackToPreviousPane(_ sender: Any?) {
        guard let target = AttentionManager.shared.resolveGoBackTarget(currentSurfaceId: focusedSurface?.id) else {
            NSSound.beep()
            return
        }
        NotificationCenter.default.post(name: Tako.Notification.takoPresentTerminal, object: target)
    }

    @IBAction func toggleAttentionMute(_ sender: Any?) {
        guard let surface = focusedSurface else { return }
        surface.toggleAttentionMute()
    }

    private static func surface(withID id: UUID) -> Tako.SurfaceView? {
        for controller in TerminalController.all {
            if let surface = controller.surfaceTree.first(where: { $0.id == id }) {
                return surface
            }
        }
        return nil
    }

    @IBAction func toggleCommandPalette(_ sender: Any?) {
        commandPaletteIsShowing.toggle()
        if commandPaletteIsShowing {
            // Fix the incorrect focus when toggling from InlineTitleEditor
            // When toggling the command palette from the inline title editor,
            // the first responder state of the surface is changed quickly from true to false.

            // `makeFirstResponder:` is called by the title editor when finishing,
            // but it happens **after** the command palette is shown,
            // so the `focused` is set to `true` while the command palette is shown.
            // (Could be an AppKit issue as well, since the resign is not called after but the command palette is receiving `keyDown`).

            // Since `performKeyEquivalent(with:)` is called on all of the subviews
            // until one of the return `true` so the paste action is consumed by the surface
            // instead of the first responder (command palette).
            _ = focusedSurface?.resignFirstResponder()
        }
    }

    @IBAction func find(_ sender: Any) {
        focusedSurface?.find(sender)
    }

    @IBAction func selectionForFind(_ sender: Any) {
        focusedSurface?.selectionForFind(sender)
    }

    @IBAction func scrollToSelection(_ sender: Any) {
        focusedSurface?.scrollToSelection(sender)
    }

    @IBAction func findNext(_ sender: Any) {
        focusedSurface?.findNext(sender)
    }

    @IBAction func findPrevious(_ sender: Any) {
        focusedSurface?.findPrevious(sender)
    }

    @IBAction func findHide(_ sender: Any) {
        focusedSurface?.findHide(sender)
    }

    @IBAction func jumpToPreviousPrompt(_ sender: Any?) {
        focusedSurface?.jumpToPreviousPrompt(sender)
    }

    @IBAction func jumpToNextPrompt(_ sender: Any?) {
        focusedSurface?.jumpToNextPrompt(sender)
    }

    @IBAction func selectCommandOutput(_ sender: Any?) {
        focusedSurface?.selectCommandOutput(sender)
    }

    @objc func resetTerminal(_ sender: Any) {
        guard let surface = focusedSurface else { return }
        tako.resetTerminal(surface: surface)
    }

}
