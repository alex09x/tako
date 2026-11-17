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

    private func frames(_ key: String, over seconds: TimeInterval, trace: MotionStageTrace? = nil) async -> Int {
        var n = 0
        LivingAnimationState.shared.onFrame = { if $0 == key { n += 1; trace?.mark("\(key).frame") } }
        defer { LivingAnimationState.shared.onFrame = nil }
        trace?.mark("frames.wait.start")
        await wait(seconds)
        trace?.mark("frames.wait.end")
        diagnostics("\(key): \(n) frames over \(seconds)s")
        return n
    }

    /// Diagnostics only: the motion clock's own pause inputs and the probe's
    /// window, content and bitmap sizes, as they are at `label`.
    private func record(_ trace: MotionStageTrace?, _ label: String, _ probe: SwiftUIMotionProbe, bitmap: NSBitmapImageRep? = nil) {
        guard let trace else { return }
        let motion = LivingAnimationState.shared
        trace.set(label, ["t": trace.now(), "reduce": motion.reduceMotion, "paused": motion.isTimelinePaused,
                          "occludedOrIdle": motion.isOccludedOrIdle, "shown": motion.statusShown,
                          "animates": motion.statusAnimates, "fixedTime": motion.fixedTimeOverride != nil,
                          "appActive": NSApp.isActive, "window": "\(probe.window.frame)",
                          "windowVisible": probe.window.isVisible, "occlusion": probe.window.occlusionState.rawValue,
                          "content": "\(probe.host.bounds)",
                          "bitmap": bitmap.map { [$0.pixelsWide, $0.pixelsHigh] } ?? [],
                          "screenFps": NSScreen.main?.maximumFramesPerSecond ?? 0])
    }

    /// Retain the actual clock prerequisites on hosted runners. A paused
    /// clock, an occluded window and a non-running presentation are different
    /// failures; no frame-count expectation is skipped or relaxed here.
    private func diagnostics(_ label: String, window: NSWindow? = nil) {
        let motion = LivingAnimationState.shared
        let watched = motion.windowsToWatch()
        print("[motion environment] \(label); reduce=\(motion.reduceMotion), source=\(motion.reduceMotionSource()), paused=\(motion.isTimelinePaused), occluded=\(motion.isOccludedOrIdle), shown=\(motion.statusShown), animates=\(motion.statusAnimates), fixed=\(String(describing: motion.fixedTimeOverride)), active=\(NSApp.isActive)")
        print("[motion display] screen=\(String(describing: NSScreen.main?.frame)), scale=\(NSScreen.main?.backingScaleFactor ?? 0), fps=\(NSScreen.main?.maximumFramesPerSecond ?? 0), watched=\(watched.count), visible=\(watched.filter(\.isVisible).count), probeVisible=\(window?.isVisible ?? false), probeOcclusion=\(window?.occlusionState.rawValue ?? 0)")
    }

    private func overview(_ statuses: [Tako.PaneStatus]) -> (SwiftUIMotionProbe, PaneOverviewStore) {
        let store = PaneOverviewStore()
        store.items = statuses.map { PaneOverviewItem(id: UUID(), title: "pane", status: $0) }
        let probe = SwiftUIMotionProbe(PaneOverviewView(isPresented: .constant(true), showsBackdrop: false, store: store),
                                       size: CGSize(width: 520, height: 360))
        diagnostics("overview mounted", window: probe.window)
        return (probe, store)
    }

    @Test func aClockProbeRunsAndRestoresAReducedHost() async {
        let motion = LivingAnimationState.shared
        let realSource = motion.reduceMotionSource
        motion.reduceMotionSource = { true }
        motion.refreshReduceMotion()
        defer {
            motion.reduceMotionSource = realSource
            motion.refreshReduceMotion()
        }
        #expect(motion.reduceMotion)
        await withMotionOn {
            #expect(!motion.reduceMotion)
            let (probe, _) = overview([.working])
            defer { probe.close() }
            await wait(0.4)
            let n = await frames("overview", over: 0.5)
            #expect(n >= 8, "the controlled motion fixture stayed paused by the simulated host: \(n) frames")
        }
        #expect(motion.reduceMotionSource(), "the fixture must restore the host's accessibility source")
        #expect(motion.reduceMotion)
    }

    @Test func theOverviewTakesThirtyFramesASecondAtRest() async {
        // Diagnostics only (TAKO_MOTION_DIAGNOSTICS): the rest-rate control, timed the same way.
        let trace = MotionStageTrace("clock-rest")
        defer { trace?.write() }
        await withMotionOn {
            trace?.mark("probe.init.start")
            let (probe, _) = overview([.working, .needsApproval])
            trace?.mark("probe.init.end")
            defer { probe.close() }
            record(trace, "mounted", probe)
            trace?.mark("settle.wait.start")
            await wait(0.4)
            trace?.mark("settle.wait.end")
            let n = await frames("overview", over: 1, trace: trace)
            record(trace, "counted", probe)
            trace?.set("count", n)
            #expect((20...40).contains(n), "\(n) frames in a second, not 30")
        }
    }

    @Test func aOneOffTakesEveryFrameUntilItRestsThenThirtyAgain() async {
        await withMotionOn {
            let (probe, _) = overview([.working, .done])
            defer { probe.close() }
            let during = await frames("overview", over: 0.5)
            #expect(during >= 24, "a card's one-off took only \(during) frames in half a second")
            await wait(0.8)
            let after = await frames("overview", over: 1)
            #expect((20...40).contains(after), "after the one-off \(after) frames a second, not 30")
        }
    }

    /// The Overview opens on a frame of five cards; 0.05 s later its clock
    /// starts and the rest of the cards come in.
    @Test func theOverviewOpensOnAStillFrameOfFiveCardsThenItsClockStarts() async {
        // The sixth card is measured as light over the dark body: a light
        // shell's body is brighter than the card that arrives on it.
        // Diagnostics only (TAKO_MOTION_DIAGNOSTICS): every overview frame's time from the
        // probe's creation, how long creation and the first snapshot took, and the wait itself.
        let trace = MotionStageTrace("clock-still")
        defer { trace?.write() }
        await withDarkShell { await withMotionOn {
            var n = 0
            LivingAnimationState.shared.onFrame = { if $0 == "overview" { n += 1; trace?.mark("overview.frame") } }
            defer { LivingAnimationState.shared.onFrame = nil }
            let store = PaneOverviewStore()
            store.items = (0..<12).map { _ in PaneOverviewItem(id: UUID(), title: "pane", status: .working) }
            trace?.mark("probe.init.start")
            let probe = SwiftUIMotionProbe(PaneOverviewView(isPresented: .constant(true), showsBackdrop: false, store: store),
                                           size: CGSize(width: 1100, height: 760))
            trace?.mark("probe.init.end")
            defer { probe.close() }
            trace?.mark("firstRep.start")
            let firstRep = probe.snapshot()
            trace?.mark("firstRep.end")
            let still = n
            trace?.set("still", still)
            record(trace, "firstRep", probe, bitmap: firstRep)
            trace?.mark("wait.start")
            await wait(0.4)
            trace?.mark("wait.end")
            trace?.set("counted", n - still)
            record(trace, "waited", probe)
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
        } }
    }

    /// Nobody can see Tako: the Overview takes no frames until it is seen.
    @Test func aCoveredOverviewTakesNoFrames() async {
        await withMotionOn {
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
    }

    @Test func aPausedOverviewTakesNoFrames() async {
        await withMotionOn {
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
        await withMotionOn {
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
    }

    @Test func aPausedSidebarsRowTakesNoFrames() async {
        await withMotionOn {
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

}
