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
import Testing
@testable import Tako

/// The crab of a classic tab against the Terminal UI design's «Краб во
/// вкладке: 7 состояний»: each state's colours and figure from the SVGs, and
/// its motion from the CSS keyframes -- read off the Core Animation the
/// layer runs, and off its pixels. The crab drew still before: one colour,
/// no scurry, hop, shiver or pulse, and the ghost grey.
@Suite(.serialized) @MainActor
struct MotionCrabTests {
    static let slot = CGRect(x: 0, y: 0, width: 16, height: 16)
    private let easeInOut = CSSTiming.cubicBezier(0.42, 0, 0.58, 1)

    private func crab(_ state: Tako.CrabState, after previous: Tako.CrabState? = nil,
                      reduceMotion: Bool = false, paused: Bool = false) -> Tako.CrabLayer {
        let crab = Tako.CrabLayer()
        if let previous {
            crab.apply(state: previous, in: Self.slot, unread: false, reduceMotion: reduceMotion, paused: paused, scale: 2)
        }
        crab.apply(state: state, in: Self.slot, unread: false, reduceMotion: reduceMotion, paused: paused, scale: 2)
        return crab
    }

    private func hex(_ color: CGColor?) -> Int {
        guard let color, let c = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return -1 }
        return [c.redComponent, c.greenComponent, c.blueComponent].reduce(0) { $0 << 8 | Int(($1 * 255).rounded()) }
    }

    /// The squares of a path, as cells of the crab's grid: column 0 is the
    /// leftmost square there is, row 0 the topmost -- the claws hold both.
    private func cells(_ paths: [CGPath]) -> [[MotionSpec.CrabCell]] {
        let origins = paths.map { path -> [CGPoint] in
            var points: [CGPoint] = []
            path.applyWithBlock { element in
                if element.pointee.type == .moveToPoint { points.append(element.pointee.points[0]) }
            }
            return points
        }
        let all = origins.flatMap { $0 }
        guard let left = all.map(\.x).min(), let top = all.map(\.y).max() else { return paths.map { _ in [] } }
        let xs = Set(all.map(\.x)).sorted()
        let step = zip(xs, xs.dropFirst()).map { $1 - $0 }.min() ?? 1
        return origins.map { points in
            points.map { MotionSpec.CrabCell(column: Int((($0.x - left) / step).rounded()), row: Int(((top - $0.y) / step).rounded())) }
        }
    }

    private func keyframes(_ stops: [(at: Double, value: Double)], at fraction: Double) -> Double {
        for (a, b) in zip(stops, stops.dropFirst()) where fraction <= b.at {
            let k = easeInOut(max(0, (fraction - a.at) / (b.at - a.at)))
            return a.value + (b.value - a.value) * k
        }
        return stops.last?.value ?? 0
    }

    private func number(_ layer: CALayer, _ keyPath: String) -> Double {
        (layer.value(forKeyPath: keyPath) as? NSNumber)?.doubleValue ?? .nan
    }

    // MARK: - How each state looks

    @Test(arguments: MotionSpec.crabStates)
    func eachStateHasTheDesignsColoursFigureAndOpacity(_ state: Tako.CrabState) {
        let crab = crab(state)
        let colors = MotionSpec.crabColors(state)
        #expect(hex(crab.claws.fillColor) == colors.claws, "claws of \(state)")
        #expect(hex(crab.body.fillColor) == colors.body, "body of \(state)")
        #expect(abs(crab.glyph.opacity - (state == .ghost ? MotionSpec.crabGhostOpacity : 1)) < 0.001)

        let drawn = cells([crab.claws.path!, crab.body.path!])
        let ghost = state == .ghost
        #expect(Set(drawn[0]) == Set(MotionSpec.crabClawRects.map(MotionSpec.crabCell)), "claws of \(state)")
        #expect(Set(drawn[1]) == Set((ghost ? MotionSpec.ghostBodyRects : MotionSpec.crabBodyRects).map(MotionSpec.crabCell)),
                "body of \(state)")
        let eyes = Set((ghost ? MotionSpec.ghostEyeRects : MotionSpec.crabEyeRects).map(MotionSpec.crabCell))
        #expect(eyes.isDisjoint(with: drawn.flatMap { $0 }), "the eyes are holes")
    }

    @Test func theCrabIsDrawnInItsColoursWithItsEyesOpen() throws {
        let frames = LayerFrames()
        let crab = crab(.idle)
        let frame = frames.render(crab, size: Self.slot.size, at: 0)
        let cells = cells([crab.claws.path!, crab.body.path!])
        let box = crab.claws.path!.boundingBoxOfPath.union(crab.body.path!.boundingBoxOfPath)
        let step = box.width / 10
        func centre(_ cell: MotionSpec.CrabCell) -> CGPoint {
            CGPoint(x: box.minX + (CGFloat(cell.column) + 0.5) * step, y: box.maxY - (CGFloat(cell.row) + 0.5) * step)
        }
        let claw = frame.color(atPoint: centre(try #require(cells[0].first)))
        let body = frame.color(atPoint: centre(MotionSpec.crabCell((49, 54))))
        let eye = frame.color(atPoint: centre(MotionSpec.crabCell(MotionSpec.crabEyeRects[0])))
        #expect(abs(claw.g - CGFloat((MotionSpec.claw >> 8) & 0xFF) / 255) < 0.06, "claw \(claw)")
        #expect(abs(body.g - CGFloat((MotionSpec.ember >> 8) & 0xFF) / 255) < 0.06, "body \(body)")
        #expect(eye.r < 0.05 && eye.g < 0.05, "an eye shows what is behind: \(eye)")

        let ghost = frames.render(self.crab(.ghost), size: Self.slot.size, at: 0)
        let faded = ghost.color(atPoint: centre(MotionSpec.crabCell((49, 76))))
        #expect(abs(faded.r - 0xF4 / 255 * 0.45) < 0.06, "a ghost is the crab at 45 %: \(faded)")
    }

    // MARK: - How it moves

    @Test func aRunningCrabScurriesThroughFourPosesEach200ms() throws {
        let scuttle = try #require(crab(.running).glyph.animation(forKey: Tako.CrabLayer.Key.scuttle))
        #expect(scuttle.repeatCount == .infinity)
        let times = stride(from: 0.0, to: 1.6, by: 0.2).flatMap { [$0 + 0.03, $0 + 0.17] }
        for (t, p) in zip(times, AnimationClock().sample(scuttle, at: times)) {
            let pose = MotionSpec.crabScuttlePoses[Int((t.truncatingRemainder(dividingBy: MotionSpec.crabScuttleCycle)) / 0.2)]
            #expect(abs(p.transform.m41 - pose.dx) < 0.01, "x at \(t): \(p.transform.m41)")
            // CSS turns clockwise for a positive angle; a layer, y up, the other way.
            let angle = atan2(p.transform.m12, p.transform.m11) * 180 / .pi
            #expect(abs(angle + pose.clockwiseDegrees) < 0.1, "turn at \(t): \(angle)")
        }
    }

    @Test(arguments: [(Tako.CrabState.succeeded, MotionSpec.crabHopSuccess), (.attention, MotionSpec.crabHopBell)])
    func aCrabHopsOnceWhenACommandSucceedsOrTheBellRings(_ state: Tako.CrabState, _ duration: CFTimeInterval) throws {
        let hop = try #require(crab(state, after: .running).glyph.animation(forKey: Tako.CrabLayer.Key.hop))
        #expect(abs(hop.duration - duration) < 0.001)
        #expect(hop.repeatCount == 0 && hop.isRemovedOnCompletion, "once")
        let times = stride(from: 0.0, through: duration, by: duration / 40).map { $0 }
        let stops = MotionSpec.crabHopStops.map { (at: $0.at, value: $0.up) }
        for (t, p) in zip(times, AnimationClock().sample(hop, at: times)) {
            #expect(abs(number(p, "transform.translation.y") - keyframes(stops, at: t / duration)) < 0.05, "up at \(t)")
        }
    }

    @Test func aFailedCrabShiversOnceFor400ms() throws {
        let shake = try #require(crab(.failed(code: 2), after: .running).glyph.animation(forKey: Tako.CrabLayer.Key.shake))
        #expect(abs(shake.duration - MotionSpec.crabShakeDuration) < 0.001)
        #expect(shake.repeatCount == 0 && shake.isRemovedOnCompletion, "once")
        let times = stride(from: 0.0, through: 0.4, by: 0.01).map { $0 }
        let stops = MotionSpec.crabShakeStops.map { (at: $0.at, value: $0.dx) }
        for (t, p) in zip(times, AnimationClock().sample(shake, at: times)) {
            #expect(abs(number(p, "transform.translation.x") - keyframes(stops, at: t / 0.4)) < 0.05, "x at \(t)")
        }
    }

    @Test func aReconnectingCrabPulsesTo35PercentEvery1100ms() throws {
        let pulse = try #require(crab(.reconnecting).glyph.animation(forKey: Tako.CrabLayer.Key.pulse))
        #expect(pulse.repeatCount == .infinity)
        let times = stride(from: 0.0, to: 2.4, by: 0.05).map { $0 }
        let stops = MotionSpec.crabPulseStops.map { (at: $0.at, value: $0.opacity) }
        for (t, p) in zip(times, AnimationClock().sample(pulse, at: times)) {
            let phase = t.truncatingRemainder(dividingBy: MotionSpec.crabPulseCycle) / MotionSpec.crabPulseCycle
            #expect(abs(Double(p.opacity) - keyframes(stops, at: phase)) < 0.01, "opacity at \(t)")
        }
    }

    @Test func itsPixelsMoveAsTheKeyframesSay() throws {
        let frames = LayerFrames()
        let running = crab(.running)
        LayerFrames.restartAnimations(in: running)
        let a = try #require(frames.render(running, size: Self.slot.size, padding: 4, at: 0.1).centroid(over: 0.2, LayerFrame.light))
        let c = try #require(frames.render(running, size: Self.slot.size, padding: 4, at: 0.5).centroid(over: 0.2, LayerFrame.light))
        #expect(abs((c.x - a.x) - 5) < 0.6, "from -2 to +3: \(a.x) -> \(c.x)")

        let hopping = crab(.succeeded, after: .running)
        LayerFrames.restartAnimations(in: hopping)
        let rest = try #require(frames.render(hopping, size: Self.slot.size, padding: 6, at: 1.6).centroid(over: 0.2, LayerFrame.light))
        let up = try #require(frames.render(hopping, size: Self.slot.size, padding: 6, at: 0.42).centroid(over: 0.2, LayerFrame.light))
        #expect(abs((up.y - rest.y) - 4) < 0.6, "4 pt up at 30 %: \(rest.y) -> \(up.y)")
    }

    // MARK: - When it moves

    @Test(arguments: [Tako.CrabState.succeeded, .failed(code: 1), .attention])
    func aCrabFirstSeenInAStateDoesNotPlayItsOneOff(_ state: Tako.CrabState) {
        #expect(crab(state).glyph.animationKeys() == nil, "\(state) seen first")
    }

    @Test func anotherFailureWhileFailedDoesNotShiverAgain() {
        let crab = crab(.failed(code: 1), after: .running)
        crab.glyph.removeAllAnimations()
        crab.apply(state: .failed(code: 2), in: Self.slot, unread: false, reduceMotion: false, paused: false, scale: 2)
        #expect(crab.glyph.animationKeys() == nil)
    }

    @Test(arguments: [Tako.CrabState.idle, .ghost])
    func anIdleCrabAndAGhostStandStill(_ state: Tako.CrabState) {
        #expect(crab(state, after: .running).glyph.animationKeys() == nil)
    }

    @Test(arguments: MotionSpec.crabStates)
    func underReduceMotionTheCrabOnlyChangesColour(_ state: Tako.CrabState) {
        let still = crab(state, after: .running, reduceMotion: true)
        let moving = crab(state, after: .running)
        #expect(still.glyph.animationKeys() == nil, "\(state) moved under Reduce Motion")
        #expect(hex(still.claws.fillColor) == hex(moving.claws.fillColor) && hex(still.body.fillColor) == hex(moving.body.fillColor))
    }

    @Test func turningReduceMotionOnStopsTheScurryAndOffStartsIt() {
        let crab = crab(.running)
        crab.apply(state: .running, in: Self.slot, unread: false, reduceMotion: true, paused: false, scale: 2)
        #expect(crab.glyph.animationKeys() == nil)
        crab.apply(state: .running, in: Self.slot, unread: false, reduceMotion: false, paused: false, scale: 2)
        #expect(crab.glyph.animation(forKey: Tako.CrabLayer.Key.scuttle) != nil)
    }

    @Test func aPausedCrabHoldsItsFrameAndGoesOnAfter() {
        let crab = crab(.running, paused: true)
        #expect(crab.speed == 0)
        #expect(crab.glyph.animation(forKey: Tako.CrabLayer.Key.scuttle) != nil)
        crab.apply(state: .running, in: Self.slot, unread: false, reduceMotion: false, paused: false, scale: 2)
        #expect(crab.speed == 1)
    }

    @Test func theUnreadDotStaysPutWhileTheCrabMoves() {
        let crab = crab(.running)
        crab.apply(state: .attention, in: Self.slot, unread: true, reduceMotion: false, paused: false, scale: 2)
        #expect(!crab.unreadDot.isHidden)
        #expect(crab.unreadDot.superlayer === crab, "the dot is not part of what hops")
        #expect(hex(crab.unreadDot.fillColor) == MotionSpec.claw)
    }

    // MARK: - In the classic strip

    @Test func aClassicTabsCrabShowsItsPanesAndComesAndGoesWithTheTab() throws {
        _ = NSApplication.shared
        let surface = Tako.SurfaceView(frame: .zero)
        let window = makeWindow(title: "classic")
        window.contentView = surface
        defer { window.close() }
        let bar = Tako.TabBarView(frame: NSRect(x: 0, y: 0, width: 520, height: 38))
        bar.styleOverride = .classic
        bar.stripRect = bar.bounds
        let tab = Tako.TabBarView.Tab(window: window, frame: CGRect(x: 0, y: 0, width: 160, height: 38), isActive: true, index: 0)
        let slot = CGRect(x: 8, y: 11, width: 16, height: 16)
        bar.updateCrabLayer(for: tab, rect: slot, unread: false)
        let crab = try #require(bar.crabLayers[ObjectIdentifier(window)])
        #expect(crab.superlayer === bar.layer)
        #expect(crab.shownState == .idle && !crab.isHidden)
        #expect(hypot(crab.position.x - slot.midX, crab.position.y - slot.midY) < 0.001 && crab.bounds.size == slot.size)

        surface.crab.setStatus(.working, text: nil)
        bar.updateCrabLayer(for: tab, rect: slot, unread: false)
        #expect(crab.shownState == .running)
        surface.crab.setStatus(.error, text: nil)
        bar.updateCrabLayer(for: tab, rect: slot, unread: false)
        #expect(crab.shownState?.isSameKind(as: .failed(code: nil)) == true)
        if !LivingAnimationState.shared.reduceMotion {
            #expect(crab.glyph.animation(forKey: Tako.CrabLayer.Key.shake) != nil, "the tab failed: it shivers")
        }

        var growing = tab
        growing.showsContent = false
        bar.updateCrabLayer(for: growing, rect: slot, unread: false)
        #expect(crab.isHidden, "a tab still growing in shows its content after")
        bar.stripRect = CGRect(x: 40, y: 0, width: 400, height: 38)
        bar.updateCrabLayer(for: tab, rect: slot, unread: false)
        #expect(crab.isHidden, "a crab outside the strip is not shown")

        bar.syncStatusLayers(visibleTabIds: [])
        #expect(bar.crabLayers.isEmpty && crab.superlayer == nil, "a tab gone takes its crab")
        bar.stripRect = bar.bounds
        bar.updateCrabLayer(for: tab, rect: slot, unread: false)
        bar.styleOverride = .pill
        bar.syncStatusLayers(visibleTabIds: [ObjectIdentifier(window)])
        #expect(bar.crabLayers.isEmpty, "pills have rings, not crabs")
    }

    @Test func aLiftedTabTurnsItsCrabWithIt() {
        let crab = crab(.idle)
        let slot = CGRect(x: 8, y: 11, width: 16, height: 16)
        crab.apply(state: .idle, in: slot, unread: false, reduceMotion: false, paused: false, scale: 2)
        let pivot = CGPoint(x: 80, y: 19)
        crab.setPose(tilt: MotionSpec.liftTilt, about: pivot)
        // CSS -3° turns anticlockwise on screen, as the lifted tab is drawn.
        let angle = atan2(crab.transform.m12, crab.transform.m11) * 180 / .pi
        #expect(abs(angle - 3) < 0.01)
        let before = hypot(slot.midX - pivot.x, slot.midY - pivot.y)
        #expect(abs(hypot(crab.position.x - pivot.x, crab.position.y - pivot.y) - before) < 0.01, "turned about the tab's centre")
        #expect(crab.position.y < slot.midY, "its left end goes down")
        crab.setPose(tilt: 0, about: pivot)
        #expect(hypot(crab.position.x - slot.midX, crab.position.y - slot.midY) < 0.001 && CATransform3DIsIdentity(crab.transform))
    }
}
