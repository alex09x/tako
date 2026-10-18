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

extension Tako.TabStatusLayer {
    /// One ripple of a flowing live ring for each new count of output
    /// bursts. A ring that was hidden or paused when it changed does not
    /// catch up: the next burst ripples it.
    func rippleIfPulsed(_ pulses: Int, state: Tako.SurfaceState, reduceMotion: Bool, paused: Bool) {
        defer { lastPulses = pulses }
        guard pulses != lastPulses, state == .live(flowing: true), !reduceMotion, !paused,
              let ripple = ringContainer.sublayers?.first(where: { $0.name == "liveRipple" }) else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0; scale.toValue = LiveRingStyle.rippleScale
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = LiveRingStyle.rippleOpacity; fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]; group.duration = LiveRingStyle.rippleDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ripple.add(group, forKey: "liveRipple")
    }
}
