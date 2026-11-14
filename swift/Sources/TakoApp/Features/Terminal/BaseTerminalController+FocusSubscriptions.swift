/*
 * tako — What follows the focused pane: read state and the window title
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Cocoa
import Combine

extension BaseTerminalController {
    /// Makes `surface` this tab's focused pane without marking it seen: for
    /// a tab the user is not looking at, such as one a pane just left.
    func setFocusedSurfaceUnseen(_ surface: Tako.SurfaceView?) {
        focusChangeMarksSeen = false
        defer { focusChangeMarksSeen = true }
        focusedSurface = surface
    }

    /// After a focus change: the newly focused pane is seen (unless the
    /// change is only logical), and the window title follows it. Only the
    /// focus paths in BaseTerminalController call this.
    func bindFocusedSurfaceSubscriptions(previous lastFocusedSurface: Tako.SurfaceView?) {
        if let focused = focusedSurface, focusChangeMarksSeen {
            NotificationStore.shared.markRead(surfaceId: focused.id)
            AttentionManager.shared.markSeen(surfaceId: focused.id)
        }
        SessionSidebarStore.shared.objectWillChange.send()
        focusedSurfaceCancellables = []
        if let titleSurface = focusedSurface ?? lastFocusedSurface, surfaceTree.contains(titleSurface) {
            titleSurface.$titleText
                .combineLatest(titleSurface.$bell)
                .map { [weak self] in self?.computeTitle(title: $0, bell: $1) ?? "" }
                .sink { [weak self] in self?.titleDidChange(to: $0) }
                .store(in: &focusedSurfaceCancellables)
        } else {
            titleDidChange(to: "👻")
        }
    }
}
