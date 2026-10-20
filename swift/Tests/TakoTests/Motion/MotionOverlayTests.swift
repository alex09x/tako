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
        #expect(frames.filter { $0.t > 0.3 }.allSatisfy { abs($0.value - end) < span * 0.05 }, "\(what) still moving after 0.3 s")
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

    @Test func aFileOverlayFadesInOverThePaneAndOut() throws {
        _ = NSApplication.shared
        let surface = Tako.SurfaceView(frame: .zero)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tako-fade-\(UUID().uuidString).txt")
        try String(repeating: "an overlay over the pane fades in and out\n", count: 40).write(to: file, atomically: true, encoding: .utf8)
        defer {
            _ = OverlayStore.shared.closeOverlay(paneId: surface.id)
            try? FileManager.default.removeItem(at: file)
        }
        let probe = SwiftUIMotionProbe(Tako.InspectableSurface(surfaceView: surface), size: CGSize(width: 240, height: 140))
        defer { probe.close() }
        probe.settle(0.8)
        let before = SwiftUIMotionProbe.light(probe.snapshot())
        var opened: Error?
        let coming = probe.frames(after: {
            do {
                _ = try OverlayStore.shared.openOverlay(paneId: surface.id, path: file.path,
                                                        surfacePwd: file.deletingLastPathComponent().path)
            } catch { opened = error }
        }, for: 0.5,
                                  measure: SwiftUIMotionProbe.light)
        #expect(opened == nil, "\(String(describing: opened))")
        #expect(OverlayStore.shared.overlay(for: surface.id) != nil)
        try expectAnimated(coming, from: before, "a file overlay coming in")
        let shown = try #require(coming.last).value
        let going = probe.frames(after: { _ = OverlayStore.shared.closeOverlay(paneId: surface.id) }, for: 0.5,
                                 measure: SwiftUIMotionProbe.light)
        try expectAnimated(going, from: shown, "a file overlay going")
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
