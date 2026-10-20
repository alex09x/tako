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
    /// The crab of a classic tab (Terminal UI › «Краб во вкладке: 7
    /// состояний»), drawn and moved by Core Animation as the pills' rings
    /// are: it scurries while a command runs, hops once on a success or a
    /// bell, shivers once on a failure and pulses while ssh reconnects; a
    /// ghost stands still at 45 %. Reduce Motion keeps the colours only
    /// ("анимации выключаются, остаётся только смена цвета"), and a paused
    /// layer -- a window nobody sees -- keeps its frame.
    final class CrabLayer: CALayer {
        /// The design's keyframes: `crab-scuttle 0.8s steps(1)`, `crab-hop`
        /// 1.4 s after exit 0 and 2 s on a bell, the shiver's 0.4 s
        /// ("дрожь один раз (0.4s)") and `crab-pulse 1.1s ease-in-out`.
        enum Motion {
            static let scuttleCycle: CFTimeInterval = 0.8
            /// CSS `translateX(dx) rotate(θ)`, each held a quarter of the cycle.
            static let scuttlePoses: [(dx: CGFloat, degrees: CGFloat)] = [(-2, -8), (1, 5), (3, -5), (1, 8)]
            /// Points up: 4, back, 2, back, rest.
            static let hopRise: [CGFloat] = [0, 4, 0, 2, 0, 0]
            static let hopKeyTimes: [Double] = [0, 0.30, 0.55, 0.70, 0.85, 1]
            static let successHop: CFTimeInterval = 1.4
            static let attentionHop: CFTimeInterval = 2
            static let shakeOffsets: [CGFloat] = [0, -2, 2, -2, 2, 0]
            static let shakeKeyTimes: [Double] = [0, 0.2, 0.4, 0.6, 0.8, 1]
            static let shakeDuration: CFTimeInterval = 0.4
            static let pulseCycle: CFTimeInterval = 1.1
            static let pulseOpacity: [Float] = [1, 0.35, 1]
        }

        enum Key { static let scuttle = "crabScuttle", hop = "crabHop", shake = "crabShake", pulse = "crabPulse" }
        enum Name { static let glyph = "crabGlyph", claws = "crabClaws", body = "crabBody", unread = "crabUnread" }

        /// What moves: the claws and the body, about the crab's centre.
        let glyph = CALayer()
        let claws = CAShapeLayer()
        let body = CAShapeLayer()
        /// The unread dot stays where it is while the crab moves.
        let unreadDot = CAShapeLayer()
        private(set) var shownState: CrabState?
        private var shownReduced = false
        private var drawn: (size: CGSize, scale: CGFloat, rows: [String])?
        private var restingRect: CGRect = .zero
        private(set) var isLayerPaused = false

        override init() {
            super.init()
            glyph.name = Name.glyph
            claws.name = Name.claws
            body.name = Name.body
            unreadDot.name = Name.unread
            unreadDot.fillColor = Brand.claw.cgColor
            unreadDot.isHidden = true
            glyph.addSublayer(claws)
            glyph.addSublayer(body)
            addSublayer(glyph)
            addSublayer(unreadDot)
        }

        override init(layer: Any) { super.init(layer: layer) }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        /// Shows `state` in `rect`. A change into a state plays its one-off
        /// from now; the first state a crab is shown in does not.
        func apply(state: CrabState, in rect: CGRect, unread: Bool, reduceMotion: Bool, paused: Bool, scale: CGFloat) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            if restingRect != rect {
                restingRect = rect
                bounds = CGRect(origin: .zero, size: rect.size)
                position = CGPoint(x: rect.midX, y: rect.midY)
            }
            let rows = CrabPainter.rows(for: state)
            if drawn?.size != rect.size || drawn?.scale != scale || drawn?.rows != rows {
                for layer in [self, glyph, claws, body, unreadDot] { layer.contentsScale = scale }
                glyph.frame = bounds
                let cells = CrabPainter.cells(rows, in: bounds, scale: scale)
                claws.path = cells.claws
                body.path = cells.body
                unreadDot.path = CGPath(ellipseIn: CGRect(x: bounds.maxX - 3, y: bounds.maxY - 3, width: 3, height: 3), transform: nil)
                drawn = (rect.size, scale, rows)
            }
            let colors = CrabPainter.colors(for: state)
            claws.fillColor = colors.claws.cgColor
            body.fillColor = colors.body.cgColor
            glyph.opacity = CrabPainter.opacity(for: state)
            unreadDot.isHidden = !unread
            let changed = shownState.map { !$0.isSameKind(as: state) } ?? true
            if changed || shownReduced != reduceMotion {
                restartMotion(for: state, entered: changed && shownState != nil, reduceMotion: reduceMotion)
            }
            shownState = state
            shownReduced = reduceMotion
            setLayerPaused(paused)
        }

        private func restartMotion(for state: CrabState, entered: Bool, reduceMotion: Bool) {
            glyph.removeAllAnimations()
            guard !reduceMotion else { return }
            switch state {
            case .running: glyph.add(Self.scuttle(), forKey: Key.scuttle)
            case .reconnecting: glyph.add(Self.pulse(), forKey: Key.pulse)
            case .succeeded where entered: glyph.add(Self.hop(over: Motion.successHop), forKey: Key.hop)
            case .attention where entered: glyph.add(Self.hop(over: Motion.attentionHop), forKey: Key.hop)
            case .failed where entered: glyph.add(Self.shake(), forKey: Key.shake)
            default: break
            }
        }

        /// CSS `translateX(dx) rotate(θ)`: θ turns clockwise on screen, a
        /// negative angle in a layer's space, whose y goes up.
        static func pose(dx: CGFloat, degrees: CGFloat) -> CATransform3D {
            CATransform3DRotate(CATransform3DMakeTranslation(dx, 0, 0), -degrees * .pi / 180, 0, 0, 1)
        }

        static func scuttle() -> CAKeyframeAnimation {
            let scuttle = CAKeyframeAnimation(keyPath: "transform")
            scuttle.values = Motion.scuttlePoses.map { NSValue(caTransform3D: pose(dx: $0.dx, degrees: $0.degrees)) }
            scuttle.keyTimes = [0, 0.25, 0.5, 0.75, 1]
            scuttle.calculationMode = .discrete
            scuttle.duration = Motion.scuttleCycle
            scuttle.repeatCount = .infinity
            return scuttle
        }

        static func hop(over duration: CFTimeInterval) -> CAKeyframeAnimation {
            keyframes("transform.translation.y", Motion.hopRise.map { NSNumber(value: Double($0)) }, at: Motion.hopKeyTimes, over: duration)
        }

        static func shake() -> CAKeyframeAnimation {
            keyframes("transform.translation.x", Motion.shakeOffsets.map { NSNumber(value: Double($0)) },
                      at: Motion.shakeKeyTimes, over: Motion.shakeDuration)
        }

        static func pulse() -> CAKeyframeAnimation {
            let pulse = keyframes("opacity", Motion.pulseOpacity.map { NSNumber(value: $0) }, at: [0, 0.5, 1], over: Motion.pulseCycle)
            pulse.repeatCount = .infinity
            return pulse
        }

        /// CSS `ease-in-out` eases each step between two keyframes.
        private static func keyframes(_ keyPath: String, _ values: [NSNumber], at times: [Double],
                                      over duration: CFTimeInterval) -> CAKeyframeAnimation {
            let keyframes = CAKeyframeAnimation(keyPath: keyPath)
            keyframes.values = values
            keyframes.keyTimes = times.map { NSNumber(value: $0) }
            keyframes.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: values.count - 1)
            keyframes.duration = duration
            return keyframes
        }

        /// A tab lifted by a drag turns its crab with it, about the tab's centre.
        func setPose(tilt degrees: CGFloat, about pivot: CGPoint) {
            let angle = -degrees * .pi / 180
            let rest = CGPoint(x: restingRect.midX - pivot.x, y: restingRect.midY - pivot.y)
            let centre = CGPoint(x: pivot.x + rest.x * cos(angle) - rest.y * sin(angle),
                                 y: pivot.y + rest.x * sin(angle) + rest.y * cos(angle))
            let turn = degrees == 0 ? CATransform3DIdentity : CATransform3DMakeRotation(angle, 0, 0, 1)
            guard position != centre || !CATransform3DEqualToTransform(transform, turn) else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            position = centre
            transform = turn
            CATransaction.commit()
        }

        func setShown(_ shown: Bool) {
            guard isHidden == shown else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            isHidden = !shown
            CATransaction.commit()
        }

        func setLayerPaused(_ paused: Bool) {
            guard isLayerPaused != paused else { return }
            isLayerPaused = paused
            if paused {
                let pausedTime = convertTime(CACurrentMediaTime(), from: nil)
                speed = 0
                timeOffset = pausedTime
            } else {
                let pausedTime = timeOffset
                speed = 1
                timeOffset = 0
                beginTime = 0
                beginTime = convertTime(CACurrentMediaTime(), from: nil) - pausedTime
            }
        }
    }
}
