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

extension Tako {
    /// Core Animation layer subtree for a single Pill Tab in `TabBarView` (Spec 1b §2, §3, §4, §7).
    /// Renders the S=14 Status Ring and live surface effects (Comet, Breathe, Done Flash, Failed Line + Shake, Progress Line, Offline Dashed) on the GPU without per-frame `draw(_:)` timers.
    @MainActor
    final class TabStatusLayer: CALayer {
        private typealias T = Tako.LivingTokens

        private(set) var currentState: SurfaceState?
        private var lastSize: CGSize = .zero
        private var lastReduceMotion: Bool = false
        private var isLayerPaused: Bool = false

        private let clippedInnerContainer = CALayer()
        private let failedLineLayer = CALayer()
        private let progressLineLayer = CAGradientLayer()
        private let flashLayer = CAGradientLayer()

        private let cometContainer = CALayer()
        private let cometMask = CAShapeLayer()
        private let cometGradient = CAGradientLayer()

        private let breatheLayer = CAShapeLayer()
        private let offlineBorderLayer = CAShapeLayer()
        private let ringContainer = CALayer()

        override init() {
            super.init()
            setupSublayers()
        }

        override init(layer: Any) { super.init(layer: layer) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        private func setupSublayers() {
            masksToBounds = false
            clippedInnerContainer.cornerRadius = 6
            clippedInnerContainer.masksToBounds = true
            addSublayer(clippedInnerContainer)

            failedLineLayer.backgroundColor = T.error.cgColor
            failedLineLayer.isHidden = true
            clippedInnerContainer.addSublayer(failedLineLayer)

            progressLineLayer.colors = [T.rust.cgColor, T.ember.cgColor]
            progressLineLayer.startPoint = CGPoint(x: 0, y: 0.5); progressLineLayer.endPoint = CGPoint(x: 1, y: 0.5)
            progressLineLayer.cornerRadius = 1; progressLineLayer.isHidden = true
            clippedInnerContainer.addSublayer(progressLineLayer)

            flashLayer.colors = [NSColor.clear.cgColor, T.ok.withAlphaComponent(0.26).cgColor, NSColor.clear.cgColor]
            flashLayer.locations = [0, 0.5, 1.0]
            flashLayer.startPoint = CGPoint(x: 0, y: 0.41); flashLayer.endPoint = CGPoint(x: 1, y: 0.59)
            flashLayer.opacity = 0
            clippedInnerContainer.addSublayer(flashLayer)

            cometMask.fillColor = nil; cometMask.strokeColor = NSColor.black.cgColor; cometMask.lineWidth = 1.0
            cometContainer.mask = cometMask; cometContainer.isHidden = true

            cometGradient.type = .conic
            cometGradient.startPoint = CGPoint(x: 0.5, y: 0.5); cometGradient.endPoint = CGPoint(x: 0.5, y: 1.0)
            cometGradient.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, T.rust.cgColor, T.claw.cgColor, NSColor.clear.cgColor]
            cometGradient.locations = [0.0, 0.62, 0.78, 0.88, 1.0]
            cometContainer.addSublayer(cometGradient)
            addSublayer(cometContainer)

            breatheLayer.fillColor = nil; breatheLayer.lineWidth = 1.0
            breatheLayer.strokeColor = T.claw.withAlphaComponent(0.65).cgColor
            breatheLayer.shadowColor = T.claw.cgColor; breatheLayer.shadowOffset = .zero; breatheLayer.shadowRadius = 8
            breatheLayer.isHidden = true
            addSublayer(breatheLayer)

            offlineBorderLayer.fillColor = nil; offlineBorderLayer.lineWidth = 1.0
            offlineBorderLayer.strokeColor = T.ghostBorder.cgColor; offlineBorderLayer.lineDashPattern = [3, 3]
            offlineBorderLayer.isHidden = true
            addSublayer(offlineBorderLayer)

            ringContainer.masksToBounds = false
            addSublayer(ringContainer)
        }

        func apply(state: SurfaceState, in pillRect: CGRect, hideRing: Bool, reduceMotion: Bool, paused: Bool, allowFrameAnimation: Bool = false) {
            let previousState = currentState
            let didChangeState = (previousState != nil && previousState != state)
            let isFirstApply = (previousState == nil)
            let sizeChanged = (lastSize != pillRect.size) || (lastReduceMotion != reduceMotion)

            CATransaction.begin()
            CATransaction.setDisableActions(!allowFrameAnimation)
            frame = pillRect
            ringContainer.isHidden = hideRing
            if sizeChanged {
                lastSize = pillRect.size; lastReduceMotion = reduceMotion
                layoutGeometries(for: pillRect.size)
            }
            CATransaction.commit()
            setLayerPaused(paused)

            guard isFirstApply || didChangeState || sizeChanged else {
                if case .progress(let p) = state { updateProgressValue(p, in: pillRect.size) }
                return
            }

            currentState = state
            rebuildRing(for: state, reduceMotion: reduceMotion, triggerOneShot: didChangeState)
            rebuildSurfaceEffects(for: state, size: pillRect.size, reduceMotion: reduceMotion, triggerOneShot: didChangeState)
        }

