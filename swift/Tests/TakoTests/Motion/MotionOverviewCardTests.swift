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
import SwiftUI
import Testing
@testable import Tako

/// An Overview card drawn by SwiftUI at a chosen moment of its state, the
/// way its window draws it, with room round it for its glow.
@MainActor
final class CardScene {
    let item: PaneOverviewItem
    let selected: Bool
    let reduceMotion: Bool
    static let width: CGFloat = 300
    let padding: CGFloat = 24
    let cardHeight: CGFloat

    init(_ state: Tako.SurfaceState, selected: Bool = false, reduceMotion: Bool = false) {
        item = Self.item(state)
        self.selected = selected
        self.reduceMotion = reduceMotion
        let probe = NSHostingView(rootView: PaneOverviewCard(item: item, isSelected: selected).frame(width: Self.width))
        cardHeight = probe.fittingSize.height
    }

    var size: CGSize { CGSize(width: Self.width + 2 * padding, height: cardHeight + 2 * padding) }
    /// The card in the frame's points, y up.
    var rect: CGRect { CGRect(x: padding, y: padding, width: Self.width, height: cardHeight) }
    /// The 18 pt ring: 12 pt in from the card's top left, centred in its 18 pt row.
    var ringCentre: CGPoint { CGPoint(x: rect.minX + 12 + 9, y: rect.maxY - 12 - 9) }
    var ringArea: CGRect { CGRect(x: ringCentre.x - 13, y: ringCentre.y - 13, width: 26, height: 26) }

    /// The card `t` seconds into its state.
    func at(_ t: TimeInterval) -> WindowSnapshot {
        let state = LivingAnimationState.shared
        state.fixedTimeOverride = t
        defer { state.fixedTimeOverride = nil }
        let card = PaneOverviewCard(item: item, isSelected: selected, now: Date(timeIntervalSinceReferenceDate: t),
                                    reduceMotion: reduceMotion)
        let view = ZStack {
            Color.black
            card.frame(width: Self.width, height: cardHeight)
        }
        return WindowSnapshot(view, size: size)
    }

    func onBorder(_ p: CGPoint, band: CGFloat = 1.8) -> Bool {
        guard !ringArea.contains(p), rect.insetBy(dx: -0.5, dy: -0.5).contains(p) else { return false }
        return p.x - rect.minX < band || rect.maxX - p.x < band || p.y - rect.minY < band || rect.maxY - p.y < band
    }

    func outside(_ p: CGPoint) -> Bool { !rect.insetBy(dx: -0.5, dy: -0.5).contains(p) }

    func borderPoints(inset: CGFloat = 0.75) -> [CGPoint] {
        let r = rect.insetBy(dx: inset, dy: inset)
        var out: [CGPoint] = []
        var x = r.minX + 12
        while x < r.maxX - 12 { out.append(CGPoint(x: x, y: r.maxY)); out.append(CGPoint(x: x, y: r.minY)); x += 0.5 }
        var y = r.minY + 12
        while y < r.maxY - 12 { out.append(CGPoint(x: r.minX, y: y)); out.append(CGPoint(x: r.maxX, y: y)); y += 0.5 }
        return out.filter { !ringArea.contains($0) }
    }

    static func item(_ state: Tako.SurfaceState) -> PaneOverviewItem {
        var status: Tako.PaneStatus = .idle
        var progressState: TakoTerminalNSView.ProgressState = .none
        var progressValue: Int?
        var live: Tako.LiveActivity?
        switch state {
        case .idle: break
        case .working: status = .working
        case .progress(let p): status = .working; progressState = .normal; progressValue = Int((p * 100).rounded())
        case .waiting: status = .needsApproval
        case .done: status = .done
        case .failed: status = .error
        case .offline: status = .disconnected
        case .live(let flowing):
            var activity = Tako.LiveActivity(program: "tail")
            activity.isFlowing = flowing
            live = activity
        }
        return PaneOverviewItem(id: UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!, title: "psql",
                                status: status, progressState: progressState, progressValue: progressValue, live: live)
    }
}

/// The Overview's cards (4b), drawn by SwiftUI: each state's look and motion
/// read off frames, held to the same spec the layer-drawn surfaces are.
@Suite(.serialized) @MainActor
struct MotionOverviewCardTests {
    private static let strongWarm: PixelWeight = { r, g, b in max(0, Weights.warm(r, g, b) - 0.2) }

