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
    /// How the tab strip moves as its tabs change (Terminal UI, «Вкладки:
    /// анатомия, состояния, переходы»): a new tab grows from nothing in
    /// 160 ms, ease-out; a closed one collapses in 140 ms, ease-in, its
    /// neighbours closing up; the active bar travels to a newly chosen tab
    /// in 120 ms while the content changes at once; a dragged tab is lifted
    /// -- a shadow, tilted 3° -- its neighbours make room in 120 ms, and
    /// dropped it springs into its place (spring 300/24). A bar button's
    /// hover fill comes in over 80 ms.
    ///
    /// Every tab is a window with a strip of its own, and the strip that
    /// shows after a change is not the one that saw it, so the group keeps
    /// what moves. Reduce Motion, or a strip nobody sees, takes every change
    /// at once.
    @MainActor
    final class TabStripTransitions {
        static let appearDuration: CFTimeInterval = 0.16
        static let closeDuration: CFTimeInterval = 0.14
        static let barDuration: CFTimeInterval = 0.12
        static let reorderDuration: CFTimeInterval = 0.12
        static let hoverDuration: CFTimeInterval = 0.08
        static let springStiffness = 300.0
        static let springDamping = 24.0
        /// Long enough for the spring to come to rest within half a point.
        static let springSettle: CFTimeInterval = 0.6
        /// CSS rotate(-3deg): anticlockwise on screen.
        static let liftTiltDegrees: CGFloat = -3
        /// CSS box-shadow: 0 14px 30px rgba(0, 0, 0, .55).
        static let liftShadowOffset: CGFloat = 14
        static let liftShadowBlur: CGFloat = 30
        static let liftShadowAlpha: CGFloat = 0.55

        /// The clock every transition is timed on; a test sets its own.
        static var clock: () -> CFTimeInterval = { CACurrentMediaTime() }

        static let easeIn: (Double) -> Double = CSSTiming.cubicBezier(0.42, 0, 1, 1)

        struct Closing: Equatable {
            let index: Int
            let width: CGFloat
            let at: CFTimeInterval
        }

        private(set) var appeared: [ObjectIdentifier: CFTimeInterval] = [:]
        private(set) var closings: [Closing] = []
        private(set) var barMove: (from: CGRect, at: CFTimeInterval)?
        /// Each tab's frame as last laid out at rest: where a closed tab
        /// was and how wide, where the bar starts from.
        var restingFrames: [ObjectIdentifier: CGRect] = [:]

        // MARK: What happened

        func tabAppeared(_ window: NSWindow) {
            appeared[ObjectIdentifier(window)] = Self.clock()
        }

        /// `index` is the tab's place among the tabs shown before it went.
        func tabClosed(_ window: NSWindow, at index: Int) {
            let id = ObjectIdentifier(window)
            if let frame = restingFrames[id] {
                closings.append(Closing(index: index, width: frame.width, at: Self.clock()))
            }
            restingFrames[id] = nil
            appeared[id] = nil
        }

        func selectionMoved(from window: NSWindow?) {
            guard let window, let frame = restingFrames[ObjectIdentifier(window)] else { return }
            barMove = (frame, Self.clock())
        }

        // MARK: Where things are now

        /// How much of its width a tab has grown into: 0 just opened, 1 at rest.
        func widthFactor(for window: NSWindow, now: CFTimeInterval, still: Bool) -> CGFloat {
            guard !still, let at = appeared[ObjectIdentifier(window)] else { return 1 }
            return Self.appearFactor(elapsed: now - at)
        }

        /// The room closed tabs still take at their places among the tabs:
        /// what is left of their width, and of the gap after it.
        func closingRoom(now: CFTimeInterval, still: Bool) -> [(index: Int, width: CGFloat, left: CGFloat)] {
            guard !still else { return [] }
            return closings.compactMap { c in
                let left = Self.closeFactor(elapsed: now - c.at)
                return left > 0 ? (c.index, c.width * left, left) : nil
            }
        }

        /// The active bar on its way to `target`, or at it.
        func barFrame(to target: CGRect, now: CFTimeInterval, still: Bool) -> CGRect {
            guard !still, let move = barMove, now - move.at < Self.barDuration else { return target }
            let k = Self.barProgress(elapsed: now - move.at)
            return CGRect(x: move.from.minX + (target.minX - move.from.minX) * k,
                          y: target.minY,
                          width: move.from.width + (target.width - move.from.width) * k,
                          height: target.height)
        }

        /// Whether anything above is still moving at `now`.
        func isMoving(now: CFTimeInterval) -> Bool {
            appeared.values.contains { now - $0 < Self.appearDuration }
                || closings.contains { now - $0.at < Self.closeDuration }
                || barMove.map { now - $0.at < Self.barDuration } == true
        }

        /// Lets go of what has run its time.
        func expire(now: CFTimeInterval) {
            appeared = appeared.filter { now - $0.value < Self.appearDuration }
            closings.removeAll { now - $0.at >= Self.closeDuration }
            if let move = barMove, now - move.at >= Self.barDuration { barMove = nil }
        }

        // MARK: Curves

        static func appearFactor(elapsed: CFTimeInterval) -> CGFloat {
            CGFloat(CSSTiming.easeOut(max(0, elapsed) / appearDuration))
        }

        static func closeFactor(elapsed: CFTimeInterval) -> CGFloat {
            1 - CGFloat(easeIn(max(0, elapsed) / closeDuration))
        }

        static func barProgress(elapsed: CFTimeInterval) -> CGFloat {
            CGFloat(CSSTiming.easeOut(max(0, elapsed) / barDuration))
        }

        static func reorderProgress(elapsed: CFTimeInterval) -> CGFloat {
            CGFloat(CSSTiming.easeOut(max(0, elapsed) / reorderDuration))
        }

        static func hoverAlpha(elapsed: CFTimeInterval) -> CGFloat {
            CGFloat(CSSTiming.easeOut(max(0, elapsed) / hoverDuration))
        }

        /// What is left of a displacement `x0`, let go at rest `elapsed`
        /// seconds ago, on a spring of stiffness 300 and damping 24 (mass 1):
        /// underdamped, it overshoots by about 5 % and settles.
        static func springRemaining(_ x0: CGFloat, elapsed: CFTimeInterval) -> CGFloat {
            guard elapsed > 0 else { return x0 }
            guard elapsed < springSettle else { return 0 }
            let omega0 = springStiffness.squareRoot()
            let zeta = springDamping / (2 * omega0)
            let omegaD = omega0 * (1 - zeta * zeta).squareRoot()
            let decay = exp(-zeta * omega0 * elapsed)
            let value = decay * (cos(omegaD * elapsed) + (zeta * omega0 / omegaD) * sin(omegaD * elapsed))
            return x0 * CGFloat(value)
        }
    }
}

