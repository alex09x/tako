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

extension Tako.SurfaceView {
    func didGainSurfaceFocus(flushTitle: Bool) {
        if flushTitle { publishCurrentTitle() }
        (window?.windowController as? TerminalController)?.focusedSurface = self
        BroadcastInputStore.shared.setLeader(paneId: id)
        if isSecureInput { SecureInput.shared.setScoped(self, isSecure: true, focused: true) }
        crab.focused()
        NotificationStore.shared.markRead(surfaceId: self.id)
        reflowToCurrentBounds(forcePtyResize: true)
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
            notifyProgramStatusInterrupted()
            crab.userInterrupted()
        }
        return false
    }
}
