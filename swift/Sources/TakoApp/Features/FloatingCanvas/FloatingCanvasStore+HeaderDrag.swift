/*
 * tako — Grid drag intent stays separate from persistent free-window mode
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

extension FloatingCanvasStore {
    struct HeaderDragSession: Equatable {
        let surfaceId: UUID
        let wasTiled: Bool
        let preferredRect: CGRect
    }

    func beginHeaderDrag(for surfaceId: UUID) {
        guard headerDragSession?.surfaceId != surfaceId,
              let pane = state(for: surfaceId), pane.mode != .minimized else { return }
        headerDragSession = HeaderDragSession(surfaceId: surfaceId,
            wasTiled: isTiled(surfaceId), preferredRect: pane.rect)
        if dropTarget != nil { dropTarget = nil }
    }

    func canDockHeaderDrag(_ surfaceId: UUID) -> Bool {
        guard let session = headerDragSession, session.surfaceId == surfaceId,
              session.wasTiled, let pane = state(for: surfaceId), pane.mode != .minimized else { return false }
        return true
    }

    /// Even a proposed edge/peer target cannot enable docking for a free window.
    func updateHeaderDropTarget(_ proposed: CanvasDropTarget?, for surfaceId: UUID) {
        let next = canDockHeaderDrag(surfaceId) ? proposed : nil
        if dropTarget != next { dropTarget = next }
    }

    func finishHeaderDrag(for surfaceId: UUID, docked: Bool) {
        if let session = headerDragSession, session.surfaceId == surfaceId, session.wasTiled {
            if docked {
                if let idx = panes.firstIndex(where: { $0.surfaceId == surfaceId }),
                   panes[idx].rect != session.preferredRect {
                    panes[idx].rect = session.preferredRect
                }
            } else if tiledIds.contains(surfaceId) {
                tiledIds.remove(surfaceId)
            }
        }
        cancelHeaderDrag(for: surfaceId)
    }

    func cancelHeaderDrag(for surfaceId: UUID? = nil) {
        guard surfaceId == nil || headerDragSession?.surfaceId == surfaceId else { return }
        if headerDragSession != nil { headerDragSession = nil }
        if dropTarget != nil { dropTarget = nil }
    }
}
