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

/// Reduce Motion and the pause, branch by branch where they are taken:
/// the strip's slides, shakes and transitions; the SwiftUI ring's spinner,
/// halo, blink, ripple and glow; a sidebar row's and a card ring's shake;
/// the header ring; and the pause reaching a pill's layer and the
/// exported frame its pose.
@Suite(.serialized) @MainActor
struct MotionReduceMotionTests {
    private func withReduceMotion<T>(_ on: Bool, _ body: @MainActor () throws -> T) rethrows -> T {
        let motion = LivingAnimationState.shared
        let saved = motion.reduceMotionSource
        motion.reduceMotionSource = { on }
        motion.refreshReduceMotion()
        defer {
            motion.reduceMotionSource = saved
            motion.refreshReduceMotion()
        }
        return try body()
    }

    /// Two frames of a SwiftUI view at two times, as the window draws them.
    private func frames<V: View>(_ view: (Date) -> V, size: CGSize) -> (NSBitmapImageRep, NSBitmapImageRep) {
        let a = SwiftUIMotionProbe(view(Date(timeIntervalSinceReferenceDate: 10.1)), size: size)
        let b = SwiftUIMotionProbe(view(Date(timeIntervalSinceReferenceDate: 10.55)), size: size)
        defer { a.close(); b.close() }
        return (a.snapshot(), b.snapshot())
    }

    private func same(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
        for y in stride(from: 0, to: a.pixelsHigh, by: 1) {
            for x in stride(from: 0, to: a.pixelsWide, by: 1) where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { return false }
        }
        return true
    }

    // MARK: The strip

    @Test func underReduceMotionTheChipTakesItsWidthAtOnceAndAPillDoesNotShake() {
        withReduceMotion(true) {
            let bar = Tako.TabBarView(frame: .zero)
            #expect(bar.displayedChipWidth(target: 80, now: 10) == 80)
            #expect(bar.displayedChipWidth(target: 120, now: 10.05) == 120, "the chip slid under Reduce Motion")
            let key = ObjectIdentifier(NSObject())
            #expect(bar.shakeOffset(for: key, state: .failed, previous: .working, now: 1) == 0)
            #expect(bar.shakeOffset(for: key, state: .failed, previous: .failed, now: 1.064) == 0, "a pill shook under Reduce Motion")
            #expect(bar.failedSince.isEmpty)
        }
    }

    @Test func underReduceMotionANewTabTakesItsPlaceAtOnce() throws {
        try withReduceMotion(true) {
            let scene = StripScene(tabs: 2, motionOn: false)
            defer { scene.close() }
            #expect(scene.shown.takesChangesAtOnce)
            let extra = makeWindow(title: "new")
            Tako.CustomTabGroup.join(extra, to: scene.windows[0], select: false)
            defer { Tako.CustomTabGroup.leave(extra); extra.close() }
            let frames = scene.laid()
            let grown = try #require(frames.first { $0.window === extra })
            let other = try #require(frames.first { $0.window === scene.windows[1] })
            #expect(abs(grown.frame.width - other.frame.width) < 0.5, "a new tab grew in under Reduce Motion: \(grown.frame.width)")
            #expect(grown.showsContent)
        }
    }

