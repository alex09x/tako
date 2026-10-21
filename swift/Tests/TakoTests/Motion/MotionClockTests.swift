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

/// The SwiftUI clocks, counted frame by frame on screen: the Overview takes
/// 30 frames a second at rest and every frame while a card plays a one-off,
/// then 30 again; it takes none when paused; a sidebar row takes frames while
/// it shakes, none once it rests, none while the sidebar is paused.
@Suite(.serialized) @MainActor
struct MotionClockTests {
    final class Box<T>: ObservableObject { @Published var value: T; init(_ v: T) { value = v } }

    /// The views' own asyncAfter and tasks run on the main queue: it runs while the test waits.
    private func wait(_ seconds: TimeInterval) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    private func frames(_ key: String, over seconds: TimeInterval) async -> Int {
        var n = 0
        LivingAnimationState.shared.onFrame = { if $0 == key { n += 1 } }
        defer { LivingAnimationState.shared.onFrame = nil }
        await wait(seconds)
        return n
    }

    private func overview(_ statuses: [Tako.PaneStatus]) -> (SwiftUIMotionProbe, PaneOverviewStore) {
        let store = PaneOverviewStore()
        store.items = statuses.map { PaneOverviewItem(id: UUID(), title: "pane", status: $0) }
        let probe = SwiftUIMotionProbe(PaneOverviewView(isPresented: .constant(true), showsBackdrop: false, store: store),
                                       size: CGSize(width: 520, height: 360))
        return (probe, store)
    }

    @Test func theOverviewTakesThirtyFramesASecondAtRest() async {
        let (probe, _) = overview([.working, .needsApproval])
        defer { probe.close() }
        await wait(0.4)
        let n = await frames("overview", over: 1)
        #expect((20...40).contains(n), "\(n) frames in a second, not 30")
    }

    @Test func aOneOffTakesEveryFrameUntilItRestsThenThirtyAgain() async {
        let (probe, _) = overview([.working, .done])
        defer { probe.close() }
        let during = await frames("overview", over: 0.5)
        #expect(during >= 24, "a card's one-off took only \(during) frames in half a second")
        await wait(0.8)
        let after = await frames("overview", over: 1)
        #expect((20...40).contains(after), "after the one-off \(after) frames a second, not 30")
    }

    /// The Overview opens on a frame of five cards; 0.05 s later its clock
    /// starts and the rest of the cards come in.
    @Test func theOverviewOpensOnAStillFrameOfFiveCardsThenItsClockStarts() async {
        var n = 0
        LivingAnimationState.shared.onFrame = { if $0 == "overview" { n += 1 } }
        defer { LivingAnimationState.shared.onFrame = nil }
        let store = PaneOverviewStore()
        store.items = (0..<12).map { _ in PaneOverviewItem(id: UUID(), title: "pane", status: .working) }
        let probe = SwiftUIMotionProbe(PaneOverviewView(isPresented: .constant(true), showsBackdrop: false, store: store),
                                       size: CGSize(width: 1100, height: 760))
        defer { probe.close() }
        let firstRep = probe.snapshot()
        let still = n
        await wait(0.4)
        #expect(n - still >= 4, "the Overview's clock never started: \(n - still) frames")
        // Three to a row: the sixth card is the second row's third, there
        // only once the clock runs.
        func sixthCard(_ r: NSBitmapImageRep) -> Double {
            var sum = 0.0
            for y in stride(from: 2 * r.pixelsHigh / 6, to: 3 * r.pixelsHigh / 6, by: 3) {
                for x in stride(from: 2 * r.pixelsWide / 3, to: r.pixelsWide, by: 3) {
                    let c = r.colorAt(x: x, y: y); sum += Double((c?.redComponent ?? 0) + (c?.greenComponent ?? 0))
                }
            }
            return sum
        }
        let before = sixthCard(firstRep), after = sixthCard(probe.snapshot())
        #expect(after > before * 1.12, "the sixth card was there in the first frame: \(before) -> \(after)")
    }

    /// Nobody can see Tako: the Overview takes no frames until it is seen.
    @Test func aCoveredOverviewTakesNoFrames() async {
        let motion = LivingAnimationState.shared
        let covered = MotionPauseTests.Window(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        covered.isReleasedWhenClosed = false
        covered.seen = []
        let saved = motion.windowsToWatch
        motion.windowsToWatch = { [covered] }
        motion.recomputeOcclusion()
        defer {
            motion.windowsToWatch = saved
            motion.recomputeOcclusion()
        }
        let (probe, _) = overview([.working])
        defer { probe.close() }
        await wait(0.3)
        let n = await frames("overview", over: 0.6)
        #expect(n <= 2, "a covered Overview took \(n) frames")
        covered.seen = .visible
        motion.recomputeOcclusion()
        let seen = await frames("overview", over: 0.5)
        #expect(seen >= 8, "the Overview did not go on once seen: \(seen) frames")
    }

    @Test func aPausedOverviewTakesNoFrames() async {
        let motion = LivingAnimationState.shared
        let saved = motion.reduceMotionSource
        motion.reduceMotionSource = { true }
        motion.refreshReduceMotion()
        defer {
            motion.reduceMotionSource = saved
            motion.refreshReduceMotion()
        }
        let (probe, _) = overview([.working])
        defer { probe.close() }
        await wait(0.3)
        let n = await frames("overview", over: 0.6)
        #expect(n <= 2, "a paused Overview took \(n) frames")
    }

    struct Row: View {
        @ObservedObject var item: Box<SessionSidebarItem>
        let paused: Bool
        var body: some View {
            SessionSidebarRowView(item: item.value, index: 0, selectedIndex: -1, targetWindow: nil, editingItemId: .constant(nil),
                                  editingDescriptionText: .constant(""), isPresented: .constant(true), now: nil,
                                  reduceMotion: false, motionPaused: paused, onSelect: {})
        }
    }

    @Test func aFailedRowTakesFramesWhileItShakesAndNoneOnceItRests() async {
        let item = Box(MotionSurfaceHarness.item(.idle, isChild: false, pulses: 0))
        let probe = SwiftUIMotionProbe(Row(item: item, paused: false), size: CGSize(width: 280, height: 40))
        defer { probe.close() }
        await wait(0.2)
        item.value = MotionSurfaceHarness.item(.failed, isChild: false, pulses: 0)
        let shaking = await frames("row", over: 0.4)
        #expect(shaking >= 10, "a shaking row took \(shaking) frames")
        await wait(0.5)
        let resting = await frames("row", over: 0.6)
        #expect(resting <= 2, "a row at rest after its shake took \(resting) frames")
    }

    @Test func aPausedSidebarsRowTakesNoFrames() async {
        let item = Box(MotionSurfaceHarness.item(.idle, isChild: false, pulses: 0))
        let probe = SwiftUIMotionProbe(Row(item: item, paused: true), size: CGSize(width: 280, height: 40))
        defer { probe.close() }
        await wait(0.2)
        item.value = MotionSurfaceHarness.item(.failed, isChild: false, pulses: 0)
        let n = await frames("row", over: 0.5)
        #expect(n <= 2, "a paused row took \(n) frames")
        #expect(SessionSidebarView.motionPaused(timelinePaused: true, isPresented: true))
        #expect(SessionSidebarView.motionPaused(timelinePaused: false, isPresented: false))
        #expect(!SessionSidebarView.motionPaused(timelinePaused: false, isPresented: true))
    }

}
