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

    func makeStrokeCircle(_ rect: CGRect, inset: CGFloat, color: CGColor, width: CGFloat, dash: [NSNumber]? = nil) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.contentsScale = 2.0; l.frame = rect; l.path = CGPath(ellipseIn: rect.insetBy(dx: inset, dy: inset), transform: nil)
        l.fillColor = nil; l.strokeColor = color; l.lineWidth = width; l.lineDashPattern = dash
        return l
    }

    func makeSpinAnimation(duration: CFTimeInterval) -> CABasicAnimation {
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0.0; spin.toValue = -Double.pi * 2.0; spin.duration = duration
        spin.repeatCount = .infinity; spin.timingFunction = CAMediaTimingFunction(name: .linear)
        spin.isRemovedOnCompletion = false
        return spin
    }

    func rebuildRing(for state: Tako.SurfaceState, reduceMotion: Bool, triggerOneShot: Bool, palette: Tako.TabStatusPalette) {
        ringContainer.sublayers?.forEach { $0.removeFromSuperlayer() }
        ringContainer.removeAllAnimations()
        let rBounds = CGRect(x: 0, y: 0, width: 14, height: 14)

        switch state {
        case .idle:
            ringContainer.addSublayer(makeStrokeCircle(rBounds, inset: 0.75, color: palette.idleRingColor, width: 1.5))

        case .working:
            ringContainer.addSublayer(makeStrokeCircle(rBounds, inset: 1.25, color: palette.working.copy(alpha: 0.16) ?? palette.working, width: 2.5))
            let conic = CAGradientLayer()
            conic.name = "workingSpin"; conic.type = .conic; conic.frame = rBounds
            conic.startPoint = CGPoint(x: 0.5, y: 0.5); conic.endPoint = CGPoint(x: 0.5, y: 1.0)
            conic.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, palette.working, palette.working.copy(alpha: 0) ?? palette.working]
            conic.locations = [0, 0.222, 0.223, 1.0]
            conic.mask = makeStrokeCircle(rBounds, inset: 1.25, color: NSColor.black.cgColor, width: 2.5)
            ringContainer.addSublayer(conic)
            if !reduceMotion { conic.add(makeSpinAnimation(duration: 0.9), forKey: "spin") }

        case .progress(let p):
            ringContainer.addSublayer(makeStrokeCircle(rBounds, inset: 1.25, color: T.progressTrack.cgColor, width: 2.5))
            // `.r-prog`: conic-gradient(Rust 0%, Ember p%) -- the arc
            // shades from Rust at the top to Ember where it stops.
            let shade = CAGradientLayer()
            shade.name = "progressArc"; shade.type = .conic; shade.frame = rBounds
            shade.startPoint = CGPoint(x: 0.5, y: 0.5); shade.endPoint = CGPoint(x: 0.5, y: 1.0)
            let arc = CAShapeLayer()
            arc.frame = rBounds
            let arcPath = CGMutablePath()
            arcPath.addArc(center: CGPoint(x: 7, y: 7), radius: 5.75, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 2, clockwise: true)
            arc.path = arcPath; arc.fillColor = nil; arc.strokeColor = NSColor.black.cgColor
            arc.lineWidth = 2.5; arc.lineCap = .butt
            shade.mask = arc
            ringContainer.addSublayer(shade)
            setProgressArc(shade, to: CGFloat(min(1.0, max(0.0, p))), palette: palette)

        case .waiting:
            if !reduceMotion {
                let halo = makeStrokeCircle(rBounds, inset: 1.0, color: palette.waiting, width: 2.0)
                halo.name = "waitingHalo"; ringContainer.addSublayer(halo)
                let scaleAnim = CABasicAnimation(keyPath: "transform.scale"); scaleAnim.fromValue = 1.0; scaleAnim.toValue = 2.1
                let opAnim = CABasicAnimation(keyPath: "opacity"); opAnim.fromValue = 0.75; opAnim.toValue = 0.0
                let group = CAAnimationGroup()
                group.animations = [scaleAnim, opAnim]; group.duration = 1.6; group.repeatCount = .infinity
                group.timingFunction = CAMediaTimingFunction(name: .easeOut); group.isRemovedOnCompletion = false
                halo.add(group, forKey: "halo")
            }
            ringContainer.addSublayer(makeStrokeCircle(rBounds, inset: 1.0, color: palette.waiting, width: 2.0))
            let dot = CAShapeLayer()
            dot.name = "waitingDot"; dot.frame = rBounds
            dot.path = CGPath(ellipseIn: CGRect(x: 5, y: 5, width: 4, height: 4), transform: nil)
            dot.fillColor = palette.waiting
            ringContainer.addSublayer(dot)
            if !reduceMotion {
                let blink = CABasicAnimation(keyPath: "opacity")
                blink.fromValue = 1.0; blink.toValue = 0.25; blink.duration = 0.8
                blink.autoreverses = true; blink.repeatCount = .infinity
                blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); blink.isRemovedOnCompletion = false
                dot.add(blink, forKey: "blink")
            }

        case .done:
            let disc = CAShapeLayer()
            disc.frame = rBounds; disc.path = CGPath(ellipseIn: rBounds, transform: nil); disc.fillColor = palette.done
            ringContainer.addSublayer(disc)
            let check = CAShapeLayer(); check.frame = rBounds
            let checkPath = CGMutablePath()
            checkPath.move(to: CGPoint(x: 4.0, y: 14.0 - 7.2))
            checkPath.addLine(to: CGPoint(x: 6.1, y: 14.0 - 9.3))
            checkPath.addLine(to: CGPoint(x: 10.0, y: 14.0 - 5.0))
            check.path = checkPath; check.fillColor = nil; check.strokeColor = T.ink.cgColor
            check.lineWidth = 1.75; check.lineCap = .round; check.lineJoin = .round
            ringContainer.addSublayer(check)
            if triggerOneShot && !reduceMotion {
                let b = CAMediaTimingFunction(controlPoints: 0.3, 1.6, 0.5, 1.0)
                let pop = CAKeyframeAnimation(keyPath: "transform.scale")
                pop.values = [1.0, 0.55, 1.25, 1.0]
                pop.keyTimes = [0.0, NSNumber(value: 192.0 / 704.0), NSNumber(value: 448.0 / 704.0), 1.0]
                pop.timingFunctions = [b, b, b]; pop.duration = 0.704
                ringContainer.add(pop, forKey: "donePop")
            }

        case .failed:
            let disc = CAShapeLayer()
            disc.frame = rBounds; disc.path = CGPath(ellipseIn: rBounds, transform: nil); disc.fillColor = palette.error
            ringContainer.addSublayer(disc)
            let bang = CAShapeLayer(); bang.frame = rBounds
            let bangPath = CGMutablePath()
            bangPath.addRoundedRect(in: CGRect(x: 6, y: 14.0 - 8.0, width: 2, height: 5), cornerWidth: 1, cornerHeight: 1)
            bangPath.addRoundedRect(in: CGRect(x: 6, y: 14.0 - 11.5, width: 2, height: 2), cornerWidth: 1, cornerHeight: 1)
            bang.path = bangPath; bang.fillColor = T.ink.cgColor
            ringContainer.addSublayer(bang)

        case .offline:
            ringContainer.addSublayer(makeStrokeCircle(rBounds, inset: 0.75, color: T.faint.cgColor, width: 1.5, dash: [2, 2]))

        case .live(let flowing):
            let ripple = makeStrokeCircle(rBounds, inset: 0.75, color: palette.waiting, width: 1.5)
            ripple.name = "liveRipple"; ripple.opacity = 0
            ringContainer.addSublayer(ripple)
            let alpha = flowing ? 1 : CGFloat(LiveRingStyle.quietOpacity)
            ringContainer.addSublayer(makeStrokeCircle(rBounds, inset: 0.75, color: palette.working.copy(alpha: alpha) ?? palette.working, width: 1.5))
        }
        ringContainer.sublayers?.forEach { $0.contentsScale = 2.0 }
    }
}
