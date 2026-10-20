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

/// A surface Core Animation draws, rendered at chosen moments: one state,
/// entered from another or shown first, with room round it for its glow.
@MainActor
final class StatusScene {
    let harness: MotionSurfaceHarness
    let layer: Tako.TabStatusLayer
    let size: CGSize
    let padding: CGFloat = 12
    private let frames = LayerFrames()

    init(_ surface: MotionSpec.Surface, _ state: Tako.SurfaceState, from: Tako.SurfaceState? = nil,
         reduceMotion: Bool = false, pulses: Int? = nil, paused: Bool = false) throws {
        harness = MotionSurfaceHarness(surface, reduceMotion: reduceMotion)
        if let from { harness.show(from, pulses: pulses.map { $0 - 1 }) }
        harness.show(state, pulses: pulses)
        layer = try #require(harness.layer, "\(surface) draws no layer in \(state.specName)")
        if paused {
            layer.apply(state: state, in: layer.frame, hideRing: false, reduceMotion: reduceMotion, paused: true)
        }
        size = layer.bounds.size
        LayerFrames.restartAnimations(in: layer)
    }

    /// The frame `t` seconds into the state.
    func at(_ t: CFTimeInterval) -> LayerFrame { frames.render(layer, size: size, padding: padding, at: t) }

    /// The surface's rectangle in the frame's points.
    var rect: CGRect { CGRect(x: padding, y: padding, width: size.width, height: size.height) }
    /// The ring's centre in the frame's points.
    var ringCentre: CGPoint {
        CGPoint(x: layer.ringContainer.position.x + padding, y: layer.ringContainer.position.y + padding)
    }
    var cornerRadius: CGFloat { layer.geometry.cornerRadius }

    /// Points along the border, `inset` in from the edge, away from the corners and the ring.
    func borderPoints(inset: CGFloat = 0.5, step: CGFloat = 0.5) -> [CGPoint] {
        let r = rect.insetBy(dx: inset, dy: inset)
        let c = cornerRadius + 1
        var out: [CGPoint] = []
        var x = r.minX + c
        while x < r.maxX - c { out.append(CGPoint(x: x, y: r.maxY)); out.append(CGPoint(x: x, y: r.minY)); x += step }
        var y = r.minY + c
        while y < r.maxY - c { out.append(CGPoint(x: r.minX, y: y)); out.append(CGPoint(x: r.maxX, y: y)); y += step }
        return out.filter { hypot($0.x - ringCentre.x, $0.y - ringCentre.y) > 9 }
    }

    /// Whether `p` is on the border band and clear of the ring.
    func onBorder(_ p: CGPoint, band: CGFloat = 1.6) -> Bool {
        guard hypot(p.x - ringCentre.x, p.y - ringCentre.y) > 9 else { return false }
        let r = rect
        guard r.insetBy(dx: -0.5, dy: -0.5).contains(p) else { return false }
        return p.x - r.minX < band || r.maxX - p.x < band || p.y - r.minY < band || r.maxY - p.y < band
    }

    /// Points round the ring at `radius` from its centre.
    func ringCircle(radius: CGFloat = 6.25, count: Int = 72) -> [CGPoint] {
        (0..<count).map { i in
            let a = Double(i) / Double(count) * 2 * .pi
            return CGPoint(x: ringCentre.x + radius * cos(a), y: ringCentre.y + radius * sin(a))
        }
    }

    var ringArea: CGRect { CGRect(x: ringCentre.x - 12, y: ringCentre.y - 12, width: 24, height: 24) }
}

/// What each state looks like and how it moves on the layer-drawn surfaces,
/// read off rendered frames: colours, places, directions, periods.
@Suite(.serialized) @MainActor
struct MotionLayerPixelTests {
    static let both: [MotionSpec.Surface] = [.pill, .row]
    /// Warm light over the faint working track.
    private static let strongWarm: PixelWeight = { r, g, b in max(0, Weights.warm(r, g, b) - 0.2) }

