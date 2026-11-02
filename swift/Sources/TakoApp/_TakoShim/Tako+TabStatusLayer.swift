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
        private(set) var currentPalette: TabStatusPalette?
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
        var drawsSurface = true {
            didSet { if drawsSurface != oldValue { currentState = nil } }
        }

        func ringFrame(in size: CGSize, ringX: CGFloat) -> CGRect {
            let origin = geometry.ringOrigin ?? CGPoint(x: ringX, y: ((size.height - 14) / 2).rounded())
            return CGRect(origin: origin, size: CGSize(width: 14, height: 14))
        }

        let clippedInnerContainer = CALayer()
        let failedLineLayer = CAShapeLayer()
        let progressLineLayer = CAGradientLayer()
        let flashLayer = DoneGlintLayer()

        let cometContainer = CALayer()
        let cometMask = CAShapeLayer()
        let cometGradient = CAGradientLayer()

        let breatheGlowContainer = CALayer()
        let breatheGlowMask = CAShapeLayer()
        let breatheGlowLayer = CAShapeLayer()
        let breatheLayer = CAShapeLayer()
        let offlineBorderLayer = CAShapeLayer()
        let ringContainer = CALayer()

        override init() { super.init(); setupSublayers() }
        override init(layer: Any) { super.init(layer: layer) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// Each effect's layer by name, as a test or a debugger finds it.
        enum LayerName {
            static let failedLine = "failedLine", progressLine = "progressLine", doneGlint = "doneGlint"
            static let comet = "comet", cometGradient = "cometGradient"
            static let breatheGlow = "breatheGlow", breatheGlowShadow = "breatheGlowShadow", breathe = "breathe"
            static let offlineBorder = "offlineBorder", ring = "ring"
        }

        private func setupSublayers() {
            contentsScale = 2.0; masksToBounds = false
            failedLineLayer.name = LayerName.failedLine; progressLineLayer.name = LayerName.progressLine
            flashLayer.name = LayerName.doneGlint
            cometContainer.name = LayerName.comet; cometGradient.name = LayerName.cometGradient
            breatheGlowContainer.name = LayerName.breatheGlow; breatheGlowLayer.name = LayerName.breatheGlowShadow
            breatheLayer.name = LayerName.breathe; offlineBorderLayer.name = LayerName.offlineBorder
            ringContainer.name = LayerName.ring
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
            cometGradient.colors = Self.cometColors
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
                   allowFrameAnimation: Bool = false, pulses: Int = 0,
                   palette: TabStatusPalette? = nil) {
            defer { rippleIfPulsed(pulses, state: state, reduceMotion: reduceMotion, paused: paused) }
            let palette = palette ?? Tako.tabStatusPalette()
            let previousState = currentState
            let previousPalette = currentPalette
            // A new percentage is the same state: the arc and the line move
            // and nothing is rebuilt -- a rebuild started a sidebar row's
            // comet over at every progress report.
            let sameState: Bool = {
                if case .progress = previousState, case .progress = state { return true }
                return previousState == state
            }()
            let didChangeState = (previousState != nil && !sameState)
            let didChangePalette = (previousPalette != nil && previousPalette != palette)
            let isFirstApply = (previousState == nil)
            let sizeChanged = (lastSize != pillRect.size)
            let reduceMotionChanged = (lastReduceMotion != reduceMotion)

            CATransaction.begin()
            CATransaction.setDisableActions(!allowFrameAnimation)
            let savedTransform = transform; transform = CATransform3DIdentity
            frame = pillRect; transform = savedTransform
            let savedRingTransform = ringContainer.transform; ringContainer.transform = CATransform3DIdentity
            ringContainer.isHidden = hideRing
            let ringX: CGFloat = (state == .working || state == .offline) ? 9 : 8
            ringContainer.frame = ringFrame(in: pillRect.size, ringX: ringX)
            if sizeChanged || reduceMotionChanged {
                lastSize = pillRect.size; lastReduceMotion = reduceMotion; layoutGeometries(for: pillRect.size, ringX: ringX)
            }
            ringContainer.transform = savedRingTransform
            CATransaction.commit()
            setLayerPaused(paused)

            // A new size or place is laid out above, not rebuilt: a sidebar row
            // that finishes loses a point of padding in the same pass, and a
            // rebuild took its pop off before it was drawn.
            guard isFirstApply || didChangeState || didChangePalette || reduceMotionChanged else {
                currentState = state
                currentPalette = palette
                if case .progress(let p) = state { updateProgressValue(p, in: pillRect.size, palette: palette) }
                return
            }

            currentState = state
            currentPalette = palette
            rebuildRing(for: state, reduceMotion: reduceMotion, triggerOneShot: didChangeState, palette: palette)
            rebuildSurfaceEffects(for: state, size: pillRect.size, reduceMotion: reduceMotion, triggerOneShot: didChangeState, palette: palette)
        }

        /// The comet: Claw into Rust over a quarter of the turn, the rest clear.
        static let cometColors = [NSColor.clear.cgColor, T.claw.cgColor, T.rust.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]
        /// The working border that does not move: Ember all round, as the sidebar's SwiftUI rows draw it.
        static let stillBorderColors = Array(repeating: T.ember.withAlphaComponent(0.8).cgColor, count: 5)

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
                let waitingColor = currentPalette?.waiting ?? T.claw.cgColor
                breatheLayer.strokeColor = waitingColor.copy(alpha: 0.40 + 0.55 * s)
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
            setPose(dx: dx, tiltDegrees: 0)
        }

        /// Off its place by `dx` and turned by `tiltDegrees` (CSS sense,
        /// negative anticlockwise) with the rest of its pill: shaking, or
        /// lifted by a drag.
        func setPose(dx: CGFloat, tiltDegrees: CGFloat) {
            var pose = CATransform3DMakeTranslation(dx, 0, 0)
            if tiltDegrees != 0 { pose = CATransform3DRotate(pose, -tiltDegrees * .pi / 180, 0, 0, 1) }
            guard !CATransform3DEqualToTransform(transform, pose) else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            transform = pose
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
