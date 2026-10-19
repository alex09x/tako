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

/// The Overview's frame rate. One timeline drives every card at 30 frames a
/// second (§7); a card playing a one-off motion -- the done glint and pop,
/// the failed shake -- takes every frame the display shows while it plays,
/// as a pill tab and a sidebar row do, and the modal drops back after.
extension PaneOverviewView {
    /// Seconds until the last one-off motion among `items` comes to rest, or
    /// nil when none plays.
    static func oneOffRemaining(of items: [PaneOverviewItem], reduceMotion: Bool, now: Date = Date()) -> TimeInterval? {
        items.compactMap { item -> TimeInterval? in
            let state = item.surfaceState
            guard LivingMotion.minimumFrameInterval(for: state) == nil else { return nil }
            // The key the card itself times its state with.
            let elapsed = LivingAnimationState.shared.elapsedInState(for: "overview-\(item.id.uuidString)", state: state, now: now)
            return LivingMotion.remaining(state, elapsed: elapsed, reduceMotion: reduceMotion)
        }.max()
    }

    static func minimumFrameInterval(oneOffRemaining: TimeInterval?) -> TimeInterval? {
        oneOffRemaining == nil ? 1.0 / 30.0 : nil
    }
}