    // MARK: Idle

    @Test(arguments: both)
    func anIdleRingIsTheIdleColourAndNothingElseShows(_ surface: MotionSpec.Surface) throws {
        let scene = try StatusScene(surface, .idle)
        let frame = scene.at(0.5)
        #expect(frame.litShare(along: scene.ringCircle(), over: 0.5, Weights.near(MotionSpec.ringIdle)) > 0.9)
        let elsewhere = frame.mass(where: { !scene.ringArea.contains($0) }, Weights.light)
        #expect(elsewhere < 0.5, "light outside the ring \(elsewhere)")
    }

    // MARK: Working

    @Test(arguments: both)
    func theSpinnerTurnsClockwiseOnceIn900ms(_ surface: MotionSpec.Surface) throws {
        let scene = try StatusScene(surface, .working)
        let centre = scene.ringCentre
        func angle(_ t: Double) throws -> Double {
            try #require(scene.at(t).angle(around: centre, in: scene.ringArea, where: { hypot($0.x - centre.x, $0.y - centre.y) < 7.6 },
                                           Self.strongWarm), "no spinner at \(t)")
        }
        let a0 = try angle(0.05)
        let quarter = MotionSpec.spinnerTurn / 4
        for k in 1...3 {
            let d = MotionAngles.delta(a0, try angle(0.05 + quarter * Double(k)))
            let want = MotionAngles.delta(0, -90 * Double(k))
            #expect(abs(MotionAngles.delta(want, d)) < 15, "after \(k) quarter(s) it turned \(d)°, not \(want)°")
        }
        #expect(abs(MotionAngles.delta(a0, try angle(0.05 + MotionSpec.spinnerTurn))) < 6, "not back after a turn")
    }

    @Test(arguments: both)
    func theCometRunsClockwiseRoundTheBorderOnceIn2200ms(_ surface: MotionSpec.Surface) throws {
        let scene = try StatusScene(surface, .working)
        let centre = CGPoint(x: scene.rect.midX, y: scene.rect.midY)
        func angle(_ t: Double) throws -> Double {
            try #require(scene.at(t).angle(around: centre, where: { scene.onBorder($0) }, Self.strongWarm), "no comet at \(t)")
        }
        let steps = 8
        var previous = try angle(0.05)
        let first = previous
        var travelled = 0.0
        for k in 1...steps {
            let now = try angle(0.05 + MotionSpec.cometTurn * Double(k) / Double(steps))
            let d = MotionAngles.delta(previous, now)
            #expect(d < -5 && d > -110, "step \(k) went \(d)°: not clockwise, or too far")
            travelled += d
            previous = now
        }
        #expect(abs(travelled + 360) < 25, "a turn of \(travelled)° in \(MotionSpec.cometTurn) s")
        #expect(abs(MotionAngles.delta(first, previous)) < 8)
    }

    @Test(arguments: both)
    func underReduceMotionWorkingIsAStillEmberBorderAllRound(_ surface: MotionSpec.Surface) throws {
        let scene = try StatusScene(surface, .working, reduceMotion: true)
        let a = scene.at(0.1), b = scene.at(1.3)
        let border = scene.borderPoints()
        #expect(a.litShare(along: border, over: 0.15, Weights.warm) > 0.95, "border not all round")
        #expect(abs(a.mass(where: { scene.onBorder($0) }, Weights.warm) - b.mass(where: { scene.onBorder($0) }, Weights.warm)) < 0.5,
                "the border moved")
        let centre = scene.ringCentre
        let spinA = a.angle(around: centre, in: scene.ringArea, where: { hypot($0.x - centre.x, $0.y - centre.y) < 7.6 }, Self.strongWarm)
        let spinB = b.angle(around: centre, in: scene.ringArea, where: { hypot($0.x - centre.x, $0.y - centre.y) < 7.6 }, Self.strongWarm)
        #expect(abs(MotionAngles.delta(spinA ?? 0, spinB ?? 0)) < 3, "the spinner turned")
    }

    @Test func aRowInProgressRunsTheCometAndAPillDoesNot() throws {
        for (surface, comet) in [(MotionSpec.Surface.row, true), (.pill, false)] {
            let scene = try StatusScene(surface, .progress(0.4))
            let mass = scene.at(0.3).mass(where: { scene.onBorder($0) && $0.y > scene.rect.minY + 3 }, Self.strongWarm)
            #expect((mass > 2) == comet, "\(surface): border light \(mass)")
        }
    }

    // MARK: Progress

    @Test(arguments: both)
    func theProgressArcCoversItsShareClockwiseFromTheTop(_ surface: MotionSpec.Surface) throws {
        let scene = try StatusScene(surface, .progress(0.4))
        let frame = scene.at(0.2)
        let circle = scene.ringCircle(radius: 5.75, count: 180)
        let share = frame.litShare(along: circle, over: 0.3, Weights.warm)
        #expect(abs(share - 0.4) < 0.07, "arc covers \(share)")
        let c = scene.ringCentre
        let justClockwise = CGPoint(x: c.x + 5.75 * cos(80 * .pi / 180), y: c.y + 5.75 * sin(80 * .pi / 180))
        let justAnticlockwise = CGPoint(x: c.x + 5.75 * cos(100 * .pi / 180), y: c.y + 5.75 * sin(100 * .pi / 180))
        let lit = { (p: CGPoint) -> CGFloat in let s = frame.sample(p); return Weights.warm(s.r, s.g, s.b) }
        #expect(lit(justClockwise) > 0.3, "the arc does not start at the top going clockwise")
        #expect(lit(justAnticlockwise) < 0.15, "the arc runs anticlockwise from the top")
        #expect(frame.litShare(along: circle, over: 0.4, Weights.near(MotionSpec.progressTrack)) > 0.45, "no track for the rest")
        MotionOverviewCardTests.expectArcRunsRustToEmber(frame, centre: c, radius: 5.75, share: 0.4)
    }

    @Test(arguments: both)
    func theProgressLineRunsRustToEmberAcrossItsShare(_ surface: MotionSpec.Surface) throws {
        let scene = try StatusScene(surface, .progress(0.4))
        let frame = scene.at(0.2)
        let lineY = scene.rect.minY + (surface == .row ? 2 : 1)
        let lit = stride(from: scene.rect.minX, to: scene.rect.maxX, by: 0.5)
            .map { CGPoint(x: $0, y: lineY) }
            .filter { let s = frame.sample($0); return Weights.warm(s.r, s.g, s.b) > 0.2 }
        let first = try #require(lit.first), last = try #require(lit.last)
        let inset = surface == .row ? first.x - scene.rect.minX : 0
        // 4a: a row's progress line starts 8 pt in (`.pfill` left: 8px).
        #expect(surface == .pill || (7...10).contains(inset), "the row's line starts \(inset) pt in")
        let span = scene.size.width - 2 * inset
        // A pill's corner hides the first couple of points of a line that starts at its edge.
        #expect(abs((last.x - first.x) - span * 0.4) < 4, "line \(last.x - first.x) of \(span)")
        let left = frame.sample(CGPoint(x: first.x + 1, y: lineY)), right = frame.sample(CGPoint(x: last.x - 1, y: lineY))
        #expect(right.r > left.r + 0.05, "Rust \(left) to Ember \(right)")
    }

    // MARK: Waiting

    @Test(arguments: both)
    func theWaitingBorderBreathesFromFortyToNinetyFivePercent(_ surface: MotionSpec.Surface) throws {
        let scene = try StatusScene(surface, .waiting)
        let border = { (t: Double) in scene.at(t).mass(where: { scene.onBorder($0, band: 1) }, Weights.warm) }
        let low = border(0), high = border(MotionSpec.breatheHalf), back = border(2 * MotionSpec.breatheHalf)
        let ratio = high / max(low, 0.001)
        #expect(ratio > 1.8 && ratio < 3.2, "breath \(low) -> \(high), ratio \(ratio), not .95/.40")
        #expect(abs(back - low) < low * 0.15, "not back after a breath: \(low) vs \(back)")
    }

    @Test(arguments: both)
    func theWaitingGlowSpreadsOutsideTheBorderAtTheBreathsPeak(_ surface: MotionSpec.Surface) throws {
        let scene = try StatusScene(surface, .waiting)
        let outside = { (p: CGPoint) in !scene.rect.insetBy(dx: -0.5, dy: -0.5).contains(p) }
        let low = scene.at(0).mass(where: outside, Weights.warm)
        let peak = scene.at(MotionSpec.breatheHalf).mass(where: outside, Weights.warm)
        #expect(peak > 3, "no glow outside at the peak: \(peak)")
        #expect(low < peak * 0.15, "glow at rest \(low) vs peak \(peak)")
    }

    @Test(arguments: both)
    func theHaloGrowsAndFadesEvery1600ms(_ surface: MotionSpec.Surface) throws {
        let scene = try StatusScene(surface, .waiting)
        let c = scene.ringCentre
        let reach = { (t: Double) in scene.at(t).reach(from: c, within: 10.5, over: 0.12, Weights.warm) }
        #expect(reach(0.5) > 8.5, "the halo has not grown at 0.5 s: \(reach(0.5))")
        #expect(reach(1.55) < 7.6, "the halo has not faded at 1.55 s: \(reach(1.55))")
        #expect(reach(1.6 + 0.5) > 8.5, "the halo does not come round again")
    }

    @Test(arguments: both)
    func theDotBlinksToAQuarter(_ surface: MotionSpec.Surface) throws {
        let scene = try StatusScene(surface, .waiting)
        let c = scene.ringCentre
        let dot = CGRect(x: c.x - 1.6, y: c.y - 1.6, width: 3.2, height: 3.2)
        let on = scene.at(0).mass(in: dot, Weights.warm), off = scene.at(MotionSpec.blinkHalf).mass(in: dot, Weights.warm)
        let ratio = off / max(on, 0.001)
        #expect(ratio > 0.15 && ratio < 0.4, "dot \(on) -> \(off), ratio \(ratio), not .25")
    }

    @Test(arguments: both)
    func underReduceMotionWaitingStandsStillWithAFaintGlow(_ surface: MotionSpec.Surface) throws {
        let scene = try StatusScene(surface, .waiting, reduceMotion: true)
        let a = scene.at(0), b = scene.at(MotionSpec.breatheHalf)
        let c = scene.ringCentre
        #expect(b.reach(from: c, within: 10.5, over: 0.12, Weights.warm) < 7.6, "a halo with motion reduced")
        let dot = CGRect(x: c.x - 1.6, y: c.y - 1.6, width: 3.2, height: 3.2)
        #expect(abs(a.mass(in: dot, Weights.warm) - b.mass(in: dot, Weights.warm)) < 0.05, "the dot blinks")
        let border = { (f: LayerFrame) in f.mass(where: { scene.onBorder($0, band: 1) }, Weights.warm) }
        #expect(abs(border(a) - border(b)) < 0.3, "the border breathes")
        let outside = { (p: CGPoint) in !scene.rect.insetBy(dx: -0.5, dy: -0.5).contains(p) }
        #expect(a.mass(where: outside, Weights.warm) > 0.5, "no glow at all")
    }

    // MARK: Done

    private func discArea(_ frame: LayerFrame, _ scene: StatusScene) -> CGFloat {
        frame.mass(in: scene.ringArea, Weights.near(MotionSpec.ok))
    }

    @Test(arguments: both)
    func aDoneRingPopsSmallThenBigThenSettles(_ surface: MotionSpec.Surface) throws {
        let scene = try StatusScene(surface, .done, from: .working)
        let rest = discArea(scene.at(2), scene)
        let small = discArea(scene.at(MotionSpec.popDuration * MotionSpec.popKeyTimes[1]), scene) / rest
        let big = discArea(scene.at(MotionSpec.popDuration * MotionSpec.popKeyTimes[2]), scene) / rest
        let settled = discArea(scene.at(MotionSpec.popDuration + 0.05), scene) / rest
        #expect(abs(small - 0.55 * 0.55) < 0.1, "at its smallest the disc is \(small) of its area, not .55²")
        #expect(abs(big - 1.25 * 1.25) < 0.25, "at its biggest the disc is \(big) of its area, not 1.25²")
        #expect(abs(settled - 1) < 0.06, "settled at \(settled)")
    }

    @Test(arguments: both)
    func theGlintCrossesLeftToRightOnceAndIsGone(_ surface: MotionSpec.Surface) throws {
        let scene = try StatusScene(surface, .done, from: .working)
        let away = { (p: CGPoint) in !scene.ringArea.contains(p) && scene.rect.contains(p) }
        // Ease-out: most of the way early. Every frame the band shows in
        // shows it right of the last. (The repeating tiles CSS has put a
        // faint sliver of the next band at the left edge late in the run;
        // a band is a frame with a quarter of the peak's green or more.)
        let samples = stride(from: 0.0, through: MotionSpec.glintDuration, by: 0.04).map { t -> (m: CGFloat, x: CGFloat?) in
            let frame = scene.at(t)
            return (frame.mass(where: away, Weights.green), frame.centroid(where: away, Weights.green)?.x)
        }
        let peak = samples.map(\.m).max() ?? 0
        let xs = samples.filter { $0.m > peak / 4 }.compactMap(\.x)
        #expect(xs.count >= 4, "the band showed in \(xs.count) frames")
        #expect(zip(xs, xs.dropFirst()).allSatisfy { $0 < $1 }, "the band went \(xs)")
        #expect((xs.first ?? .infinity) < scene.rect.midX && (xs.last ?? 0) > scene.rect.midX, "it did not cross: \(xs)")
        // Done, the animation is taken off and the layer is where no band shows.
        let glint = try #require(scene.layer.named(Tako.TabStatusLayer.LayerName.doneGlint))
        glint.removeAllAnimations()
        let after = scene.at(MotionSpec.glintDuration + 0.1).mass(where: away, Weights.green)
        #expect(after < peak / 50, "the glint is still there after it ran: \(after) of \(peak)")
    }

    @Test(arguments: both)
    func aSurfaceFirstSeenDoneNeitherPopsNorGlints(_ surface: MotionSpec.Surface) throws {
        let scene = try StatusScene(surface, .done)
        let rest = discArea(scene.at(2), scene)
        #expect(abs(discArea(scene.at(0.19), scene) / rest - 1) < 0.05)
        let away = { (p: CGPoint) in !scene.ringArea.contains(p) && scene.rect.contains(p) }
        #expect(scene.at(0.4).mass(where: away, Weights.green) < 0.2)
    }

    @Test(arguments: both)
    func underReduceMotionDoneOnlyTurnsGreen(_ surface: MotionSpec.Surface) throws {
        let scene = try StatusScene(surface, .done, from: .working, reduceMotion: true)
        let rest = discArea(scene.at(2), scene)
        #expect(rest > 100, "no green disc: \(rest)")
        #expect(abs(discArea(scene.at(0.19), scene) / rest - 1) < 0.05, "it popped")
        let away = { (p: CGPoint) in !scene.ringArea.contains(p) && scene.rect.contains(p) }
        #expect(scene.at(0.4).mass(where: away, Weights.green) < 0.2, "it glinted")
    }

    // MARK: Failed

    @Test(arguments: both)
    func aFailedSurfaceHasARedDiscAndARedBaseline(_ surface: MotionSpec.Surface) throws {
        let scene = try StatusScene(surface, .failed, from: .working)
        let frame = scene.at(1)
        #expect(frame.mass(in: scene.ringArea, Weights.near(MotionSpec.error)) > 80, "no red disc")
        let r = scene.cornerRadius + 1
        let along = { (y: CGFloat) in
            stride(from: scene.rect.minX + r, to: scene.rect.maxX - r, by: 0.5).map { CGPoint(x: $0, y: y) }
                .filter { !scene.ringArea.contains($0) }
        }
        #expect(frame.litShare(along: along(scene.rect.minY + 1), over: 0.5, Weights.near(MotionSpec.error)) > 0.95, "no baseline")
        #expect(frame.litShare(along: along(scene.rect.minY + 3.5), over: 0.2, Weights.warm) < 0.02, "the line is thicker than 2 pt")
    }

    // MARK: Offline

    @Test(arguments: both)
    func anOfflineSurfaceHasADashedBorderAndADashedRing(_ surface: MotionSpec.Surface) throws {
        let scene = try StatusScene(surface, .offline)
        let frame = scene.at(0.5)
        let r = scene.cornerRadius + 2
        let top = stride(from: scene.rect.minX + r, to: scene.rect.maxX - r, by: 0.5).map { CGPoint(x: $0, y: scene.rect.maxY - 0.5) }
            .filter { !scene.ringArea.contains($0) }
        let lit = top.map { let s = frame.sample($0); return Weights.light(s.r, s.g, s.b) > 0.1 }
        let share = Double(lit.filter { $0 }.count) / Double(lit.count)
        #expect(share > 0.3 && share < 0.7, "dashes cover \(share) of the top edge")
        let switches = zip(lit, lit.dropFirst()).filter { $0 != $1 }.count
        let expected = Double(top.count) * 0.5 / 3   // a change every 3 pt
        #expect(abs(Double(switches) - expected) < expected * 0.35, "\(switches) dash edges, ~\(expected) for 3 pt dashes")
        let ring = frame.litShare(along: scene.ringCircle(), over: 0.1, Weights.light)
        #expect(ring > 0.3 && ring < 0.75, "the ring is not dashed: \(ring)")
    }

    // MARK: Live

    @Test(arguments: both)
    func aQuietLiveRingIsEmberAtFortyFivePercentOfAFlowingOne(_ surface: MotionSpec.Surface) throws {
        let flowing = try StatusScene(surface, .live(flowing: true))
        let quiet = try StatusScene(surface, .live(flowing: false))
        let a = flowing.at(0.5).mass(in: flowing.ringArea, Weights.warm)
        let b = quiet.at(0.5).mass(in: quiet.ringArea, Weights.warm)
        #expect(abs(b / a - MotionSpec.liveQuietAlpha) < 0.1, "quiet/flowing \(b / a)")
        #expect(flowing.at(0.5).mass(where: { !flowing.ringArea.contains($0) }, Weights.light) < 0.5, "a live surface has no border or glow")
    }

    @Test(arguments: both)
    func aBurstRipplesTheLiveRingOutAndAway(_ surface: MotionSpec.Surface) throws {
        let scene = try StatusScene(surface, .live(flowing: true), from: .live(flowing: true), pulses: 1)
        let c = scene.ringCentre
        let early = scene.at(0.1).reach(from: c, within: 10.5, over: 0.1, Weights.warm)
        let late = scene.at(MotionSpec.rippleDuration + 0.05).reach(from: c, within: 10.5, over: 0.1, Weights.warm)
        #expect(early > 7.8, "no ripple out at 0.1 s: \(early)")
        #expect(late < 7.4, "the ripple is still there after 0.35 s: \(late)")
    }

    // MARK: Paused

    @Test func aPausedPillShowsTheSameFrameWhateverTheClock() throws {
        let scene = try StatusScene(.pill, .working, paused: true)
        let c = scene.ringCentre
        let spin = { (t: Double) in
            scene.at(t).angle(around: c, in: scene.ringArea, where: { hypot($0.x - c.x, $0.y - c.y) < 7.6 }, Self.strongWarm) ?? .nan
        }
        #expect(abs(MotionAngles.delta(spin(0.05), spin(0.5))) < 3, "a paused spinner turned")
    }
}
