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
import TakoCoreUI

extension Tako.SurfaceView {
    func didGainSurfaceFocus(flushTitle: Bool) {
        if flushTitle { publishCurrentTitle() }
        let isSeen = window?.isKeyWindow == true
        if let controller = window?.windowController as? TerminalController {
            // Outside the key window the tab's focus moves only logically:
            // assigning it outright would read the pane before the gate below.
            if isSeen { controller.focusedSurface = self } else { controller.setFocusedSurfaceUnseen(self) }
        }
        BroadcastInputStore.shared.setLeader(paneId: id)
        if isSecureInput { SecureInput.shared.setScoped(self, isSecure: true, focused: true) }
        // Seen only in the key window. A restored tab's pane takes its focus
        // back as its canvas lays out -- behind the selected tab, or in a
        // workspace not shown -- and nobody saw it; when its window becomes
        // key, `focusDidChange(true)` acknowledges it then.
        if isSeen { acknowledgeSeen() }
        reflowToCurrentBounds(forcePtyResize: true)
    }

    /// The user looked at this pane: what waited for them is read.
    func acknowledgeSeen() {
        crab.focused()
        withdrawAllProgramStatusNotifications()
        NotificationStore.shared.markRead(surfaceId: self.id)
    }

    func didLoseSurfaceFocus() {
        if isSecureInput { SecureInput.shared.setScoped(self, isSecure: true, focused: false) }
        crab.unfocused()
    }

    func interceptSurfaceKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53 && mods.isEmpty {
            if OverlayStore.shared.overlay(for: id) != nil {
                OverlayStore.shared.closeOverlay(paneId: id)
                return true
            }
            if DiffReviewStore.shared.session(for: id) != nil {
                DiffReviewStore.shared.closeReview(paneId: id)
                return true
            }
        }
        if Tako.InterruptKeystroke.isInterrupt(keyCode: event.keyCode,
                                               character: event.charactersIgnoringModifiers,
                                               modifiers: event.modifierFlags) {
            withdrawAllProgramStatusNotifications()
            notifyProgramStatusInterrupted()
            crab.userInterrupted()
        }
        return false
    }
}