    @Test func anExportedFrameShakesAFailedPillUnlessReduceMotionIsOn() {
        let bar = Tako.TabBarView(frame: .zero)
        let tab = Tako.TabBarView.Tab(window: makeWindow(title: "t"), frame: .zero, isActive: true, index: 0)
        LivingAnimationState.shared.fixedTimeOverride = 0.064
        defer { LivingAnimationState.shared.fixedTimeOverride = nil }
        withReduceMotion(false) { #expect(abs(bar.stripShake(for: tab, state: .failed) - (-2)) < 0.05) }
        withReduceMotion(true) { #expect(bar.stripShake(for: tab, state: .failed) == 0) }
    }

    @Test func aShakingPillIsDrawnOffItsPlace() throws {
        try withMotionOn {
            let scene = StripScene(tabs: 2, motionOn: false)
            defer { scene.close() }
            let bar = scene.shown
            @MainActor func leftEdge() -> Int {
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bar.bounds.width), pixelsHigh: Int(bar.bounds.height),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                bar.draw(bar.bounds)
                NSGraphicsContext.restoreGraphicsState()
                let tab = bar.tabs.first { $0.isActive }!
                let y = rep.pixelsHigh - 1 - Int(tab.frame.midY)
                return (Int(tab.frame.minX) - 6..<Int(tab.frame.midX)).first { x in
                    guard let c = rep.colorAt(x: x, y: y) else { return false }
                    return abs(c.redComponent - 0x24 / 255) < 0.03 && abs(c.greenComponent - 0x1C / 255) < 0.03
                } ?? -1
            }
            let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            scene.windows[0].contentView?.addSubview(surface)
            defer { surface.removeFromSuperview() }
            let rest = leftEdge()
            surface.crab.setStatus(.error, text: nil)
            _ = leftEdge()   // the moment it fails
            RunLoop.current.run(until: Date().addingTimeInterval(0.07))
            let shaken = leftEdge()
            #expect(rest >= 0 && shaken >= 0)
            #expect(abs(shaken - rest) >= 1, "the failed pill was drawn where it rests: \(rest) -> \(shaken)")
        }
    }

    // MARK: SwiftUI's ring, glow, rows and cards

    @Test(arguments: [Tako.SurfaceState.working, .waiting])
    func underReduceMotionASwiftUIRingStandsStill(_ state: Tako.SurfaceState) {
        let still = frames({ StatusRingView(state: state, size: .large, now: $0, reduceMotion: true) }, size: CGSize(width: 60, height: 60))
        #expect(same(still.0, still.1), "\(state) moved under Reduce Motion")
        let moving = frames({ StatusRingView(state: state, size: .large, now: $0, reduceMotion: false) }, size: CGSize(width: 60, height: 60))
        #expect(!same(moving.0, moving.1), "\(state) stands still with motion on: the comparison sees nothing")
    }

    @Test func underReduceMotionAWaitingRingHasNoHaloAndAFullDot() {
        let size = CGSize(width: 60, height: 60)
        func shot(_ t: Double, _ rm: Bool) -> NSBitmapImageRep {
            let p = SwiftUIMotionProbe(StatusRingView(state: .waiting, size: .large, now: Date(timeIntervalSinceReferenceDate: t), reduceMotion: rm), size: size)
            defer { p.close() }
            return p.snapshot()
        }
        // Halo at its widest early in its 1.6 s loop; the dot at its dimmest half way.
        let still = shot(10 * 1.6 + 0.3, true), haloed = shot(10 * 1.6 + 0.3, false)
        #expect(SwiftUIMotionProbe.light(still) < SwiftUIMotionProbe.light(haloed) - 1, "a halo under Reduce Motion")
        let dim = shot(10 * 1.6 + 0.8, false), full = shot(10 * 1.6 + 0.8, true)
        // The dot sits at the ring's centre: the light's centre in the still frame.
        var sx = 0.0, sy = 0.0, sw = 0.0
        for y in 0..<full.pixelsHigh {
            for x in 0..<full.pixelsWide {
                let w = Double(full.colorAt(x: x, y: y)?.redComponent ?? 0)
                sx += w * Double(x); sy += w * Double(y); sw += w
            }
        }
        let (cx, cy) = (Int(sx / sw), Int(sy / sw))
        func dot(_ rep: NSBitmapImageRep) -> Double {
            var sum = 0.0
            for y in cy - 2...cy + 2 { for x in cx - 2...cx + 2 { sum += Double(rep.colorAt(x: x, y: y)?.redComponent ?? 0) } }
            return sum
        }
        #expect(dot(full) > dot(dim) + 1, "the dot dims under Reduce Motion: \(dot(full)) vs \(dot(dim))")
    }

    struct Ripple: View {
        @ObservedObject var pulses: MotionSwiftUIEffectTests.Box<Int>
        var body: some View {
            StatusRingView(state: .live(flowing: true), size: .large, reduceMotion: true, pulses: pulses.value).frame(width: 80, height: 80)
        }
    }

    @Test func underReduceMotionALiveRingDoesNotRipple() {
        let pulses = MotionSwiftUIEffectTests.Box(0)
        let probe = SwiftUIMotionProbe(Ripple(pulses: pulses), size: CGSize(width: 80, height: 80))
        defer { probe.close() }
        let before = SwiftUIMotionProbe.light(probe.snapshot())
        let frames = probe.frames(after: { pulses.value += 1 }, for: 0.4, measure: SwiftUIMotionProbe.light)
        #expect(frames.allSatisfy { abs($0.value - before) < 2 }, "a ripple under Reduce Motion")
    }

    @Test func underReduceMotionTheWaitingGlowStandsStill() {
        let glow = { (now: Date) in
            LivingSurfaceOuterGlow(state: .waiting, cornerRadius: 6, backingColor: .black, now: now, reduceMotion: true)
                .frame(width: 120, height: 40).padding(20)
        }
        let still = frames(glow, size: CGSize(width: 160, height: 80))
        #expect(same(still.0, still.1), "the glow breathed under Reduce Motion")
        #expect(SwiftUIMotionProbe.light(still.0) > 1, "no glow at all under Reduce Motion")
        let breathing = frames({ now in
            LivingSurfaceOuterGlow(state: .waiting, cornerRadius: 6, backingColor: .black, now: now, reduceMotion: false)
                .frame(width: 120, height: 40).padding(20)
        }, size: CGSize(width: 160, height: 80))
        #expect(!same(breathing.0, breathing.1), "the glow stands still with motion on: the comparison sees nothing")
    }

    @Test func underReduceMotionACardRingAndARowDoNotShake() {
        let ring = { (rm: Bool) -> Double in
            let p = SwiftUIMotionProbe(StatusRingView(state: .failed, size: .large, elapsedInState: 0.064, reduceMotion: rm,
                                                      shakeRingOnly: true).frame(width: 60, height: 60), size: CGSize(width: 60, height: 60))
            defer { p.close() }
            return SwiftUIMotionProbe.centroidX(p.snapshot())
        }
        let restAt = SwiftUIMotionProbe(StatusRingView(state: .failed, size: .large, elapsedInState: 5, shakeRingOnly: true)
                                            .frame(width: 60, height: 60), size: CGSize(width: 60, height: 60))
        let rest = SwiftUIMotionProbe.centroidX(restAt.snapshot())
        restAt.close()
        #expect(abs(ring(true) - rest) < 0.1, "a card ring shook under Reduce Motion")
        #expect(abs(ring(false) - rest) > 1, "a card ring does not shake with motion on: the comparison sees nothing")

        let item = MotionSurfaceHarness.item(.failed, isChild: false, pulses: 0)
        let row = { (rm: Bool) -> Double in
            _ = LivingAnimationState.shared.elapsedInState(for: "sidebar-\(item.id)", state: .failed, now: Date(timeIntervalSinceReferenceDate: 0))
            let view = SessionSidebarRowView(item: item, index: 0, selectedIndex: -1,
                                             targetWindow: nil, editingItemId: .constant(nil), editingDescriptionText: .constant(""),
                                             isPresented: .constant(true), now: Date(timeIntervalSinceReferenceDate: 0.064), reduceMotion: rm,
                                             motionPaused: false, onSelect: {})
            let p = SwiftUIMotionProbe(view, size: CGSize(width: 280, height: 40))
            defer { p.close() }
            return SwiftUIMotionProbe.centroidX(p.snapshot())
        }
        #expect(abs(row(true) - row(false)) > 0.3, "a row shakes the same with Reduce Motion on as off")
    }

    @Test func theHeaderRingRestsUnderReduceMotionAndWhenNothingWaits() {
        #expect(SessionSidebarView.headerRingRests(reduceMotion: true, waiting: 3))
        #expect(SessionSidebarView.headerRingRests(reduceMotion: false, waiting: 0))
        #expect(!SessionSidebarView.headerRingRests(reduceMotion: false, waiting: 2))
    }

    // MARK: The pause and the export reaching the layers

    @Test func aCoveredTakoPausesAPillsLayer() throws {
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
        let bar = Tako.TabBarView(frame: NSRect(x: 0, y: 0, width: 520, height: 38))
        let w = makeWindow(title: "p")
        bar.updateStatusLayer(for: w, rect: CGRect(x: 0, y: 5, width: 140, height: 28), state: .working, hideRing: false)
        let layer = try #require(bar.statusLayers[ObjectIdentifier(w)])
        #expect(layer.speed == 0, "a pill kept moving while nobody could see Tako")
    }

    /// While nobody can see Tako the strip takes its changes at once and
    /// runs no frames: a covered window is paused as a hidden one is.
    @Test func aCoveredStripTakesItsChangesAtOnceAndRunsNoFrames() {
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
        #expect(motion.isOccludedOrIdle)
        let bar = Tako.TabBarView(frame: .zero)
        #expect(bar.displayedChipWidth(target: 80, now: 10) == 80)
        #expect(bar.displayedChipWidth(target: 120, now: 10.05) == 120, "the chip slid while nobody could see it")
        #expect(bar.shakeOffset(for: ObjectIdentifier(bar), state: .failed, previous: .working, now: 1) == 0)
        #expect(bar.failedSince.isEmpty, "a pill shook while nobody could see it")
        let scene = StripScene(tabs: 2, motionOn: false)
        defer { scene.close() }
        #expect(scene.shown.takesChangesAtOnce, "a covered strip moved its tabs")
        scene.shown.runMotion()
        #expect(scene.shown.motionLink == nil, "a covered strip took frames")
    }

    @Test func anExportedStripStepsAPillToTheExportsTime() throws {
        LivingAnimationState.shared.fixedTimeOverride = 0.3
        defer { LivingAnimationState.shared.fixedTimeOverride = nil }
        let bar = Tako.TabBarView(frame: NSRect(x: 0, y: 0, width: 520, height: 38))
        let w = makeWindow(title: "e")
        bar.updateStatusLayer(for: w, rect: CGRect(x: 0, y: 5, width: 140, height: 28), state: .working, hideRing: false)
        let spin = try #require(bar.statusLayers[ObjectIdentifier(w)]?.ringContainer.sublayers?.first { $0.name == "workingSpin" })
        let angle = atan2(Double(spin.transform.m12), Double(spin.transform.m11))
        let expected = -2 * .pi * 0.3 / MotionSpec.spinnerTurn
        #expect(abs(atan2(sin(angle - expected), cos(angle - expected))) < 0.02, "the exported spinner stands at \(angle)")
    }
}