extension Tako.TabBarView {
    private typealias Transitions = Tako.TabStripTransitions

    /// Whether this strip takes its changes at once: Reduce Motion, a strip
    /// in a window not shown, or Tako covered where nobody can see it.
    var takesChangesAtOnce: Bool {
        LivingAnimationState.shared.isTimelinePaused || window?.isVisible != true
    }

    /// `resting`, the tabs as they lie once nothing moves, moved by what is
    /// moving now: tabs growing in, closed tabs' room collapsing, the
    /// lifted tab under the pointer, its neighbours making room, a dropped
    /// tab springing home.
    func applyTransitions(to resting: [Tab], gap: CGFloat) -> [Tab] {
        restingTabs = resting
        guard let motion = group?.transitions else { return resting }
        let now = Transitions.clock()
        let still = takesChangesAtOnce
        for tab in resting { motion.restingFrames[ObjectIdentifier(tab.window)] = tab.frame }

        var out: [Tab] = []
        out.reserveCapacity(resting.count)
        let room = motion.closingRoom(now: now, still: still)
        var x = resting.first?.frame.minX ?? 0
        for (i, tab) in resting.enumerated() {
            for closed in room where closed.index == i { x += closed.width + gap * closed.left }
            let factor = motion.widthFactor(for: tab.window, now: now, still: still)
            var moved = tab
            moved.frame.origin.x = x
            moved.frame.size.width = tab.frame.width * factor
            moved.showsContent = factor >= 1
            out.append(moved)
            x += moved.frame.width + gap * factor
        }

        let liftedId = isTabDragging ? draggingWindow.map(ObjectIdentifier.init) : nil
        if !still, let reorder = reorderFrom, now - reorder.at < Transitions.reorderDuration {
            let k = Transitions.reorderProgress(elapsed: now - reorder.at)
            for i in out.indices {
                let id = ObjectIdentifier(out[i].window)
                guard id != liftedId, let from = reorder.frames[id] else { continue }
                out[i].frame.origin.x = from.minX + (out[i].frame.minX - from.minX) * k
            }
        }
        if let liftedId, let pointer = dragPointX, let i = out.firstIndex(where: { ObjectIdentifier($0.window) == liftedId }) {
            let width = out[i].frame.width
            out[i].frame.origin.x = min(max(pointer - dragGrabOffset, stripRect.minX), max(stripRect.minX, stripRect.maxX - width))
        }
        if !still, let drop, now - drop.at < Transitions.springSettle,
           let i = out.firstIndex(where: { ObjectIdentifier($0.window) == drop.id }) {
            out[i].frame.origin.x += Transitions.springRemaining(drop.fromX - out[i].frame.minX, elapsed: now - drop.at)
        }

        if let active = resting.first(where: \.isActive) {
            activeBarFrame = motion.barFrame(to: active.frame, now: now, still: still)
        } else {
            activeBarFrame = nil
        }
        if !still && stripMoves(now: now) { runMotion() }
        return out
    }

