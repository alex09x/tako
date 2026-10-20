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
        /// The live ring's last ripple: a new count ripples it once.
        var lastPulses = 0

        /// The surface's corners and where its ring sits: a pill's by default,
        /// a sidebar row's for `SidebarStatusLayerView`.
        struct Geometry: Equatable {
            var cornerRadius: CGFloat = 6
            /// The ring's origin, y up; nil puts it 8-9 pt in, centred.
            var ringOrigin: CGPoint?
            /// How far in from each side the progress line runs.
            var progressInset: CGFloat = 0
            /// A sidebar row in progress runs the comet too, its line 1 pt up.
            var cometForProgress = false
        }

        var geometry = Geometry() {
            didSet { if geometry != oldValue { lastSize = .zero } }
        }

        /// False draws the ring alone: no border, glow, glint or line.
        var drawsSurface = true

        private func ringFrame(in size: CGSize, ringX: CGFloat) -> CGRect {
            let origin = geometry.ringOrigin ?? CGPoint(x: ringX, y: ((size.height - 14) / 2).rounded())
            return CGRect(origin: origin, size: CGSize(width: 14, height: 14))
        }

        private let clippedInnerContainer = CALayer()
        private let failedLineLayer = CAShapeLayer()
        private let progressLineLayer = CAGradientLayer()
        private let flashLayer = DoneGlintLayer()

        private let cometContainer = CALayer()
        private let cometMask = CAShapeLayer()
        private let cometGradient = CAGradientLayer()

        private let breatheGlowContainer = CALayer()
        private let breatheGlowMask = CAShapeLayer()
        private let breatheGlowLayer = CAShapeLayer()
        private let breatheLayer = CAShapeLayer()
        private let offlineBorderLayer = CAShapeLayer()
        let ringContainer = CALayer()

        override init() { super.init(); setupSublayers() }
        override init(layer: Any) { super.init(layer: layer) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        private func setupSublayers() {
            contentsScale = 2.0; masksToBounds = false
            for l: CALayer in [clippedInnerContainer, failedLineLayer, progressLineLayer, flashLayer, cometContainer, cometMask, cometGradient, breatheGlowContainer, breatheGlowMask, breatheGlowLayer, breatheLayer, offlineBorderLayer, ringContainer] {
                l.contentsScale = 2.0
            }
            clippedInnerContainer.cornerRadius = 6; clippedInnerContainer.masksToBounds = true
            addSublayer(clippedInnerContainer)

            failedLineLayer.fillColor = T.error.cgColor; failedLineLayer.fillRule = .evenOdd; failedLineLayer.isHidden = true
            clippedInnerContainer.addSublayer(failedLineLayer)

            progressLineLayer.colors = [T.rust.cgColor, T.ember.cgColor]
            progressLineLayer.startPoint = CGPoint(x: 0, y: 0.5); progressLineLayer.endPoint = CGPoint(x: 1, y: 0.5)
            progressLineLayer.cornerRadius = 1; progressLineLayer.isHidden = true
            clippedInnerContainer.addSublayer(progressLineLayer)

            flashLayer.opacity = 0
            clippedInnerContainer.addSublayer(flashLayer)

            cometMask.fillColor = nil; cometMask.strokeColor = NSColor.black.cgColor; cometMask.lineWidth = 1.0
            cometContainer.mask = cometMask; cometContainer.isHidden = true

            cometGradient.type = .conic
            cometGradient.startPoint = CGPoint(x: 0.5, y: 0.5); cometGradient.endPoint = CGPoint(x: 0.5, y: 1.0)
            cometGradient.colors = [NSColor.clear.cgColor, T.claw.cgColor, T.rust.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]
            cometGradient.locations = [0.0, 0.12, 0.22, 0.38, 1.0]
            cometContainer.addSublayer(cometGradient)
            addSublayer(cometContainer)

            breatheGlowMask.fillRule = .evenOdd; breatheGlowContainer.mask = breatheGlowMask; breatheGlowContainer.isHidden = true
            breatheGlowLayer.fillColor = NSColor.black.cgColor
            breatheGlowLayer.shadowColor = T.claw.cgColor; breatheGlowLayer.shadowOffset = .zero; breatheGlowLayer.shadowRadius = 8.0
            breatheGlowContainer.addSublayer(breatheGlowLayer)
            addSublayer(breatheGlowContainer)

            breatheLayer.fillColor = nil; breatheLayer.lineWidth = 1.0
            breatheLayer.strokeColor = T.claw.withAlphaComponent(0.65).cgColor; breatheLayer.isHidden = true
            addSublayer(breatheLayer)

            offlineBorderLayer.fillColor = nil; offlineBorderLayer.lineWidth = 1.0
            offlineBorderLayer.strokeColor = T.ghostBorder.cgColor; offlineBorderLayer.lineDashPattern = [3, 3]
            offlineBorderLayer.isHidden = true
            addSublayer(offlineBorderLayer)

            ringContainer.masksToBounds = false
            addSublayer(ringContainer)
        }

        func apply(state: SurfaceState, in pillRect: CGRect, hideRing: Bool, reduceMotion: Bool, paused: Bool,
                   allowFrameAnimation: Bool = false, pulses: Int = 0) {
            defer { rippleIfPulsed(pulses, state: state, reduceMotion: reduceMotion, paused: paused) }
            let previousState = currentState
            let didChangeState = (previousState != nil && previousState != state)
            let isFirstApply = (previousState == nil)
            let sizeChanged = (lastSize != pillRect.size) || (lastReduceMotion != reduceMotion)

            CATransaction.begin()
            CATransaction.setDisableActions(!allowFrameAnimation)
            let savedTransform = transform; transform = CATransform3DIdentity
            frame = pillRect; transform = savedTransform
            let savedRingTransform = ringContainer.transform; ringContainer.transform = CATransform3DIdentity
            ringContainer.isHidden = hideRing
            let ringX: CGFloat = (state == .working || state == .offline) ? 9 : 8
            ringContainer.frame = ringFrame(in: pillRect.size, ringX: ringX)
            if sizeChanged { lastSize = pillRect.size; lastReduceMotion = reduceMotion; layoutGeometries(for: pillRect.size, ringX: ringX) }
            ringContainer.transform = savedRingTransform
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

        private func layoutGeometries(for size: CGSize, ringX: CGFloat = 8) {
            let b = CGRect(origin: .zero, size: size)
            let r = geometry.cornerRadius
            clippedInnerContainer.frame = b
            clippedInnerContainer.cornerRadius = r
            failedLineLayer.frame = b
            let errPath = CGMutablePath()
            errPath.addRect(b)
            errPath.addRoundedRect(in: b.offsetBy(dx: 0, dy: 2), cornerWidth: r, cornerHeight: r)
            failedLineLayer.path = errPath
            flashLayer.layout(for: size)

            cometContainer.frame = b
            let insetRect = b.insetBy(dx: 0.5, dy: 0.5)
            let borderPath = CGPath(roundedRect: insetRect, cornerWidth: r, cornerHeight: r, transform: nil)
            cometMask.frame = b; cometMask.path = borderPath

            let diag = hypot(size.width, size.height)
            cometGradient.bounds = CGRect(x: 0, y: 0, width: diag, height: diag)
            cometGradient.position = CGPoint(x: size.width / 2, y: size.height / 2)

            let pad: CGFloat = 24
            let outer = CGRect(x: 0, y: 0, width: size.width + pad * 2, height: size.height + pad * 2)
            let inner = CGRect(x: pad, y: pad, width: size.width, height: size.height)
            breatheGlowContainer.frame = CGRect(x: -pad, y: -pad, width: outer.width, height: outer.height)
            breatheGlowMask.frame = outer
            let mp = CGMutablePath(); mp.addRect(outer); mp.addRoundedRect(in: inner, cornerWidth: r, cornerHeight: r)
            breatheGlowMask.path = mp
            breatheGlowLayer.frame = outer; breatheGlowLayer.path = CGPath(roundedRect: inner, cornerWidth: r, cornerHeight: r, transform: nil)
            breatheGlowLayer.shadowPath = CGPath(roundedRect: inner.insetBy(dx: -1, dy: -1), cornerWidth: r + 1, cornerHeight: r + 1, transform: nil)
            breatheLayer.frame = b; breatheLayer.path = borderPath
            offlineBorderLayer.frame = b; offlineBorderLayer.path = borderPath
            ringContainer.frame = ringFrame(in: size, ringX: ringX)
        }

        private func makeStrokeCircle(_ rect: CGRect, inset: CGFloat, color: CGColor, width: CGFloat, dash: [NSNumber]? = nil) -> CAShapeLayer {
            let l = CAShapeLayer()
            l.contentsScale = 2.0; l.frame = rect; l.path = CGPath(ellipseIn: rect.insetBy(dx: inset, dy: inset), transform: nil)
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
                conic.name = "workingSpin"; conic.type = .conic; conic.frame = rBounds
                conic.startPoint = CGPoint(x: 0.5, y: 0.5); conic.endPoint = CGPoint(x: 0.5, y: 1.0)
                conic.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, T.ember.cgColor, T.ember.withAlphaComponent(0).cgColor]
                conic.locations = [0, 0.222, 0.223, 1.0]
                conic.mask = makeStrokeCircle(rBounds, inset: 1.25, color: NSColor.black.cgColor, width: 2.5)
                ringContainer.addSublayer(conic)
                if !reduceMotion { conic.add(makeSpinAnimation(duration: 0.9), forKey: "spin") }

            case .progress(let p):
                ringContainer.addSublayer(makeStrokeCircle(rBounds, inset: 1.25, color: T.progressTrack.cgColor, width: 2.5))
                let arc = CAShapeLayer()
                arc.name = "progressArc"; arc.frame = rBounds
                let arcPath = CGMutablePath()
                arcPath.addArc(center: CGPoint(x: 7, y: 7), radius: 5.75, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 2, clockwise: true)
                arc.path = arcPath; arc.fillColor = nil; arc.strokeColor = T.ember.cgColor
                arc.lineWidth = 2.5; arc.lineCap = .butt; arc.strokeEnd = CGFloat(min(1.0, max(0.0, p)))
                ringContainer.addSublayer(arc)

            case .waiting:
                if !reduceMotion {
                    let halo = makeStrokeCircle(rBounds, inset: 1.0, color: T.claw.cgColor, width: 2.0)
                    halo.name = "waitingHalo"; ringContainer.addSublayer(halo)
                    let scaleAnim = CABasicAnimation(keyPath: "transform.scale"); scaleAnim.fromValue = 1.0; scaleAnim.toValue = 2.1
                    let opAnim = CABasicAnimation(keyPath: "opacity"); opAnim.fromValue = 0.75; opAnim.toValue = 0.0
                    let group = CAAnimationGroup()
                    group.animations = [scaleAnim, opAnim]; group.duration = 1.6; group.repeatCount = .infinity
                    group.timingFunction = CAMediaTimingFunction(name: .easeOut); group.isRemovedOnCompletion = false
                    halo.add(group, forKey: "halo")
                }
                ringContainer.addSublayer(makeStrokeCircle(rBounds, inset: 1.0, color: T.claw.cgColor, width: 2.0))
                let dot = CAShapeLayer()
                dot.name = "waitingDot"; dot.frame = rBounds
                dot.path = CGPath(ellipseIn: CGRect(x: 5, y: 5, width: 4, height: 4), transform: nil)
                dot.fillColor = T.claw.cgColor
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
                disc.frame = rBounds; disc.path = CGPath(ellipseIn: rBounds, transform: nil); disc.fillColor = T.ok.cgColor
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
                disc.frame = rBounds; disc.path = CGPath(ellipseIn: rBounds, transform: nil); disc.fillColor = T.error.cgColor
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
                let ripple = makeStrokeCircle(rBounds, inset: 0.75, color: T.claw.cgColor, width: 1.5)
                ripple.name = "liveRipple"; ripple.opacity = 0
                ringContainer.addSublayer(ripple)
                let alpha = flowing ? 1 : CGFloat(LiveRingStyle.quietOpacity)
                ringContainer.addSublayer(makeStrokeCircle(rBounds, inset: 0.75, color: T.ember.withAlphaComponent(alpha).cgColor, width: 1.5))
            }
            ringContainer.sublayers?.forEach { $0.contentsScale = 2.0 }
        }

        private func rebuildSurfaceEffects(for state: SurfaceState, size: CGSize, reduceMotion: Bool, triggerOneShot: Bool) {
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
            if comet && !reduceMotion { cometGradient.add(makeSpinAnimation(duration: 2.2), forKey: "cometSpin") }
            breatheGlowContainer.isHidden = (state != .waiting); breatheGlowLayer.removeAllAnimations()
            breatheLayer.isHidden = (state != .waiting); breatheLayer.removeAllAnimations()
            failedLineLayer.isHidden = (state != .failed); offlineBorderLayer.isHidden = (state != .offline)

            if case .progress(let p) = state {
                progressLineLayer.isHidden = false; updateProgressValue(p, in: size)
            } else {
                progressLineLayer.isHidden = true
            }

            switch state {
            case .waiting:
                if reduceMotion {
                    breatheLayer.strokeColor = T.claw.withAlphaComponent(0.90).cgColor
                    breatheGlowLayer.shadowOpacity = 0.20
                } else {
                    let eio = CAMediaTimingFunction(name: .easeInEaseOut)
                    let strokeAnim = CABasicAnimation(keyPath: "strokeColor")
                    strokeAnim.fromValue = T.claw.withAlphaComponent(0.40).cgColor; strokeAnim.toValue = T.claw.withAlphaComponent(0.95).cgColor
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

        private func updateProgressValue(_ p: Double, in size: CGSize) {
            let clamped = CGFloat(min(1.0, max(0.0, p)))
            let inset = geometry.progressInset
            progressLineLayer.frame = CGRect(x: inset, y: geometry.cometForProgress ? 1 : 0,
                                             width: max(2, (size.width - inset * 2) * clamped), height: 2)
            if let arc = ringContainer.sublayers?.first(where: { $0.name == "progressArc" }) as? CAShapeLayer { arc.strokeEnd = clamped }
        }

        /// Steps model-layer properties for deterministic offscreen snapshots/GIF capture.
        func applySnapshotPhase(at t: TimeInterval, doneElapsed: TimeInterval? = nil, failedElapsed: TimeInterval? = nil) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            transform = CATransform3DIdentity
            ringContainer.transform = CATransform3DIdentity
            switch currentState {
            case .working:
                let cometRad = CGFloat(LivingAnimationState.cometDegrees(at: t) * .pi / 180.0)
                cometGradient.transform = CATransform3DMakeRotation(-cometRad, 0, 0, 1)
                if let spin = ringContainer.sublayers?.first(where: { $0.name == "workingSpin" }) {
                    let spinRad = CGFloat(LivingAnimationState.spinDegrees(at: t) * .pi / 180.0)
                    spin.transform = CATransform3DMakeRotation(-spinRad, 0, 0, 1)
                }
            case .waiting:
                let s = CGFloat(LivingAnimationState.breatheFactor(at: t))
                breatheLayer.strokeColor = T.claw.withAlphaComponent(0.40 + 0.55 * s).cgColor
                breatheGlowLayer.shadowOpacity = Float(0.30 * s)
                if let halo = ringContainer.sublayers?.first(where: { $0.name == "waitingHalo" }) {
                    let hm = LivingAnimationState.haloMetrics(at: t)
                    halo.transform = CATransform3DMakeScale(hm.scale, hm.scale, 1.0)
                    halo.opacity = Float(hm.opacity)
                }
                if let dot = ringContainer.sublayers?.first(where: { $0.name == "waitingDot" }) {
                    dot.opacity = Float(LivingAnimationState.blinkOpacity(at: t))
                }
            case .done:
                if let el = doneElapsed {
                    let pop = LivingAnimationState.donePopScale(elapsed: el)
                    ringContainer.transform = CATransform3DMakeScale(pop, pop, 1.0)
                }
                if let el = doneElapsed, let k = DoneGlint.progress(elapsed: el), lastSize.width > 0 {
                    flashLayer.opacity = 1.0
                    flashLayer.position.x = flashLayer.x(at: k)
                } else {
                    flashLayer.opacity = 0.0
                }
            case .failed:
                if let el = failedElapsed {
                    let dx = LivingAnimationState.failedShakeOffset(elapsed: el)
                    transform = CATransform3DMakeTranslation(dx, 0, 0)
                }
            default:
                break
            }
            CATransaction.commit()
        }

        /// Off its place by `dx` with the rest of a shaking pill.
        func setShake(_ dx: CGFloat) {
            guard transform.m41 != dx || !CATransform3DIsAffine(transform) else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            transform = dx == 0 ? CATransform3DIdentity : CATransform3DMakeTranslation(dx, 0, 0)
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
