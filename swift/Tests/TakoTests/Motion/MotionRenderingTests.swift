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

/// The SwiftUI motions as their window draws them, frame by frame at fixed
/// times: where the spinner's head and the comet are, how big the pop is,
/// how far the shake goes, how wide the halo, how bright the breathing
/// border, and where a sidebar row's glint is. The curves can be right while
/// the drawing is not -- the sidebar glint stood still on macOS 15 with the
/// right progress every frame.
@Suite(.serialized)
@MainActor
struct MotionRenderingTests {
    private typealias L = LivingAnimationState
    private typealias S = WindowSnapshot

    private func at(_ t: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: t) }

    /// Degrees from `centre` to `p`, clockwise from 3 o'clock (y down), as SwiftUI turns.
    private func degrees(_ p: CGPoint, around centre: CGPoint) -> Double {
        Double(atan2(p.y - centre.y, p.x - centre.x)) * 180 / .pi
    }

    /// `a - b` as the shortest turn, -180...180.
    private func turn(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    /// The weighted mean direction of `points` around `centre`.
    private func direction(_ points: [(p: CGPoint, w: CGFloat)], around centre: CGPoint) -> Double {
        var x = 0.0, y = 0.0
        for (p, w) in points {
            let a = degrees(p, around: centre) * .pi / 180
            x += Double(w) * cos(a); y += Double(w) * sin(a)
        }
        return atan2(y, x) * 180 / .pi
    }

    /// The bounding box of the pixels over `threshold`.
    private func box(_ points: [(p: CGPoint, w: CGFloat)]) -> CGRect? {
        guard let first = points.first?.p else { return nil }
        var r = CGRect(origin: first, size: .zero)
        for (p, _) in points { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }

    // MARK: - The ring

    @Test func theSpinnerHeadTurnsClockwiseWithTheClock() throws {
        let size = CGSize(width: 18, height: 18), centre = CGPoint(x: 9, y: 9)
        func head(_ t: TimeInterval) throws -> Double {
            let snap = S(StatusRingView(state: .working, size: .large, now: at(t)).background(Color.black), size: size)
            let brightest = try #require(snap.points(over: 0.05, S.redExcess).max { $0.w < $1.w })
            return degrees(brightest.p, around: centre)
        }
        let start = try head(0)
        for t in [0.1, 0.2, 0.3, 0.45, 0.6, 0.75] {
            let moved = turn(try head(t), start)
            let expected = turn(L.spinDegrees(at: t), L.spinDegrees(at: 0))
            #expect(abs(turn(moved, expected)) < 15, "spinner at \(t): turned \(moved)°, the clock says \(expected)°")
        }
    }

    @Test func theDonePopShrinksThenOvershoots() throws {
        let size = CGSize(width: 40, height: 40)
        for elapsed in [0.05, 0.192, 0.3, 0.448, 0.6, 2.0] {
            let snap = S(StatusRingView(state: .done, size: .large, elapsedInState: elapsed).frame(width: 40, height: 40).background(Color.black), size: size)
            let disc = try #require(box(snap.points(over: 0.1, S.greenExcess)))
            let expected = 18 * L.donePopScale(elapsed: elapsed)
            #expect(abs(disc.width - expected) < 1.2, "pop at \(elapsed): \(disc.width) pt wide, the design has \(expected)")
        }
    }

    @Test func theFailedRingShakesSideways() throws {
        let size = CGSize(width: 40, height: 40)
        for elapsed in [0.0, 0.064, 0.128, 0.192, 0.32, 0.6] {
            let snap = S(StatusRingView(state: .failed, size: .large, elapsedInState: elapsed, shakeRingOnly: true)
                .frame(width: 40, height: 40).background(Color.black), size: size)
            let disc = try #require(box(snap.points(over: 0.1, S.redExcess)))
            let expected = L.failedShakeOffset(elapsed: elapsed)
            #expect(abs(disc.midX - 20 - expected) < 0.4, "shake at \(elapsed): \(disc.midX - 20) pt, the design has \(expected)")
        }
    }

    @Test func theWaitingHaloGrowsAndTheDotBlinks() throws {
        let size = CGSize(width: 60, height: 60), centre = CGPoint(x: 30, y: 30)
        for t in [0.15, 0.4, 0.65, 0.9] {
            let snap = S(StatusRingView(state: .waiting, size: .large, now: at(t)).frame(width: 60, height: 60).background(Color.black), size: size)
            // The halo's outer edge: a 2 pt stroke on a 9 pt radius, scaled.
            let reach = snap.points(over: 0.04, S.redExcess).map { hypot($0.p.x - centre.x, $0.p.y - centre.y) }.max() ?? 0
            let expected = 10 * L.haloMetrics(at: t).scale
            #expect(abs(reach - expected) < 1.2, "halo at \(t): reaches \(reach) pt, the design \(expected)")
            // The dot alone at the centre: Claw at the blink's opacity.
            let c = snap.rgb(Int(30 * snap.scale), Int(30 * snap.scale))
            let claw = Tako.LivingTokens.claw
            let full = claw.redComponent - max(claw.greenComponent, claw.blueComponent)
            let alpha = S.redExcess(c.r, c.g, c.b) / full
            #expect(abs(Double(alpha) - L.blinkOpacity(at: t)) < 0.08, "dot at \(t): \(alpha), the design \(L.blinkOpacity(at: t))")
        }
    }

    // MARK: - The surface

    @Test func theCometRunsClockwiseRoundTheBorder() throws {
        let size = CGSize(width: 48, height: 48), centre = CGPoint(x: 24, y: 24)
        func comet(_ t: TimeInterval) -> Double {
            let snap = S(LivingSurfaceEffectsOverlay(state: .working, cornerRadius: 7, now: at(t)).background(Color.black), size: size)
            return direction(snap.points(over: 0.05, S.redExcess), around: centre)
        }
        let start = comet(0)
        for t in [0.2, 0.5, 0.8, 1.1, 1.5, 1.9] {
            let moved = turn(comet(t), start)
            let expected = turn(L.cometDegrees(at: t), L.cometDegrees(at: 0))
            #expect(abs(turn(moved, expected)) < 15, "comet at \(t): turned \(moved)°, the clock says \(expected)°")
        }
    }

    @Test func theWaitingBorderBreathes() {
        let size = CGSize(width: 160, height: 40)
        let claw = Tako.LivingTokens.claw
        let full = claw.redComponent - max(claw.greenComponent, claw.blueComponent)
        for t in [0.0, 0.4, 0.8, 1.2] {
            let snap = S(LivingSurfaceEffectsOverlay(state: .waiting, cornerRadius: 7, now: at(t)).background(Color.black), size: size)
            // The top edge's middle: a 1 pt Claw border at the breath's alpha.
            let x = Int(80 * snap.scale)
            let edge = (0..<Int(snap.scale)).map { y -> CGFloat in let c = snap.rgb(x, y); return S.redExcess(c.r, c.g, c.b) }.max() ?? 0
            let expected = 0.40 + 0.55 * L.breatheFactor(at: t)
            #expect(abs(Double(edge / full) - expected) < 0.08, "border at \(t): \(edge / full), the design \(expected)")
        }
    }

    // MARK: - A sidebar row

    /// A sidebar row in `status`, drawn `elapsed` seconds into its state.
    private func row(_ status: Tako.PaneStatus, at elapsed: TimeInterval) -> S {
        L.shared.fixedTimeOverride = elapsed
        defer { L.shared.fixedTimeOverride = nil }
        let item = SessionSidebarItem(id: "motion-row", index: 0, isSelected: false, title: "psql", status: status,
                                      indentationLevel: 1, workspaceId: UUID(), tabId: "motion-tab")
        let view = SessionSidebarRowView(item: item, index: 0, selectedIndex: -1, targetWindow: nil,
                                         editingItemId: .constant(nil), editingDescriptionText: .constant(""),
                                         isPresented: .constant(true), now: at(elapsed), reduceMotion: false, onSelect: {})
        return S(view.background(Color(nsColor: Tako.LivingTokens.body)), size: CGSize(width: 280, height: 40))
    }

    @Test func aDoneRowsGlintCrossesTheRow() throws {
        // The row's surface: 8 pt in from each side of the 280 pt sidebar.
        let left: CGFloat = 8, width: CGFloat = 264
        var checked = 0
        for elapsed in [0.22, 0.28, 0.34, 0.40, 0.46] {
            let k = try #require(DoneGlint.progress(elapsed: elapsed))
            let expected = left + DoneGlint.tileOrigin(progress: k, width: width) + 1.25 * width
            // Past the ring, which is green too, and short of the edge, where the band is cut.
            guard expected > 70, expected < 260 else { continue }
            checked += 1
            let columns = row(.done, at: elapsed).columns(S.greenExcess).filter { $0.x > 60 }
            let band = try #require(columns.max { $0.sum < $1.sum })
            #expect(band.sum > 0.01, "no band at \(elapsed)")
            #expect(abs(band.x - expected) < 5, "glint at \(elapsed): at \(band.x), the design has \(expected)")
        }
        #expect(checked >= 3)
    }

    @Test func aFailedRowShakesAsAWhole() throws {
        func ringCentre(_ elapsed: TimeInterval) throws -> CGFloat {
            let red = row(.error, at: elapsed).points(over: 0.15, S.redExcess).filter { $0.p.x < 60 }
            // The ring: 14 pt down from its top, clear of the failed line along the row's foot.
            let top = try #require(red.map(\.p.y).min())
            return try #require(box(red.filter { $0.p.y < top + 15 })).midX
        }
        let rest = try ringCentre(1.0)
        for elapsed in [0.064, 0.128, 0.192, 0.32] {
            let dx = try ringCentre(elapsed) - rest
            let expected = L.failedShakeOffset(elapsed: elapsed)
            #expect(abs(dx - expected) < 0.4, "row shake at \(elapsed): \(dx) pt, the design \(expected)")
        }
    }
}
