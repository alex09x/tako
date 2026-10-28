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

/// What changes on screen a moment after something happens, left to happen:
/// a synchronized frame left open is drawn after 200 ms, output redraws come
/// together, the strip's display link runs only while something moves, a
/// dragged pill's layer follows it smoothly, and "Copied!" shows for 1.5 s.
@Suite(.serialized) @MainActor
struct MotionDelayTests {
    private func wait(_ seconds: TimeInterval) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    @Test func aSynchronizedFrameLeftOpenIsDrawnAfter200ms() async {
        _ = NSApplication.shared
        let surface = Tako.SurfaceView(frame: .zero)
        _ = surface.core.feedWithOutcome(bytes: Data("\u{1b}[?2026h".utf8))
        surface.syncOverride = false
        surface.armSyncOutputWatchdog()
        await wait(0.1)
        #expect(!surface.syncOverride, "forced before its 200 ms")
        await wait(0.25)
        #expect(surface.syncOverride, "a frame left open stayed frozen")
        #expect(Tako.MetalTerminalHost.syncOutputTimeout == 0.2)
    }

    @Test func aSynchronizedFrameClosedInTimeIsNotForced() async {
        _ = NSApplication.shared
        let surface = Tako.SurfaceView(frame: .zero)
        _ = surface.core.feedWithOutcome(bytes: Data("\u{1b}[?2026h".utf8))
        surface.syncOverride = false
        surface.armSyncOutputWatchdog()
        _ = surface.core.feedWithOutcome(bytes: Data("\u{1b}[?2026l".utf8))
        await wait(0.35)
        #expect(!surface.syncOverride, "a frame that closed was forced anyway")
    }

    @Test func outputRedrawsComeTogetherIntoOne() async {
        _ = NSApplication.shared
        let surface = Tako.SurfaceView(frame: .zero)
        surface.requestPtyRedraw()
        #expect(surface.ptyRedrawScheduled)
        surface.requestPtyRedraw()
        surface.requestPtyRedraw()
        // The surface's own shell prints too, so the flag is watched until it drops once.
        var ran = false
        for _ in 0..<60 where !ran {
            await wait(0.005)
            ran = !surface.ptyRedrawScheduled
        }
        #expect(ran, "the coalesced redraw never ran")
    }

    @Test func theStripsDisplayLinkRunsWhileSomethingMovesAndStops() throws {
        let scene = StripScene(tabs: 2)
        defer { scene.close() }
        let bar = scene.shown
        #expect(bar.window?.isVisible == true)
        bar.failedSince[ObjectIdentifier(NSObject())] = CACurrentMediaTime()
        bar.runMotion()
        let link = try #require(bar.motionLink, "a moving strip on screen took no frames")
        bar.needsDisplay = false
        bar.motionFrame(link)
        #expect(bar.needsDisplay, "a frame while something moves did not redraw")
        #expect(bar.motionLink === link)
        bar.failedSince.removeAll()
        bar.motionFrame(link)
        #expect(bar.motionLink == nil, "the link outlived the motion")
    }

    @Test func theStripsDisplayLinkStopsWhenReduceMotionIsEnabled() throws {
        let scene = StripScene(tabs: 2)
        defer { scene.close() }
        let bar = scene.shown
        bar.failedSince[ObjectIdentifier(NSObject())] = CACurrentMediaTime()
        bar.runMotion()
        let link = try #require(bar.motionLink, "a moving strip on screen took no frames")
        LivingAnimationState.shared.reduceMotionSource = { true }
        LivingAnimationState.shared.refreshReduceMotion()
        bar.motionFrame(link)
        #expect(bar.motionLink == nil, "the display link kept running under Reduce Motion")
        bar.runMotion()
        #expect(bar.motionLink == nil, "a new display link started under Reduce Motion")
    }

    @Test func aDraggedPillsLayerFollowsItSmoothlyAndOtherwiseAtOnce() {
        // Implicit animation needs a layer the window has drawn: a layer of its tree, committed.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: window.contentLayoutRect)
        host.wantsLayer = true
        window.contentView = host
        defer { window.close() }
        let layer = Tako.TabStatusLayer()
        host.layer?.addSublayer(layer)
        let a = CGRect(x: 0, y: 5, width: 140, height: 28), b = a.offsetBy(dx: 60, dy: 0)
        layer.apply(state: .idle, in: a, hideRing: false, reduceMotion: false, paused: false)
        CATransaction.flush()
        layer.apply(state: .idle, in: b, hideRing: false, reduceMotion: false, paused: false, allowFrameAnimation: false)
        #expect(layer.animation(forKey: "position") == nil, "a pill at rest moved by animation")
        CATransaction.flush()
        layer.apply(state: .idle, in: a, hideRing: false, reduceMotion: false, paused: false, allowFrameAnimation: true)
        #expect(layer.animation(forKey: "position") != nil, "a dragged pill's layer jumped instead of following")
    }

    @Test func copiedShowsForAMomentAndAnotherCopyKeepsItsOwn() async {
        let flash = CopiedFlash()
        #expect(flash.hold == 1.5)
        flash.hold = 0.1
        flash.flash()
        #expect(flash.shown)
        await wait(0.06)
        flash.flash()
        await wait(0.07)
        #expect(flash.shown, "the first copy's timer cut the second short")
        await wait(0.1)
        #expect(!flash.shown, "Copied! stayed")
    }

    /// Search hits are recounted once output pauses for 150 ms; output that
    /// never pauses stops postponing it after 350 ms.
    @Test func searchHitsAreRecountedOnceOutputPausesAndAtLeastEvery350ms() async {
        _ = NSApplication.shared
        let surface = Tako.SurfaceView(frame: .zero)
        let board = NSPasteboard(name: NSPasteboard.Name("tako-test-find-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        surface.searchState = Tako.OSSurfaceView.SearchState(from: Tako.Action.StartSearch(needle: "line"), pasteboard: board)
        surface.scheduleSearchHitRefresh()
        #expect(surface.searchHitDebounceItem != nil)
        await wait(0.08)
        #expect(surface.searchHitDebounceItem != nil, "recounted before the output paused")
        await wait(0.15)
        #expect(surface.searchHitDebounceItem == nil, "not recounted 150 ms after the output paused")
        // Output that never pauses: still recounted within 350 ms.
        let began = Date()
        var firstRecount: TimeInterval?
        while Date().timeIntervalSince(began) < 0.7, firstRecount == nil {
            surface.scheduleSearchHitRefresh()
            await wait(0.04)
            if surface.searchHitDebounceItem == nil { firstRecount = Date().timeIntervalSince(began) }
        }
        // The last postponement lands before 350 ms and fires 150 ms later:
        // at most 0.5 s. Without the ceiling it never fires while output runs.
        #expect((firstRecount ?? 9) < 0.6, "busy output held the recount back: \(String(describing: firstRecount))")
    }

    /// The search across tabs waits for typing to pause (150 ms) before it searches.
    @Test func searchingAcrossTabsWaitsForTypingToPause() async {
        let search = CrossSessionSearch()
        search.targets = { [] }
        #expect(search.debounce == .milliseconds(150))
        search.query = "panic"
        #expect(search.status == .searching)
        await wait(0.08)
        #expect(search.status == .searching, "searched before typing paused")
        await wait(0.3)
        #expect(search.status != .searching, "never searched once typing paused")
    }

}
