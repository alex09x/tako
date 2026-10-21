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
import Testing
@testable import Tako

/// When Tako stops moving, through the observers the app really has: only
/// when nobody can see any of its windows (Sessions UI: "Скрытые и
/// перекрытые окна не анимируются"), never for being in the background
/// (Alex, 2026-10-20), and under Reduce Motion as the system sets it.
@Suite(.serialized) @MainActor
struct MotionPauseTests {
    final class Window: NSWindow {
        var shown = true
        var seen: NSWindow.OcclusionState = .visible
        override var isVisible: Bool { shown }
        override var occlusionState: NSWindow.OcclusionState { seen }
    }

    private func window() -> Window {
        let w = Window(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        return w
    }

    /// The observers are on the main queue: it runs while the test waits.
    private func settle() async { try? await Task.sleep(nanoseconds: 80_000_000) }

    private func watching(_ windows: [NSWindow], _ body: () async throws -> Void) async rethrows {
        let motion = LivingAnimationState.shared
        let saved = motion.windowsToWatch
        motion.windowsToWatch = { windows }
        defer {
            motion.windowsToWatch = saved
            motion.recomputeOcclusion()
        }
        try await body()
    }

    @Test func nobodySeesTakoOnlyWhenEveryWindowOnScreenIsCovered() {
        let a = window(), b = window()
        #expect(!LivingAnimationState.nobodySees([]), "no windows is not hidden: nothing to pause")
        #expect(!LivingAnimationState.nobodySees([a, b]))
        a.seen = []
        #expect(!LivingAnimationState.nobodySees([a, b]), "one window still seen keeps it moving")
        b.seen = []
        #expect(LivingAnimationState.nobodySees([a, b]))
        b.shown = false
        #expect(LivingAnimationState.nobodySees([a, b]), "a window ordered out does not count")
    }

    @Test func aCoveredWindowPausesTheMotionAndUncoveredItGoesOn() async {
        let w = window()
        let motion = LivingAnimationState.shared
        await watching([w]) {
            w.seen = []
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: w)
            await settle()
            #expect(motion.isOccludedOrIdle, "a covered window did not pause")
            #expect(motion.isTimelinePaused)
            w.seen = .visible
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: w)
            await settle()
            #expect(!motion.isOccludedOrIdle, "an uncovered window did not go on")
        }
    }

    @Test func takoInTheBackgroundKeepsMoving() async {
        let w = window()
        let motion = LivingAnimationState.shared
        await watching([w]) {
            // On screen while another app has focus: becoming and resigning active both leave it moving.
            for name in [NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification] {
                NotificationCenter.default.post(name: name, object: NSApp)
                await settle()
                #expect(!motion.isOccludedOrIdle, "\(name.rawValue) paused a window on screen")
            }
            // And coming back to the front re-reads the windows.
            w.seen = []
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            await settle()
            #expect(motion.isOccludedOrIdle, "becoming active did not look at the windows again")
        }
    }

    @Test func reduceMotionAsTheSystemSetsItStopsAPillsRing() async throws {
        let motion = LivingAnimationState.shared
        let saved = motion.reduceMotionSource
        defer {
            motion.reduceMotionSource = saved
            motion.refreshReduceMotion()
        }
        motion.reduceMotionSource = { false }
        motion.refreshReduceMotion()
        let bar = Tako.TabBarView(frame: NSRect(x: 0, y: 0, width: 520, height: 38))
        let w = window()
        let rect = CGRect(x: 0, y: 5, width: 140, height: 28)
        bar.updateStatusLayer(for: w, rect: rect, state: .working, hideRing: false)
        let layer = try #require(bar.statusLayers[ObjectIdentifier(w)])
        #expect(layer.animationInTree(forKey: "spin") != nil, "a working ring turns")

        motion.reduceMotionSource = { true }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        await settle()
        #expect(motion.reduceMotion, "the system's Reduce Motion did not reach Tako")
        bar.updateStatusLayer(for: w, rect: rect, state: .working, hideRing: false)
        #expect(layer.animationInTree(forKey: "spin") == nil, "under Reduce Motion the ring still turns")
    }
}
