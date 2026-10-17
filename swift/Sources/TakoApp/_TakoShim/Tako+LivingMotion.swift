/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// How long a surface keeps moving once it enters a state (Spec 1b §7): the
/// spinner, the comet and the waiting halo for as long as the state lasts,
/// the done pop and glint and the failed shake once, idle and offline never.
/// A surface that does not move needs no animation frames, so a quiet
/// sidebar costs nothing between changes.
enum LivingMotion {
    /// Seconds the state moves after it is entered: nil while it lasts.
    static func duration(of state: Tako.SurfaceState) -> TimeInterval? {
        switch state {
        case .working, .progress, .waiting: return nil
        case .done: return 1.0      // glint 0.96 s, pop 0.704 s
        case .failed: return 0.5    // shake 0.448 s
        case .idle, .offline: return 0
        }
    }

    static func isMoving(_ state: Tako.SurfaceState, elapsed: TimeInterval, reduceMotion: Bool) -> Bool {
        guard !reduceMotion else { return false }
        guard let duration = duration(of: state) else { return true }
        return elapsed < duration
    }

    /// Seconds until a state that moves once comes to rest, or nil when it
    /// moves on or is already still.
    static func remaining(_ state: Tako.SurfaceState, elapsed: TimeInterval, reduceMotion: Bool) -> TimeInterval? {
        guard !reduceMotion, let duration = duration(of: state), elapsed < duration else { return nil }
        return duration - elapsed
    }
}
