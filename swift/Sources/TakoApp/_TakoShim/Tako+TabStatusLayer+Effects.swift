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
    private typealias T = Tako.LivingTokens

    func rebuildSurfaceEffects(for state: Tako.SurfaceState, size: CGSize, reduceMotion: Bool, triggerOneShot: Bool, palette: Tako.TabStatusPalette) {
        guard drawsSurface else {
            for l: CALayer in [cometContainer, breatheGlowContainer, breatheLayer, failedLineLayer, offlineBorderLayer, progressLineLayer] {
                l.isHidden = true
            }
            flashLayer.opacity = 0
            return
        }
        let comet: Bool = {
            if case .progress = state { return geometry.cometForProgress }
            return state == .working
        }()
        cometContainer.isHidden = !comet; cometGradient.removeAllAnimations()
        if palette.hasCustomColors {
            let stillBorderColors = Array(repeating: (palette.working.copy(alpha: 0.8) ?? palette.working), count: 5)
            let cometColors = [NSColor.clear.cgColor, palette.waiting, palette.rust, NSColor.clear.cgColor, NSColor.clear.cgColor]
            cometGradient.colors = reduceMotion ? stillBorderColors : cometColors
        } else {
            cometGradient.colors = reduceMotion ? Self.stillBorderColors : Self.cometColors
        }
        if comet && !reduceMotion { cometGradient.add(makeSpinAnimation(duration: 2.2), forKey: "cometSpin") }
        breatheGlowContainer.isHidden = (state != .waiting); breatheGlowLayer.removeAllAnimations()
        breatheLayer.isHidden = (state != .waiting); breatheLayer.removeAllAnimations()
        failedLineLayer.isHidden = (state != .failed)
        failedLineLayer.fillColor = palette.error
        offlineBorderLayer.isHidden = (state != .offline)

        if case .progress(let p) = state {
            progressLineLayer.isHidden = false
            progressLineLayer.colors = palette.hasCustomColors ? [palette.rust, palette.working] : [T.rust.cgColor, T.ember.cgColor]
            updateProgressValue(p, in: size, palette: palette)
        } else {
            progressLineLayer.isHidden = true
        }

        switch state {
        case .waiting:
            let waitingColor = palette.waiting
            let baseStroke = palette.hasCustomColors ? (waitingColor.copy(alpha: 0.65) ?? waitingColor) : T.claw.withAlphaComponent(0.65).cgColor
            breatheLayer.strokeColor = baseStroke
            breatheGlowLayer.shadowColor = palette.hasCustomColors ? waitingColor : T.claw.cgColor
            if reduceMotion {
                breatheLayer.strokeColor = palette.hasCustomColors ? (waitingColor.copy(alpha: 0.90) ?? waitingColor) : T.claw.withAlphaComponent(0.90).cgColor
                breatheGlowLayer.shadowOpacity = 0.20
            } else {
                let eio = CAMediaTimingFunction(name: .easeInEaseOut)
                let strokeAnim = CABasicAnimation(keyPath: "strokeColor")
                if palette.hasCustomColors {
                    strokeAnim.fromValue = waitingColor.copy(alpha: 0.40); strokeAnim.toValue = waitingColor.copy(alpha: 0.95)
                } else {
                    strokeAnim.fromValue = T.claw.withAlphaComponent(0.40).cgColor
                    strokeAnim.toValue = T.claw.withAlphaComponent(0.95).cgColor
                }
                strokeAnim.duration = 0.8; strokeAnim.autoreverses = true; strokeAnim.repeatCount = .infinity
                strokeAnim.timingFunction = eio; strokeAnim.isRemovedOnCompletion = false
                breatheLayer.add(strokeAnim, forKey: "breathe")

                let shadowAnim = CABasicAnimation(keyPath: "shadowOpacity")
                shadowAnim.fromValue = 0.0; shadowAnim.toValue = 0.30
                shadowAnim.duration = 0.8; shadowAnim.autoreverses = true; shadowAnim.repeatCount = .infinity
                shadowAnim.timingFunction = eio; shadowAnim.isRemovedOnCompletion = false
                breatheGlowLayer.add(shadowAnim, forKey: "breatheGlow")
            }
        case .done:
            flashLayer.updateColor(palette.done)
            if triggerOneShot && !reduceMotion && size.width > 0 {
                flashLayer.opacity = 1.0
                // background-position 120% -> -60%, ease-out, over 0.96 s
                let sweep = CABasicAnimation(keyPath: "position.x")
                sweep.fromValue = flashLayer.x(at: 0); sweep.toValue = flashLayer.x(at: 1)
                sweep.duration = 0.96; sweep.timingFunction = CAMediaTimingFunction(controlPoints: 0, 0, 0.58, 1)
                // Then quiet: the model position is the start, where no band shows.
                sweep.fillMode = .forwards
                flashLayer.add(sweep, forKey: "doneFlash")
            }
        case .failed:
            // The shake moves the whole pill, title too: the strip drives
            // it frame by frame (setShake), not this layer alone.
            break
        case .working, .idle, .progress, .offline, .live:
            break
        }
    }

    func updateProgressValue(_ p: Double, in size: CGSize, palette: Tako.TabStatusPalette) {
        let clamped = CGFloat(min(1.0, max(0.0, p)))
        let inset = geometry.progressInset
        // At once, as the arc moves: the line eased a quarter second
        // behind the arc it stands for.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLineLayer.frame = CGRect(x: inset, y: geometry.cometForProgress ? 1 : 0,
                                         width: max(2, (size.width - inset * 2) * clamped), height: 2)
        CATransaction.commit()
        if let shade = ringContainer.sublayers?.first(where: { $0.name == "progressArc" }) as? CAGradientLayer {
            setProgressArc(shade, to: clamped, palette: palette)
        }
    }

    /// The arc to `p` of the turn, Rust at its start and Ember at its end.
    func setProgressArc(_ shade: CAGradientLayer, to p: CGFloat, palette: Tako.TabStatusPalette) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        (shade.mask as? CAShapeLayer)?.strokeEnd = p
        // The conic runs anticlockwise from the top in a layer that is y
        // up; the arc runs clockwise, so it is the conic's last `p`.
        shade.locations = [0, NSNumber(value: Double(1 - max(0.0001, p))), 1]
        if palette.hasCustomColors {
            shade.colors = [palette.working, palette.working, palette.rust]
        } else {
            shade.colors = [T.ember.cgColor, T.ember.cgColor, T.rust.cgColor]
        }
        CATransaction.commit()
    }
}