    /// Whether the strip's own tabs or bar are still moving at `now`.
    func stripMoves(now: CFTimeInterval) -> Bool {
        if group?.transitions.isMoving(now: now) == true { return true }
        if let reorder = reorderFrom, now - reorder.at < Transitions.reorderDuration { return true }
        if let drop, now - drop.at < Transitions.springSettle { return true }
        if buttonHoverSince.values.contains(where: { now - $0 < Transitions.hoverDuration }) { return true }
        return isTabDragging && dragPointX != nil
    }

    /// The classic strip's Ember bar under the active tab, where it is on its
    /// way to it. Pill tabs have none: the pill marks the open tab (94d3f5eb).
    func drawActiveBar(in ctx: CGContext) {
        guard effectiveTabStyle != .pill, let bar = activeBarFrame else { return }
        ctx.setFillColor(Tako.Brand.ember.cgColor)
        ctx.fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width, height: Metrics.activeBarHeight))
    }

    /// The tilt of a tab lifted by a drag, in degrees; 0 for the others.
    func liftTilt(for tab: Tab) -> CGFloat {
        isTabDragging && tab.window === draggingWindow ? Transitions.liftTiltDegrees : 0
    }

    /// The lifted tab: raised by its shadow and tilted, over the others.
    func drawLifted(_ tab: Tab, in ctx: CGContext) {
        let pill = effectiveTabStyle == .pill ? pillRect(for: tab) : tab.frame
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -Transitions.liftShadowOffset), blur: Transitions.liftShadowBlur,
                      color: NSColor.black.withAlphaComponent(Transitions.liftShadowAlpha).cgColor)
        ctx.translateBy(x: pill.midX, y: pill.midY)
        // CSS turns -3° anticlockwise on screen; Core Graphics, y up, turns
        // anticlockwise for a positive angle.
        ctx.rotate(by: -Transitions.liftTiltDegrees * .pi / 180)
        ctx.translateBy(x: -pill.midX, y: -pill.midY)
        drawTab(tab, in: ctx)
        ctx.restoreGState()
    }

    /// A bar button's hover fill: it comes in over 80 ms and goes at once.
    func buttonHoverAlpha(_ key: String, hovered: Bool) -> CGFloat {
        let now = Transitions.clock()
        defer { buttonWasHovered[key] = hovered }
        guard hovered else {
            buttonHoverSince[key] = nil
            return 0
        }
        if buttonWasHovered[key] != true {
            buttonHoverSince[key] = now
            if !takesChangesAtOnce { runMotion() }
        }
        guard !takesChangesAtOnce, let since = buttonHoverSince[key] else { return 1 }
        return Transitions.hoverAlpha(elapsed: now - since)
    }
}

extension Tako {
    /// Terminal UI: the bar's tooltips show after 800 ms.
    static let tooltipDelayMilliseconds = 800

    /// Registers the tooltip delay for this process, before any tooltip shows.
    static func registerTooltipDelay(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: ["NSInitialToolTipDelay": tooltipDelayMilliseconds])
    }
}
