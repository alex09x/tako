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
import QuartzCore

/// A classic tab's crab: a `CrabLayer` over the strip, in the tab's crab
/// slot, showing the state of the tab's panes. Core Animation moves it, so
/// the strip draws nothing while it scurries.
extension Tako.TabBarView {
    func updateCrabLayer(for tab: Tab, rect: CGRect, unread: Bool) {
        if !wantsLayer {
            wantsLayer = true
            layer?.masksToBounds = false
        }
        let key = ObjectIdentifier(tab.window)
        let crab: Tako.CrabLayer
        if let existing = crabLayers[key] {
            crab = existing
        } else {
            crab = Tako.CrabLayer()
            crabLayers[key] = crab
        }
        if crab.superlayer == nil { layer?.addSublayer(crab) }
        let motion = LivingAnimationState.shared
        crab.apply(state: aggregateCrab(for: tab.window)?.state ?? .idle, in: rect, unread: unread,
                   reduceMotion: motion.reduceMotion, paused: motion.isTimelinePaused,
                   scale: window?.backingScaleFactor ?? 2)
        crab.setPose(tilt: liftTilt(for: tab), about: CGPoint(x: tab.frame.midX, y: tab.frame.midY))
        // A layer is not clipped to the strip as the drawing is: a crab
        // scrolled out of it, or of a tab still growing in, is not shown.
        crab.setShown(tab.showsContent && stripRect.contains(rect))
    }

    func syncCrabLayers(visibleTabIds: Set<ObjectIdentifier>) {
        for (id, crab) in crabLayers where !visibleTabIds.contains(id) {
            crab.removeFromSuperlayer()
            crabLayers.removeValue(forKey: id)
        }
    }
}
