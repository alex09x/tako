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
import WebKit
@testable import Tako

/// A pane's overlays, watched as they move: the broadcast banner and the
/// input-ownership header come in from the top over 0.15 s and go the same
/// way. Both popped in and out at once: their transition sat on the view
/// being put in, where an animation never reaches it.
@Suite(.serialized) @MainActor
struct MotionOverlayTests {
    /// A change that moved: frames in between, and at rest within 0.3 s.
    private func expectAnimated(_ frames: [(t: TimeInterval, value: Double)], from start: Double, _ what: String) throws {
        let end = try #require(frames.last).value
        let span = abs(end - start)
        #expect(span > 10, "\(what): nothing changed (\(start) -> \(end))")
        let between = frames.filter { abs($0.value - start) > span * 0.1 && abs($0.value - end) > span * 0.1 }
        let first = frames.prefix(8).map { String(format: "%.0f@%.3f", $0.value, $0.t) }.joined(separator: " ")
        #expect(!between.isEmpty, "\(what) happened at once: \(first)")
        let late = frames.filter { $0.t > 0.15 }.map { String(format: "%.0f@%.3f", $0.value, $0.t) }.joined(separator: " ")
        #expect(frames.filter { $0.t > 0.3 }.allSatisfy { abs($0.value - end) < span * 0.05 },
                "\(what) still moving after 0.3 s (start \(String(format: "%.0f", start)), end \(String(format: "%.0f", end))): \(late)")
    }

    @Test func theBroadcastBannerComesInOverAMomentAndGoes() throws {
        let pane = UUID(), other = UUID()
        let store = BroadcastInputStore.shared
        store.endBroadcast()
        let probe = SwiftUIMotionProbe(BroadcastInputBannerView(paneId: pane), size: CGSize(width: 360, height: 60))
        defer { probe.close(); store.endBroadcast() }
        let none = SwiftUIMotionProbe.light(probe.snapshot())
        let coming = probe.frames(after: { _ = store.startBroadcast(panes: [pane, other], leader: pane) }, for: 0.5,
                                  measure: SwiftUIMotionProbe.light)
        try expectAnimated(coming, from: none, "the banner coming in")
        let shown = try #require(coming.last).value
        let going = probe.frames(after: { store.endBroadcast() }, for: 0.5, measure: SwiftUIMotionProbe.light)
        try expectAnimated(going, from: shown, "the banner going")
    }

    @Test func theInputOwnershipHeaderComesInOverAMomentAndGoes() throws {
        let pane = UUID()
        let store = InputOwnershipStore.shared
        let probe = SwiftUIMotionProbe(InputOwnershipHeaderView(paneId: pane), size: CGSize(width: 420, height: 60))
        defer { probe.close(); store.unlock(paneId: pane) }
        let none = SwiftUIMotionProbe.light(probe.snapshot())
        let coming = probe.frames(after: { store.lock(paneId: pane, by: "claude-code") }, for: 0.5, measure: SwiftUIMotionProbe.light)
        try expectAnimated(coming, from: none, "the header coming in")
        let shown = try #require(coming.last).value
        let going = probe.frames(after: { store.unlock(paneId: pane) }, for: 0.5, measure: SwiftUIMotionProbe.light)
        if store.previousAgent(for: pane) == nil {
            try expectAnimated(going, from: shown, "the header going")
        }
    }

    /// The first file overlay a process opens pays a one-off start (WebKit and
    /// the view hierarchy) before its first frame; a second one, on another
    /// surface, does not (measured per process, cold/fresh/reopen, 2026-11-17).
    /// That cold first-use latency is not this animation's gate: it is printed
    /// here and stays a separate performance follow-up, not fixed behaviour.
    /// So one real overlay is opened, shown and closed on a surface, probe and
    /// window of its own, and the fade is then timed on a fresh surface.
    private func warmUpFileOverlay(_ file: URL) throws {
        let surface = Tako.SurfaceView(frame: .zero)
        let started = ProcessInfo.processInfo.systemUptime
        let probe = SwiftUIMotionProbe(Tako.InspectableSurface(surfaceView: surface), size: CGSize(width: 240, height: 140))
        let mounted = ProcessInfo.processInfo.systemUptime
        defer {
            probe.close()
            probe.window.contentView = nil
        }
        defer { _ = OverlayStore.shared.closeOverlay(paneId: surface.id) }
        let blank = SwiftUIMotionProbe.light(probe.snapshot())
        _ = try OverlayStore.shared.openOverlay(paneId: surface.id, path: file.path,
                                                surfacePwd: file.deletingLastPathComponent().path)
        probe.settle(0.8)
        let shown = SwiftUIMotionProbe.light(probe.snapshot())
        let ready = ProcessInfo.processInfo.systemUptime
        try #require(shown > blank + 10, "the warm-up overlay never showed: \(blank) -> \(shown)")
        _ = OverlayStore.shared.closeOverlay(paneId: surface.id)
        probe.settle(0.8)
        try #require(OverlayStore.shared.overlay(for: surface.id) == nil, "the warm-up overlay is still open")
        try #require(!containsWebView(probe.host), "the warm-up overlay left its web view in the pane")
        print(String(format: "[overlay warm-up] cold probe %.0f ms, cold open to shown snapshot %.0f ms (incl. settle 0.8 s); first-use startup, not this animation's gate",
                     (mounted - started) * 1000, (ready - mounted) * 1000))
    }

    private func containsWebView(_ root: NSView) -> Bool {
        var visited = 0
        func walk(_ view: NSView) -> Bool {
            guard visited < 200 else { return false }
            visited += 1
            if view is WKWebView { return true }
            return view.subviews.contains { walk($0) }
        }
        return walk(root)
    }

    @Test func aFileOverlayFadesInOverThePaneAndOut() throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tako-fade-\(UUID().uuidString).txt")
        try String(repeating: "an overlay over the pane fades in and out\n", count: 40).write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        try warmUpFileOverlay(file)
        let surface = Tako.SurfaceView(frame: .zero)
        defer { _ = OverlayStore.shared.closeOverlay(paneId: surface.id) }
        // Diagnostics only (TAKO_MOTION_DIAGNOSTICS): stage times and frames, written last.
        let trace = MotionStageTrace("overlay")
        defer { trace?.write() }
        trace?.mark("probe.init.start")
        let probe = SwiftUIMotionProbe(Tako.InspectableSurface(surfaceView: surface), size: CGSize(width: 240, height: 140))
        trace?.mark("probe.init.end")
        defer { probe.close() }
        probe.settle(0.8)
        trace?.mark("settle.end")
        let initial = probe.snapshot()
        trace?.mark("before.snapshot.end")
        trace?.keep("before", initial)
        trace?.set("window", ["frame": "\(probe.window.frame)", "visible": probe.window.isVisible,
                              "occlusion": probe.window.occlusionState.rawValue, "host": "\(probe.host.bounds)",
                              "pixels": [initial.pixelsWide, initial.pixelsHigh]])
        let before = SwiftUIMotionProbe.light(initial)
        var opened: Error?
        let coming = probe.frames(after: {
            do {
                _ = try OverlayStore.shared.openOverlay(paneId: surface.id, path: file.path,
                                                        surfacePwd: file.deletingLastPathComponent().path)
            } catch { opened = error }
        }, for: 0.5,
                                  measure: SwiftUIMotionProbe.light, trace: trace, phase: "coming", keepImages: 96)
        #expect(opened == nil, "\(String(describing: opened))")
        #expect(OverlayStore.shared.overlay(for: surface.id) != nil)
        try expectAnimated(coming, from: before, "a file overlay coming in")
        let shown = try #require(coming.last).value
        let going = probe.frames(after: { _ = OverlayStore.shared.closeOverlay(paneId: surface.id) }, for: 0.5,
                                 measure: SwiftUIMotionProbe.light, trace: trace, phase: "going", keepImages: 8)
        try expectAnimated(going, from: shown, "a file overlay going")
    }

    /// TEMPORARY diagnostic, only under TAKO_MOTION_DIAGNOSTICS: is the delay
    /// before a file overlay's first fade frame paid once per process or by
    /// every new overlay? In one process: A, a cold open on a fresh surface
    /// and probe; B, the same on a different fresh surface after A closed;
    /// C, A's surface again in a new probe after its first probe was
    /// detached. Each case gets its own trace (overlay-A-cold, overlay-B-fresh,
    /// overlay-C-reopen-A). It accepts no animation: the only expectations are
    /// that each close leaves no overlay and no WKWebView behind.
    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["TAKO_MOTION_DIAGNOSTICS"] ?? "").isEmpty,
                   "diagnostics only: runs under TAKO_MOTION_DIAGNOSTICS, skipped otherwise"))
    func diagnosticOverlayOpenCostColdFreshAndReopen() throws {
        guard MotionStageTrace.directory != nil else { return }
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tako-fade-cost-\(UUID().uuidString).txt")
        try String(repeating: "an overlay over the pane fades in and out\n", count: 40).write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        func run(_ name: String, on surface: Tako.SurfaceView) throws {
            let trace = try #require(MotionStageTrace(name))
            defer { trace.write() }
            defer { _ = OverlayStore.shared.closeOverlay(paneId: surface.id) }
            trace.mark("probe.init.start")
            let probe = SwiftUIMotionProbe(Tako.InspectableSurface(surfaceView: surface), size: CGSize(width: 240, height: 140))
            trace.mark("probe.init.end")
            defer {
                // Detach the host so the surface can be put in a new probe.
                probe.close()
                probe.window.contentView = nil
                trace.mark("probe.detached")
            }
            probe.settle(0.8)
            trace.mark("settle.end")
            let initial = probe.snapshot()
            trace.mark("before.snapshot.end")
            trace.keep("before", initial)
            trace.set("before", SwiftUIMotionProbe.light(initial))
            var opened: Error?
            _ = probe.frames(after: {
                do {
                    _ = try OverlayStore.shared.openOverlay(paneId: surface.id, path: file.path,
                                                            surfacePwd: file.deletingLastPathComponent().path)
                } catch { opened = error }
            }, for: 0.5, measure: SwiftUIMotionProbe.light, trace: trace, phase: "coming", keepImages: 96)
            trace.set("openError", opened.map { "\($0)" } ?? "")
            // Preparation, not animation acceptance: the shown overlay settles
            // and is read outside any timed capture before it is closed.
            trace.mark("preparation.settle.start")
            probe.settle(0.8)
            let shown = probe.snapshot()
            trace.mark("preparation.settle.end")
            trace.keep("preparation-shown", shown)
            trace.set("preparationShown", SwiftUIMotionProbe.light(shown))
            trace.set("preparationWeb", MotionStageTrace.webSample(in: probe.host))
            _ = probe.frames(after: { _ = OverlayStore.shared.closeOverlay(paneId: surface.id) }, for: 0.5,
                             measure: SwiftUIMotionProbe.light, trace: trace, phase: "going", keepImages: 8)
            let afterClose = MotionStageTrace.webSample(in: probe.host)
            trace.set("afterCloseWeb", afterClose)
            try #require(OverlayStore.shared.overlay(for: surface.id) == nil, "\(name): an overlay is still open after closing")
            try #require(afterClose["present"] as? Bool == false, "\(name): a WKWebView is still in the probe after closing")
        }

        let a = Tako.SurfaceView(frame: .zero), b = Tako.SurfaceView(frame: .zero)
        try run("overlay-A-cold", on: a)
        try run("overlay-B-fresh", on: b)
        try run("overlay-C-reopen-A", on: a)
    }

    /// The Overview scrolls to the card chosen from the keyboard over
    /// 0.15 s. Its frames take longer to draw off screen than the scroll
    /// does, so the scroll is read where it happens: the offset of the
    /// scroll view under the grid, every few milliseconds.
    @Test func theOverviewScrollsToItsChoiceOverAMoment() throws {
        let store = PaneOverviewStore()
        store.items = (0..<30).map { PaneOverviewItem(id: UUID(), title: "pane \($0)", status: .idle) }
        let probe = SwiftUIMotionProbe(PaneOverviewView(isPresented: .constant(true), showsBackdrop: false, store: store),
                                       size: CGSize(width: 520, height: 360))
        defer { probe.close() }
        probe.settle(0.6)
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        let scroll = try #require(scrollViews(probe.host).max { $0.documentView?.frame.height ?? 0 < $1.documentView?.frame.height ?? 0 })
        let offset = { Double(scroll.contentView.bounds.origin.y) }
        let start = offset()
        store.selectedIndex = 20
        let began = Date()
        var frames: [(t: TimeInterval, value: Double)] = []
        while Date().timeIntervalSince(began) < 0.6 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
            frames.append((Date().timeIntervalSince(began), offset()))
        }
        try expectAnimated(frames, from: start, "the Overview scrolling")
    }

    /// A diff review over the pane fades in as the file overlay does; a
    /// comment rebuilds it (its .id carries the count) at once, not by a fade.
    @Test func aDiffReviewFadesInAndACommentRebuildsItAtOnce() throws {
        _ = NSApplication.shared
        let store = DiffReviewStore.shared
        store.resetForTesting()
        defer { store.resetForTesting() }
        let surface = Tako.SurfaceView(frame: .zero)
        let probe = SwiftUIMotionProbe(Tako.InspectableSurface(surfaceView: surface), size: CGSize(width: 240, height: 140))
        defer { probe.close() }
        probe.settle(0.8)
        let before = SwiftUIMotionProbe.light(probe.snapshot())
        let coming = probe.frames(after: {
            _ = try? store.openReview(paneId: surface.id, taskName: "fade", projectPath: NSTemporaryDirectory(), baseBranch: "main")
        }, for: 0.5, measure: SwiftUIMotionProbe.light)
        #expect(store.hasSession(paneId: surface.id))
        try expectAnimated(coming, from: before, "a diff review coming in")
        let shown = try #require(coming.last).value
        let commented = probe.frames(after: {
            _ = try? store.addComment(paneId: surface.id, file: "a.swift", line: 1, text: "a note")
        }, for: 0.3, measure: SwiftUIMotionProbe.light)
        let end = try #require(commented.last).value
        let span = max(abs(end - shown), 1)
        #expect(!commented.dropFirst().contains { abs($0.value - shown) > span * 0.1 && abs($0.value - end) > span * 0.1 },
                "a comment faded the review instead of redrawing it")
    }

    final class Toggle: ObservableObject { @Published var on = false }
    struct Control: View {
        @ObservedObject var toggle: Toggle
        var body: some View {
            if toggle.on {
                Rectangle().fill(Color.white).frame(height: 30).transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    /// The probe sees motion: an insertion made inside withAnimation has frames in between, one made outside none.
    @Test func theProbeSeesAnAnimatedInsertionAndAnInstantOne() throws {
        let toggle = Toggle()
        let probe = SwiftUIMotionProbe(Control(toggle: toggle), size: CGSize(width: 360, height: 60))
        defer { probe.close() }
        let coming = probe.frames(after: { withAnimation(.easeInOut(duration: 0.15)) { toggle.on = true } }, for: 0.5,
                                  measure: SwiftUIMotionProbe.light)
        try expectAnimated(coming, from: 0, "the control coming in")
        let full = try #require(coming.last).value
        let going = probe.frames(after: { toggle.on = false }, for: 0.2, measure: SwiftUIMotionProbe.light)
        #expect(!going.contains { $0.value > full * 0.1 && $0.value < full * 0.9 }, "an unanimated change has no frame in between")
    }
}
