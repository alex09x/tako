/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import SwiftUI

/// The moment one moving part of a sidebar row is drawn at -- its ring, its
/// comet or breathing border, its waiting glow, its done glint -- and how far
/// into its state that is. Only these parts take animation frames; the row
/// around them is drawn once per change. A clock around the whole row redid
/// its text, layout and every overlay each frame: one working row kept the
/// main thread busy, and a few working tabs stalled every row for 75-140 ms.
struct SidebarRowClock<Content: View>: View {
    /// A snapshot's moment: drawn there, no frames.
    let fixed: Date?
    let key: String
    let state: Tako.SurfaceState
    let moving: Bool
    let paused: Bool
    @ViewBuilder let content: (Date, TimeInterval) -> Content

    var body: some View {
        if let fixed {
            content(fixed, LivingAnimationState.shared.elapsedInState(for: key, state: state, now: fixed))
        } else {
            TimelineView(.animation(minimumInterval: LivingMotion.minimumFrameInterval(for: state), paused: paused || !moving)) { context in
                // A paused timeline keeps the date of its last frame, which
                // can fall inside a glint or a shake: a part at rest is drawn
                // at the time it is now, past its motion.
                let now = LivingAnimationState.shared.effectiveDate(moving ? context.date : Date())
                content(now, LivingAnimationState.shared.elapsedInState(for: key, state: state, now: now))
            }
        }
    }
}