        private func layoutGeometries(for size: CGSize) {
            let b = CGRect(origin: .zero, size: size)
            clippedInnerContainer.frame = b
            failedLineLayer.frame = CGRect(x: 0, y: 0, width: size.width, height: 2)
            flashLayer.frame = CGRect(x: -size.width, y: -3, width: size.width, height: size.height + 6)

            cometContainer.frame = b
            let insetRect = b.insetBy(dx: 0.5, dy: 0.5)
            let borderPath = CGPath(roundedRect: insetRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
            cometMask.frame = b; cometMask.path = borderPath

            let diag = hypot(size.width, size.height)
            cometGradient.bounds = CGRect(x: 0, y: 0, width: diag, height: diag)
            cometGradient.position = CGPoint(x: size.width / 2, y: size.height / 2)

            breatheLayer.frame = b; breatheLayer.path = borderPath
            breatheLayer.shadowPath = CGPath(roundedRect: b.insetBy(dx: -1, dy: -1), cornerWidth: 7, cornerHeight: 7, transform: nil)
            offlineBorderLayer.frame = b; offlineBorderLayer.path = borderPath
            ringContainer.frame = CGRect(x: 8, y: ((size.height - 14) / 2).rounded(), width: 14, height: 14)
        }

        private func makeStrokeCircle(_ rect: CGRect, inset: CGFloat, color: CGColor, width: CGFloat, dash: [NSNumber]? = nil) -> CAShapeLayer {
            let l = CAShapeLayer()
            l.frame = rect; l.path = CGPath(ellipseIn: rect.insetBy(dx: inset, dy: inset), transform: nil)
            l.fillColor = nil; l.strokeColor = color; l.lineWidth = width; l.lineDashPattern = dash
            return l
        }

        private func makeSpinAnimation(duration: CFTimeInterval) -> CABasicAnimation {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0.0; spin.toValue = -Double.pi * 2.0; spin.duration = duration
            spin.repeatCount = .infinity; spin.timingFunction = CAMediaTimingFunction(name: .linear)
            spin.isRemovedOnCompletion = false
            return spin
        }

        private func rebuildRing(for state: SurfaceState, reduceMotion: Bool, triggerOneShot: Bool) {
            ringContainer.sublayers?.forEach { $0.removeFromSuperlayer() }
            ringContainer.removeAllAnimations()
            let rBounds = CGRect(x: 0, y: 0, width: 14, height: 14)

            switch state {
            case .idle:
                ringContainer.addSublayer(makeStrokeCircle(rBounds, inset: 0.75, color: T.ringIdle.cgColor, width: 1.5))

            case .working:
                ringContainer.addSublayer(makeStrokeCircle(rBounds, inset: 1.25, color: T.ember.withAlphaComponent(0.16).cgColor, width: 2.5))
                let conic = CAGradientLayer()
                conic.name = "workingSpin"
                conic.type = .conic
                conic.frame = rBounds
                conic.startPoint = CGPoint(x: 0.5, y: 0.5)
                conic.endPoint = CGPoint(x: 0.5, y: 1.0)
                conic.colors = [T.ember.withAlphaComponent(0).cgColor, T.ember.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]
                conic.locations = [0, 0.777, 0.778, 1.0]
                conic.mask = makeStrokeCircle(rBounds, inset: 1.25, color: NSColor.black.cgColor, width: 2.5)
                ringContainer.addSublayer(conic)
                if !reduceMotion { conic.add(makeSpinAnimation(duration: 0.9), forKey: "spin") }

            case .progress(let p):
                ringContainer.addSublayer(makeStrokeCircle(rBounds, inset: 1.25, color: T.progressTrack.cgColor, width: 2.5))
                let arc = CAShapeLayer()
                arc.name = "progressArc"
                arc.frame = rBounds
                let arcPath = CGMutablePath()
                arcPath.addArc(center: CGPoint(x: 7, y: 7), radius: 5.75, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 2, clockwise: true)
                arc.path = arcPath
                arc.fillColor = nil
                arc.strokeColor = T.ember.cgColor
                arc.lineWidth = 2.5
                arc.lineCap = .butt
                arc.strokeEnd = CGFloat(min(1.0, max(0.0, p)))
                ringContainer.addSublayer(arc)

            case .waiting:
                if !reduceMotion {
                    let halo = makeStrokeCircle(rBounds, inset: 1.0, color: T.claw.cgColor, width: 2.0)
                    halo.name = "waitingHalo"
                    ringContainer.addSublayer(halo)
                    let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
                    scaleAnim.fromValue = 1.0; scaleAnim.toValue = 2.1
                    let opAnim = CABasicAnimation(keyPath: "opacity")
                    opAnim.fromValue = 0.75; opAnim.toValue = 0.0
                    let group = CAAnimationGroup()
                    group.animations = [scaleAnim, opAnim]
                    group.duration = 1.6; group.repeatCount = .infinity
                    group.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    group.isRemovedOnCompletion = false
                    halo.add(group, forKey: "halo")
                }
                ringContainer.addSublayer(makeStrokeCircle(rBounds, inset: 1.0, color: T.claw.cgColor, width: 2.0))
                let dot = CAShapeLayer()
                dot.name = "waitingDot"
                dot.frame = rBounds
                dot.path = CGPath(ellipseIn: CGRect(x: 5, y: 5, width: 4, height: 4), transform: nil)
                dot.fillColor = T.claw.cgColor
                ringContainer.addSublayer(dot)
                if !reduceMotion {
                    let blink = CABasicAnimation(keyPath: "opacity")
                    blink.fromValue = 1.0; blink.toValue = 0.25; blink.duration = 0.8
                    blink.autoreverses = true; blink.repeatCount = .infinity
                    blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    blink.isRemovedOnCompletion = false
                    dot.add(blink, forKey: "blink")
                }

            case .done:
                let disc = CAShapeLayer()
                disc.frame = rBounds
                disc.path = CGPath(ellipseIn: rBounds, transform: nil)
                disc.fillColor = T.ok.cgColor
                ringContainer.addSublayer(disc)
                let check = CAShapeLayer()
                check.frame = rBounds
                let checkPath = CGMutablePath()
                checkPath.move(to: CGPoint(x: 4.0, y: 14.0 - 7.2))
                checkPath.addLine(to: CGPoint(x: 6.1, y: 14.0 - 9.3))
                checkPath.addLine(to: CGPoint(x: 10.0, y: 14.0 - 5.0))
                check.path = checkPath
                check.fillColor = nil; check.strokeColor = T.ink.cgColor
                check.lineWidth = 1.75; check.lineCap = .round; check.lineJoin = .round
                ringContainer.addSublayer(check)
                if triggerOneShot && !reduceMotion {
                    let pop = CAKeyframeAnimation(keyPath: "transform.scale")
                    pop.values = [1.0, 0.55, 1.25, 1.0]; pop.keyTimes = [0.0, 0.27, 0.64, 1.0]; pop.duration = 0.70
                    ringContainer.add(pop, forKey: "donePop")
                }

            case .failed:
                let disc = CAShapeLayer()
                disc.frame = rBounds
                disc.path = CGPath(ellipseIn: rBounds, transform: nil)
                disc.fillColor = T.error.cgColor
                ringContainer.addSublayer(disc)
                let bang = CAShapeLayer()
                bang.frame = rBounds
                let bangPath = CGMutablePath()
                bangPath.addRoundedRect(in: CGRect(x: 6, y: 14.0 - 8.0, width: 2, height: 5), cornerWidth: 1, cornerHeight: 1)
                bangPath.addRoundedRect(in: CGRect(x: 6, y: 14.0 - 11.5, width: 2, height: 2), cornerWidth: 1, cornerHeight: 1)
                bang.path = bangPath; bang.fillColor = T.ink.cgColor
                ringContainer.addSublayer(bang)

            case .offline:
                ringContainer.addSublayer(makeStrokeCircle(rBounds, inset: 0.75, color: T.faint.cgColor, width: 1.5, dash: [2, 2]))
            }
        }

        private func rebuildSurfaceEffects(for state: SurfaceState, size: CGSize, reduceMotion: Bool, triggerOneShot: Bool) {
            cometContainer.isHidden = (state != .working)
            cometGradient.removeAllAnimations()
            breatheLayer.isHidden = (state != .waiting)
            breatheLayer.removeAllAnimations()
            failedLineLayer.isHidden = (state != .failed)
            offlineBorderLayer.isHidden = (state != .offline)

            if case .progress(let p) = state {
                progressLineLayer.isHidden = false
                updateProgressValue(p, in: size)
            } else {
                progressLineLayer.isHidden = true
            }

            switch state {
            case .working:
                if !reduceMotion { cometGradient.add(makeSpinAnimation(duration: 2.2), forKey: "cometSpin") }
            case .waiting:
                if reduceMotion {
                    breatheLayer.strokeColor = T.claw.withAlphaComponent(0.90).cgColor
                    breatheLayer.shadowOpacity = 0.20
                } else {
                    let strokeAnim = CABasicAnimation(keyPath: "strokeColor")
                    strokeAnim.fromValue = T.claw.withAlphaComponent(0.40).cgColor
                    strokeAnim.toValue = T.claw.withAlphaComponent(0.95).cgColor
                    let shadowAnim = CABasicAnimation(keyPath: "shadowOpacity")
                    shadowAnim.fromValue = 0.0; shadowAnim.toValue = 0.30
                    let group = CAAnimationGroup()
                    group.animations = [strokeAnim, shadowAnim]
                    group.duration = 0.8; group.autoreverses = true; group.repeatCount = .infinity
                    group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    group.isRemovedOnCompletion = false
                    breatheLayer.add(group, forKey: "breathe")
                }
            case .done:
                if triggerOneShot && !reduceMotion && size.width > 0 {
                    flashLayer.opacity = 1.0
                    let sweep = CABasicAnimation(keyPath: "position.x")
                    sweep.fromValue = -0.55 * size.width; sweep.toValue = 2.15 * size.width
                    sweep.duration = 0.96; sweep.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    sweep.fillMode = .forwards
                    flashLayer.add(sweep, forKey: "doneFlash")
                }
            case .failed:
                if triggerOneShot && !reduceMotion {
                    let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
                    shake.values = [0, -2, 2, -2, 2, -1, 0]
                    shake.keyTimes = [0, 0.143, 0.286, 0.429, 0.571, 0.714, 1.0]
                    shake.duration = 0.448
                    add(shake, forKey: "failedShake")
                }
            case .idle, .progress, .offline:
                break
            }
        }

        private func updateProgressValue(_ p: Double, in size: CGSize) {
            let clamped = CGFloat(min(1.0, max(0.0, p)))
            progressLineLayer.frame = CGRect(x: 0, y: 0, width: max(2, size.width * clamped), height: 2)
            if let arc = ringContainer.sublayers?.first(where: { $0.name == "progressArc" }) as? CAShapeLayer {
                arc.strokeEnd = clamped
            }
        }

        /// Steps model-layer properties for deterministic offscreen snapshots/GIF capture.
        func applySnapshotPhase(at t: TimeInterval, doneElapsed: TimeInterval? = nil) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            switch currentState {
            case .working:
                cometGradient.transform = CATransform3DMakeRotation(-CGFloat((t / 2.2) * .pi * 2.0), 0, 0, 1)
                if let spin = ringContainer.sublayers?.first(where: { $0.name == "workingSpin" }) {
                    spin.transform = CATransform3DMakeRotation(-CGFloat((t / 0.9) * .pi * 2.0), 0, 0, 1)
                }
            case .waiting:
                let s = CGFloat(LivingAnimationState.breatheFactor(at: t))
                breatheLayer.strokeColor = T.claw.withAlphaComponent(0.40 + 0.55 * s).cgColor
                breatheLayer.shadowOpacity = Float(0.30 * s)
                if let halo = ringContainer.sublayers?.first(where: { $0.name == "waitingHalo" }) {
                    let h = CGFloat(t.truncatingRemainder(dividingBy: 1.6) / 1.6)
                    halo.transform = CATransform3DMakeScale(1.0 + 1.1 * h, 1.0 + 1.1 * h, 1.0)
                    halo.opacity = Float(0.75 * (1.0 - h))
                }
                if let dot = ringContainer.sublayers?.first(where: { $0.name == "waitingDot" }) {
                    dot.opacity = Float(0.25 + 0.75 * s)
                }
            case .done:
                if let el = doneElapsed, let frac = LivingAnimationState.doneFlashFraction(elapsed: el), lastSize.width > 0 {
                    flashLayer.opacity = 1.0
                    flashLayer.position.x = CGFloat(-0.55 * lastSize.width + frac * 2.1 * lastSize.width)
                } else {
                    flashLayer.opacity = 0.0
                }
            default:
                break
            }
            CATransaction.commit()
        }

        func setLayerPaused(_ paused: Bool) {
            guard isLayerPaused != paused else { return }
            isLayerPaused = paused
            if paused {
                let pausedTime = convertTime(CACurrentMediaTime(), from: nil)
                speed = 0.0; timeOffset = pausedTime
            } else {
                let pausedTime = timeOffset
                speed = 1.0; timeOffset = 0.0; beginTime = 0.0
                beginTime = convertTime(CACurrentMediaTime(), from: nil) - pausedTime
            }
        }
    }
}