    @Test func aWorkingCardsCometRunsClockwiseRoundItOnceIn2200ms() throws {
        let scene = CardScene(.working)
        let centre = CGPoint(x: scene.rect.midX, y: scene.rect.midY)
        func angle(_ t: Double) throws -> Double {
            try #require(scene.at(t).angle(around: centre, where: { scene.onBorder($0) }, Self.strongWarm), "no comet at \(t)")
        }
        var previous = try angle(0)
        let first = previous
        var travelled = 0.0
        for k in 1...8 {
            let now = try angle(MotionSpec.cometTurn * Double(k) / 8)
            let d = MotionAngles.delta(previous, now)
            #expect(d < -5 && d > -110, "step \(k) went \(d)°")
            travelled += d
            previous = now
        }
        #expect(abs(travelled + 360) < 25, "a turn of \(travelled)°")
        #expect(abs(MotionAngles.delta(first, previous)) < 8)
    }

    @Test func aWorkingCardsSpinnerTurnsClockwiseOnceIn900ms() throws {
        let scene = CardScene(.working)
        let c = scene.ringCentre
        func angle(_ t: Double) throws -> Double {
            try #require(scene.at(t).angle(around: c, in: scene.ringArea, where: { hypot($0.x - c.x, $0.y - c.y) < 9.6 }, Self.strongWarm))
        }
        let a0 = try angle(0)
        for k in 1...3 {
            let d = MotionAngles.delta(a0, try angle(MotionSpec.spinnerTurn * Double(k) / 4))
            #expect(abs(MotionAngles.delta(MotionAngles.delta(0, -90 * Double(k)), d)) < 15, "after \(k) quarter(s): \(d)°")
        }
        #expect(abs(MotionAngles.delta(a0, try angle(MotionSpec.spinnerTurn))) < 6)
    }

    @Test func underReduceMotionAWorkingCardHasAStillEmberBorderAllRound() {
        let scene = CardScene(.working, reduceMotion: true)
        let a = scene.at(0.1), b = scene.at(1.3)
        #expect(a.litShare(along: scene.borderPoints(), over: 0.15, Weights.warm) > 0.95)
        let mass = { (f: WindowSnapshot) in f.mass(where: { scene.onBorder($0) }, Weights.warm) }
        #expect(abs(mass(a) - mass(b)) < 0.5, "the border moved")
    }

    @Test func aWaitingCardsBorderBreathesAndItsGlowSpreads() {
        let scene = CardScene(.waiting)
        let rest = scene.at(0), peak = scene.at(MotionSpec.breatheHalf)
        let border = { (f: WindowSnapshot) in f.mass(where: { scene.onBorder($0, band: 1.2) }, Weights.warm) }
        let ratio = border(peak) / max(border(rest), 0.001)
        #expect(ratio > 1.8 && ratio < 3.2, "breath ratio \(ratio), not .95/.40")
        let glowRest = rest.mass(where: scene.outside, Weights.warm), glowPeak = peak.mass(where: scene.outside, Weights.warm)
        #expect(glowPeak > 5, "no glow at the peak: \(glowPeak)")
        #expect(glowRest < glowPeak * 0.15, "glow at rest \(glowRest) vs peak \(glowPeak)")
    }

    @Test func aSelectedCardHasASolidTwoPointEmberBorder() {
        let scene = CardScene(.idle, selected: true)
        let frame = scene.at(0.3)
        #expect(frame.litShare(along: scene.borderPoints(inset: 0.5), over: 0.5, Weights.near(MotionSpec.ember)) > 0.95)
        #expect(frame.litShare(along: scene.borderPoints(inset: 1.5), over: 0.5, Weights.near(MotionSpec.ember)) > 0.95)
        #expect(frame.litShare(along: scene.borderPoints(inset: 3), over: 0.3, Weights.near(MotionSpec.ember)) < 0.05, "thicker than 2 pt")
    }

    @Test func aSelectedWaitingCardBreathesEmberToClaw() {
        let scene = CardScene(.waiting, selected: true)
        let green = { (f: WindowSnapshot) -> CGFloat in
            let pts = scene.borderPoints(inset: 1)
            return pts.map { f.sample($0).g }.reduce(0, +) / CGFloat(pts.count)
        }
        let ember = NSColor.spec(MotionSpec.ember).greenComponent, claw = NSColor.spec(MotionSpec.claw).greenComponent
        let atRest = green(scene.at(0)), atPeak = green(scene.at(MotionSpec.breatheHalf))
        #expect(abs(atRest - ember) < 0.04, "border at rest \(atRest), Ember \(ember)")
        #expect(abs(atPeak - claw) < 0.04, "border at the peak \(atPeak), Claw \(claw)")
    }

