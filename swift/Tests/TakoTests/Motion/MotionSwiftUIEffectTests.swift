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

/// SwiftUI's own motion, watched frame by frame in a window (SwiftUIMotionProbe):
/// a card's arc easing to a new share, a live ring's ripple, a failed sidebar
/// row shaking on its live clock, and secure input's turning ring.
@Suite(.serialized) @MainActor
struct MotionSwiftUIEffectTests {
    final class Box<T>: ObservableObject { @Published var value: T; init(_ v: T) { value = v } }

    /// Frames in between, and at rest by `rest`.
    private func expectMoved(_ frames: [(t: TimeInterval, value: Double)], from start: Double, restBy rest: TimeInterval, _ what: String) throws {
        let end = try #require(frames.last).value
        let span = abs(end - start)
        let between = frames.filter { $0.t < rest && abs($0.value - start) > span * 0.1 && abs($0.value - end) > span * 0.1 }
        #expect(span > 5, "\(what): nothing changed")
        #expect(!between.isEmpty, "\(what) happened at once")
        #expect(frames.filter { $0.t > rest }.allSatisfy { abs($0.value - end) < span * 0.06 }, "\(what) still moving after \(rest) s")
    }

    struct Ring: View {
        @ObservedObject var share: Box<Double>
        var body: some View { StatusRingView(state: .progress(share.value), size: .large, now: Date(timeIntervalSinceReferenceDate: 1)) }
    }

    @Test func aCardsArcEasesToItsNewShareOverAQuarterSecond() throws {
        let share = Box(0.15)
        let probe = SwiftUIMotionProbe(Ring(share: share), size: CGSize(width: 80, height: 80))
        defer { probe.close() }
        let before = SwiftUIMotionProbe.light(probe.snapshot())
        let frames = probe.frames(after: { share.value = 0.85 }, for: 0.6, measure: SwiftUIMotionProbe.light)
        try expectMoved(frames, from: before, restBy: 0.4, "the arc")
    }

    struct Ripple: View {
        @ObservedObject var pulses: Box<Int>
        var body: some View { LiveRingRipple(pulses: pulses.value, diameter: 40).frame(width: 80, height: 80) }
    }

    @Test func aLiveCardsRippleGrowsAndFadesOncePerBurst() throws {
        let pulses = Box(0)
        let probe = SwiftUIMotionProbe(Ripple(pulses: pulses), size: CGSize(width: 80, height: 80))
        defer { probe.close() }
        #expect(SwiftUIMotionProbe.light(probe.snapshot()) < 1, "a ripple before any output")
        let frames = probe.frames(after: { pulses.value += 1 }, for: 0.6, measure: SwiftUIMotionProbe.light)
        let peak = frames.map(\.value).max() ?? 0
        #expect(peak > 5, "no ripple after a burst")
        #expect(frames.filter { $0.t < 0.3 }.contains { $0.value > 1 }, "the ripple did not show in its 0.3 s")
        #expect(frames.filter { $0.t > 0.45 }.allSatisfy { $0.value < peak * 0.05 }, "the ripple outlived its 0.3 s")
    }

    struct Row: View {
        @ObservedObject var item: Box<SessionSidebarItem>
        var body: some View {
            SessionSidebarRowView(item: item.value, index: 0, selectedIndex: -1, targetWindow: nil, editingItemId: .constant(nil),
                                  editingDescriptionText: .constant(""), isPresented: .constant(true), now: nil,
                                  reduceMotion: false, motionPaused: false, onSelect: {})
        }
    }

    @Test func aFailedRowShakesOnItsLiveClockAndStops() throws {
        let item = Box(MotionSurfaceHarness.item(.working, isChild: false, pulses: 0))
        let probe = SwiftUIMotionProbe(Row(item: item), size: CGSize(width: 280, height: 40))
        defer { probe.close() }
        probe.settle(0.2)
        let before = SwiftUIMotionProbe.centroidX(probe.snapshot())
        let frames = probe.frames(after: { item.value = MotionSurfaceHarness.item(.failed, isChild: false, pulses: 0) }, for: 0.9,
                                  measure: SwiftUIMotionProbe.centroidX)
        let rest = try #require(frames.last).value
        let offsets = frames.filter { $0.t < MotionSpec.shakeDuration }.map { abs($0.value - rest) }
        #expect((offsets.max() ?? 0) > 0.5, "the failed row did not shake: \(before) -> \(rest)")
        #expect(frames.filter { $0.t > MotionSpec.shakeDuration + 0.15 }.allSatisfy { abs($0.value - rest) < 0.2 }, "the row shook past 0.448 s")
    }

    private func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        var sum = 0.0
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                sum += abs(Double(p.redComponent - q.redComponent)) + abs(Double(p.greenComponent - q.greenComponent))
                    + abs(Double(p.blueComponent - q.blueComponent))
            }
        }
        return sum
    }

    @Test func secureInputsRingTurnsAndItsGlowPulses() throws {
        let probe = SwiftUIMotionProbe(SecureInputOverlay(), size: CGSize(width: 120, height: 60))
        defer { probe.close() }
        probe.settle(1.5)
        let a = probe.snapshot(), again = probe.snapshot()
        probe.settle(0.5)
        let b = probe.snapshot()
        let noise = difference(a, again), moved = difference(a, b)
        #expect(moved > noise * 3 + 5, "secure input's ring stood still (\(moved) against noise \(noise))")
    }
}
