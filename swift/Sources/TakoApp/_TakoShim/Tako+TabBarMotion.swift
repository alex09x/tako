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

/// What on the tab strip moves frame by frame, drawn as the pills are rather
/// than layered: a failed pill shakes whole -- background, title and ring,
/// as a sidebar row does -- and the workspace chip grows or shrinks with its
/// attention badge over a moment, the pills sliding along, instead of every
/// pill jumping by the badge's width. While either runs the strip redraws
/// every frame the display shows; then it stops.
extension Tako.TabBarView {
    static let chipSlideDuration: CFTimeInterval = 0.15
    static let shakeDuration: CFTimeInterval = 0.448

    /// The chip's width as drawn: `target`, reached over a moment when it changes.
    func displayedChipWidth(target: CGFloat, now: CFTimeInterval = CACurrentMediaTime()) -> CGFloat {
        defer { chipWidthTarget = target }
        if let last = chipWidthTarget, last != target {
            if LivingAnimationState.shared.reduceMotion {
                chipSlide = nil
            } else {
                let from = chipSlide.map { Self.slid($0, at: now) } ?? last
                chipSlide = (from, target, now)
                runMotion()
            }
        }
        guard let slide = chipSlide else { return target }
        guard now - slide.start < Self.chipSlideDuration else { chipSlide = nil; return target }
        return Self.slid(slide, at: now)
    }

    static func slid(_ slide: (from: CGFloat, to: CGFloat, start: CFTimeInterval), at now: CFTimeInterval) -> CGFloat {
        let k = CSSTiming.easeOut(min(1, max(0, (now - slide.start) / chipSlideDuration)))
        return slide.from + (slide.to - slide.from) * CGFloat(k)
    }

    /// How far a pill sits off its place: the failed shake, timed from the
    /// moment it turned failed from another state.
    func shakeOffset(for key: ObjectIdentifier, state: Tako.SurfaceState, previous: Tako.SurfaceState?,
                     now: CFTimeInterval = CACurrentMediaTime()) -> CGFloat {
        guard state == .failed else { failedSince[key] = nil; return 0 }
        if let previous, previous != .failed, !LivingAnimationState.shared.reduceMotion {
            failedSince[key] = now
            runMotion()
        }
        guard let since = failedSince[key] else { return 0 }
        guard now - since < Self.shakeDuration else { failedSince[key] = nil; return 0 }
        return LivingAnimationState.failedShakeOffset(elapsed: now - since)
    }

    /// Redraw every frame while something above moves.
    func runMotion() {
        guard motionLink == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(motionFrame(_:)))
        link.add(to: .main, forMode: .common)
        motionLink = link
    }

    @objc func motionFrame(_ link: CADisplayLink) {
        guard chipSlide != nil || !failedSince.isEmpty else {
            link.invalidate()
            motionLink = nil
            return
        }
        needsDisplay = true
    }
}