    @Test func aDoneCardPopsItsRingAndGlintsOnce() throws {
        let scene = CardScene(.done)
        let area = { (t: Double) in scene.at(t).mass(in: scene.ringArea, Weights.near(MotionSpec.ok)) }
        let rest = area(2)
        #expect(abs(area(MotionSpec.popDuration * MotionSpec.popKeyTimes[1]) / rest - 0.3025) < 0.1)
        #expect(abs(area(MotionSpec.popDuration * MotionSpec.popKeyTimes[2]) / rest - 1.5625) < 0.25)
        let away = { (p: CGPoint) in scene.rect.contains(p) && !scene.ringArea.contains(p) }
        let samples = stride(from: 0.0, through: MotionSpec.glintDuration, by: 0.06).map { t -> (CGFloat, CGFloat?) in
            let f = scene.at(t)
            return (f.mass(where: away, Weights.green), f.peakColumn(where: away, Weights.green))
        }
        let peak = samples.map(\.0).max() ?? 0
        let xs = samples.filter { $0.0 > peak / 4 }.compactMap(\.1)
        #expect(xs.count >= 3 && zip(xs, xs.dropFirst()).allSatisfy { $0 < $1 }, "the glint went \(xs)")
        #expect(scene.at(MotionSpec.glintDuration + 0.2).mass(where: away, Weights.green) < peak / 20, "the glint stays")
    }

    @Test func aFailedCardHasARedBaselineAndShakesItsRingOnTheDesignsBeats() throws {
        let scene = CardScene(.failed)
        let rest = try #require(scene.at(2).centroid(in: scene.ringArea, Weights.near(MotionSpec.error)))
        let beats: [(t: Double, dx: CGFloat)] = [(0.064, -2), (0.128, 2), (0.192, -2), (0.256, 2), (0.32, -1)]
        for beat in beats {
            let c = try #require(scene.at(beat.t).centroid(in: scene.ringArea, Weights.near(MotionSpec.error)))
            #expect(abs((c.x - rest.x) - beat.dx) < 0.6, "at \(beat.t) s the ring is \(c.x - rest.x) off, not \(beat.dx)")
        }
        let frame = scene.at(2)
        let base = stride(from: scene.rect.minX + 12, to: scene.rect.maxX - 12, by: 0.5).map { CGPoint(x: $0, y: scene.rect.minY + 1) }
        #expect(frame.litShare(along: base, over: 0.5, Weights.near(MotionSpec.error)) > 0.95, "no red baseline")
    }

    @Test func anOfflineCardHasADashedBorder() {
        let scene = CardScene(.offline)
        let frame = scene.at(0.5)
        let top = stride(from: scene.rect.minX + 14, to: scene.rect.maxX - 14, by: 0.5).map { CGPoint(x: $0, y: scene.rect.maxY - 0.5) }
        let lit = top.map { let s = frame.sample($0); return Weights.near(MotionSpec.ghostBorder)(s.r, s.g, s.b) > 0.4 }
        let share = Double(lit.filter { $0 }.count) / Double(lit.count)
        #expect(share > 0.3 && share < 0.7, "dashes cover \(share)")
    }

    @Test func aLiveCardHasNoBorderOrGlowAndItsRingIsDimWhileQuiet() {
        let flowing = CardScene(.live(flowing: true)), quiet = CardScene(.live(flowing: false))
        let f = flowing.at(0.5), q = quiet.at(0.5)
        #expect(f.mass(where: { flowing.onBorder($0) || flowing.outside($0) }, Weights.warmOverCard) < 0.5, "a live card has a border or glow")
        let ratio = q.mass(in: quiet.ringArea, Weights.warmOverCard) / f.mass(in: flowing.ringArea, Weights.warmOverCard)
        #expect(abs(ratio - MotionSpec.liveQuietAlpha) < 0.12, "quiet/flowing \(ratio)")
    }

