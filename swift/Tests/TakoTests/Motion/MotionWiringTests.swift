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

/// What drives the status layers from outside them: the tab bar handing a
/// pill's layer its bursts, the sidebar pausing its rows and its header
/// ring, the header ring moving only while something waits, the tab numbers
/// under ⌘.
@Suite(.serialized) @MainActor
struct MotionWiringTests {
    private func hosts(in view: NSView) -> [StatusLayerHostView] {
        view.subviews.flatMap { ($0 as? StatusLayerHostView).map { [$0] } ?? hosts(in: $0) }
    }

    @Test func theTabBarHandsAPillsLayerEachNewBurst() throws {
        _ = NSApplication.shared
        var lines = 0
        let surface = Tako.SurfaceView(frame: .zero)
        surface.crab.commandStarted(kind: .quiet, probe: Tako.LiveProbe(
            takeOutputLines: { defer { lines = 0 }; return lines }, program: "tail"))
        defer { surface.crab.commandEnded(exitCode: nil) }
        let window = makeWindow(title: "live")
        window.contentView = surface
        defer { window.close() }
        let bar = Tako.TabBarView(frame: NSRect(x: 0, y: 0, width: 520, height: 38))
        let rect = CGRect(x: 0, y: 5, width: 140, height: 28)
        let draw = { bar.updateStatusLayer(for: window, rect: rect, state: bar.pillSurfaceState(for: window), hideRing: false) }

        lines = 5
        surface.crab.sampleLive()
        draw()
        let layer = try #require(bar.statusLayers[ObjectIdentifier(window)])
        let ripple = try #require(layer.ringContainer.sublayers?.first { $0.name == "liveRipple" })
        ripple.removeAllAnimations()
        guard !LivingAnimationState.shared.isTimelinePaused else { return }

        draw()
        #expect(ripple.animation(forKey: "liveRipple") == nil, "a redraw with no new burst rippled")
        lines = 5
        surface.crab.sampleLive()
        draw()
        #expect(ripple.animation(forKey: "liveRipple") != nil, "a new burst did not reach the pill")
    }

    @Test(arguments: [false, true])
    func aSidebarRowStandsStillWhileTheSidebarIsHidden(_ paused: Bool) throws {
        let row = SessionSidebarRowView(item: MotionSurfaceHarness.item(.working, isChild: false, pulses: 0), index: 0,
                                        selectedIndex: -1, targetWindow: nil, editingItemId: .constant(nil),
                                        editingDescriptionText: .constant(""), isPresented: .constant(true), now: nil,
                                        reduceMotion: false, motionPaused: paused, onSelect: {})
        let view = NSHostingView(rootView: row.frame(width: 280))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        TerminalTestSupport.waitUntil(timeout: 1) { hosts(in: view).first?.statusLayer.currentState == .working }
        let layer = try #require(hosts(in: view).first?.statusLayer)
        #expect(layer.speed == (paused ? 0 : 1), "speed \(layer.speed) with the sidebar \(paused ? "hidden" : "shown")")
    }

    /// The header's "Needs you" ring (4a) pulses while something waits for
    /// you and rests when nothing does; hidden, it stands still.
    @Test func theNeedsYouRingPulsesOnlyWhileSomethingWaits() throws {
        _ = NSApplication.shared
        let suite = "test.tako.motion.header.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tako-motion-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspaces = WorkspaceStore(storeURL: dir.appendingPathComponent("workspaces.json"), isTesting: true)
        workspaces.resetForTesting()
        let store = SessionSidebarStore(defaults: defaults)

        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        surface.title = "agent"
        let controller = BaseTerminalController(Tako.App(), surfaceTree: SplitTree(view: surface))
        let tab = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                           backing: .buffered, defer: false)
        tab.isReleasedWhenClosed = false
        tab.windowController = controller
        controller.window = tab
        tab.contentView = surface
        defer { tab.close() }

        var presented = true
        let shown = Binding(get: { presented }, set: { presented = $0 })
        let sidebar = NSHostingView(rootView: SessionSidebarView(isPresented: shown, containingWindow: tab,
                                                                 store: store, workspaceStore: workspaces))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        defer { window.close() }

        // The header's ring is the one drawn small: 11 pt of a 14 pt ring.
        let header = { () -> Tako.TabStatusLayer? in
            hosts(in: sidebar).map(\.statusLayer).first { abs($0.transform.m11 - StatusRingSize.extraSmall.rawValue / 14) < 0.01 }
        }
        TerminalTestSupport.waitUntil(timeout: 1) { header() != nil }
        let resting = try #require(header())
        #expect(StatusLayerInventory.effects(of: resting) == [.ring(.waiting), .blink(moving: false)],
                "nothing waits, yet: \(StatusLayerInventory.effects(of: resting))")

        surface.crab.setStatus(.needsApproval, text: nil)
        TerminalTestSupport.waitUntil(timeout: 2) {
            header().map { StatusLayerInventory.effects(of: $0).contains(.halo) } ?? false
        }
        let moving = try #require(header())
        #expect(StatusLayerInventory.effects(of: moving) == [.ring(.waiting), .blink(moving: true), .halo])
    }

    /// Terminal UI: the tab numbers show only while ⌘ is held, after 150 ms.
    @Test func theTabNumbersShowAfterCommandIsHeld150ms() async throws {
        _ = NSApplication.shared
        let a = makeWindow(title: "a"), b = makeWindow(title: "b")
        Tako.CustomTabGroup.join(b, to: a, select: false)
        defer {
            Tako.CustomTabGroup.leave(b)
            a.close()
            b.close()
        }
        let bar = Tako.TabBarView(frame: NSRect(x: 0, y: 0, width: 520, height: 38))
        a.contentView?.addSubview(bar)
        try #require(bar.windows.count > 1, "the bar sees \(bar.windows.count) tab(s)")
        #expect(Tako.TabBarView.commandBadgeDelay == 0.15)
        bar.commandKeyChanged(held: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!bar.showingBadges, "the numbers showed before 150 ms")
        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(bar.showingBadges, "the numbers did not show after 150 ms")
        bar.commandKeyChanged(held: false)
        #expect(!bar.showingBadges, "the numbers stayed after ⌘ was let go")
    }
}
