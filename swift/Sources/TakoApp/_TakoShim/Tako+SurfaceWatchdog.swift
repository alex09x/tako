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
import Foundation

extension Tako.SurfaceView {
        /// Applies one batch's `WatchdogAction`. Main thread only: the timer
        /// and `syncOutputTimeoutItem` both live there.
        func applyWatchdogAction(_ action: Tako.MetalTerminalHost.WatchdogAction) {
            switch action {
            case .arm:
                armSyncOutputWatchdog()
            case .leaveArmed:
                break
            case .disarm:
                syncOutputTimeoutItem?.cancel()
                syncOutputTimeoutItem = nil
            }
        }

        /// Arms the one-shot watchdog. If the frame is still open when it
        /// fires, repaint from the mid-frame state rather than leave the
        /// display frozen for the rest of the frame.
        func armSyncOutputWatchdog() {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.syncOutputTimeoutItem = nil
                guard Tako.MetalTerminalHost.watchdogShouldForceRender(
                    isSynchronizedOutputActive: self.core.isSynchronizedOutputActive()
                ) else { return }
                // Mark every row dirty: the renderer replans only damaged rows,
                // so without this the forced frame paints the stale GPU cache.
                self.core.markAllDamaged()
                self.syncOverride = true
                self.needsDisplay = true
                TakoLog.render.debug("syncOutput watchdog: forced render")
            }
            syncOutputTimeoutItem = item
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Tako.MetalTerminalHost.syncOutputTimeout,
                execute: item
            )
        }

        /// Thread-safe, one-outstanding redraw request shared by the parser
        /// queue and cursor/UI paths. A PTY burst can therefore parse several
        /// batches before AppKit takes the Rust mutex for `renderFrame`.
        func requestPtyRedraw() {
            let shouldSchedule = ptyRedrawLock.withLock {
                guard !ptyRedrawScheduled else { return false }
                ptyRedrawScheduled = true
                return true
            }
            if !shouldSchedule {
                TakoLog.render.debug("requestPtyRedraw: coalesced (already scheduled)")
                return
            }
            TakoLog.render.debug("requestPtyRedraw: scheduled")

            DispatchQueue.main.asyncAfter(
                deadline: .now() + Tako.MetalTerminalHost.ptyRedrawCoalescingInterval
            ) { [weak self] in
                guard let self else { return }
                self.ptyRedrawLock.withLock {
                    self.ptyRedrawScheduled = false
                }
                TakoLog.render.debug("requestPtyRedraw: timer fired → scheduleRedraw")
                self.scheduleRedraw()
            }
        }

        /// The inherited title, mirrored so Combine subscribers can follow it.
        ///
        /// `title` itself lives on the surface and is a plain stored property
}