    @Test func aCardInProgressRunsTheCometAndFillsItsArc() {
        let scene = CardScene(.progress(0.4))
        let frame = scene.at(0.3)
        #expect(frame.mass(where: { scene.onBorder($0) }, Self.strongWarm) > 2, "no comet")
        // The ring is a whole circle, arc and track: its middle is the ring's centre.
        // The track (#3A2E26) is a whole circle, over the card's fill (#241C16).
        let c = frame.boxCentre(in: scene.ringArea, over: 0.18, Weights.light) ?? scene.ringCentre
        let circle = (0..<180).map { i -> CGPoint in
            let a = Double(i) / 180 * 2 * .pi
            return CGPoint(x: c.x + 7.75 * cos(a), y: c.y + 7.75 * sin(a))
        }
        let share = frame.litShare(along: circle, over: 0.25, Weights.warm)
        #expect(abs(share - 0.4) < 0.07, "arc covers \(share) round \(c), the card's ring at \(scene.ringCentre)")
        Self.expectArcRunsRustToEmber(frame, centre: c, radius: 7.75, share: 0.4)
    }

    /// `.r-prog`: conic-gradient(Rust 0%, Ember p%) -- the arc starts Rust at
    /// the top and ends Ember where it stops.
    static func expectArcRunsRustToEmber(_ frame: some MotionFrame, centre c: CGPoint, radius: CGFloat, share: Double,
                                         sourceLocation: SourceLocation = #_sourceLocation) {
        func at(_ degreesClockwiseFromTop: Double) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
            let a = CGFloat((90 - degreesClockwiseFromTop) * .pi / 180)
            return frame.sample(CGPoint(x: c.x + radius * Foundation.cos(a), y: c.y + radius * Foundation.sin(a)))
        }
        let start = at(8), end = at(share * 360 - 8)
        let rust = NSColor.spec(MotionSpec.rust), ember = NSColor.spec(MotionSpec.ember)
        #expect(abs(start.r - rust.redComponent) < 0.08 && abs(start.g - rust.greenComponent) < 0.06,
                "the arc starts \(start), not Rust", sourceLocation: sourceLocation)
        #expect(abs(end.r - ember.redComponent) < 0.08 && abs(end.g - ember.greenComponent) < 0.06,
                "the arc ends \(end), not Ember", sourceLocation: sourceLocation)
    }

    @Test func underReduceMotionACardNeitherPopsNorBreathes() {
        let done = CardScene(.done, reduceMotion: true)
        let area = { (t: Double) in done.at(t).mass(in: done.ringArea, Weights.near(MotionSpec.ok)) }
        #expect(abs(area(0.19) / area(2) - 1) < 0.05, "it popped")
        let waiting = CardScene(.waiting, reduceMotion: true)
        let border = { (t: Double) in waiting.at(t).mass(where: { waiting.onBorder($0, band: 1.2) }, Weights.warm) }
        #expect(abs(border(0) - border(MotionSpec.breatheHalf)) < 0.3, "it breathes")
    }
}

/// `.r-prog` on both engines at several shares: Rust where the arc starts,
/// Ember where it stops, wherever on the ring that is.
@Suite(.serialized) @MainActor
struct MotionProgressArcTests {
    static let shares = [0.25, 0.6, 0.9]

    @Test(arguments: shares)
    func aLayerDrawnArcShadesRustToEmber(_ p: Double) throws {
        let scene = try StatusScene(.pill, .progress(p))
        let frame = scene.at(0.2)
        let circle = scene.ringCircle(radius: 5.75, count: 180)
        #expect(abs(frame.litShare(along: circle, over: 0.3, Weights.warm) - p) < 0.07)
        MotionOverviewCardTests.expectArcRunsRustToEmber(frame, centre: scene.ringCentre, radius: 5.75, share: p)
    }

    @Test(arguments: shares)
    func aCardsArcShadesRustToEmber(_ p: Double) throws {
        let scene = CardScene(.progress(p))
        let frame = scene.at(0.2)
        let c = try #require(frame.boxCentre(in: scene.ringArea, over: 0.18, Weights.light))
        let circle = (0..<180).map { i -> CGPoint in
            let a = CGFloat(Double(i) / 180 * 2 * .pi)
            return CGPoint(x: c.x + 7.75 * Foundation.cos(a), y: c.y + 7.75 * Foundation.sin(a))
        }
        #expect(abs(frame.litShare(along: circle, over: 0.25, Weights.warm) - p) < 0.07)
        MotionOverviewCardTests.expectArcRunsRustToEmber(frame, centre: c, radius: 7.75, share: p)
    }
}
