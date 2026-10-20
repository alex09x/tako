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

/// One state per surface (1b «приоритет»: офлайн > ошибка > ждёт тебя >
/// работает > прогресс > готово > живёт > покой): a tab of two panes shows
/// the one ranked first, for every pair of states.
@Suite(.serialized) @MainActor
struct MotionPriorityTests {
    struct Pair: CustomTestStringConvertible, Sendable {
        let a: Tako.SurfaceState
        let b: Tako.SurfaceState
        var testDescription: String { "\(a.specName) + \(b.specName)" }
    }

    static let pairs: [Pair] = MotionSpec.states.flatMap { a in MotionSpec.states.map { Pair(a: a, b: $0) } }

    /// Two panes for every case: each surface starts a shell, and a pair for
    /// each of the 81 cases had the test Mac running 162 of them, slowing the
    /// suites after it past their own timeouts.
    private static var pool: [Tako.SurfaceView] = []

    /// A pane of the pool -- the `index`th -- in `state`, set as the app sets
    /// it: an agent's status, a progress report, a quiet program's output.
    static func pane(_ state: Tako.SurfaceState, _ index: Int = 0) -> Tako.SurfaceView {
        while pool.count <= index { pool.append(Tako.SurfaceView(frame: .zero)) }
        let surface = pool[index]
        surface.removeFromSuperview()
        let crab = surface.crab
        // Back to rest: no status, no report, no program running.
        crab.clearStatus()
        crab.progressReported(state: 0, value: nil)
        crab.commandEnded(exitCode: nil)
        switch state {
        case .idle: break
        case .working: crab.setStatus(.working, text: nil)
        case .progress(let p): crab.setStatus(.working, text: nil); crab.progressReported(state: 1, value: UInt8(p * 100))
        case .waiting: crab.setStatus(.needsApproval, text: nil)
        case .done: crab.setStatus(.done, text: nil)
        case .failed: crab.setStatus(.error, text: nil)
        case .offline: crab.setStatus(.disconnected, text: nil)
        case .live(let flowing):
            crab.commandStarted(kind: .quiet, probe: Tako.LiveProbe(takeOutputLines: { flowing ? 5 : 0 }, program: "tail"))
            if flowing { crab.sampleLive() }
        }
        return surface
    }

    /// The state the spec ranks first; of two live panes, the one whose output arrives.
    static func first(_ a: Tako.SurfaceState, _ b: Tako.SurfaceState) -> Tako.SurfaceState {
        if a.priority != b.priority { return a.priority > b.priority ? a : b }
        if case .live = a, case .live = b { return .live(flowing: a == .live(flowing: true) || b == .live(flowing: true)) }
        return a
    }

    @Test func theRanksAreTheSpecsOrder() {
        let ranks = MotionSpec.priorityOrder.map(\.priority)
        #expect(ranks == ranks.sorted(by: >) && Set(ranks).count == ranks.count, "\(ranks)")
    }

    @Test(arguments: pairs)
    func aTabOfTwoPanesShowsTheOneRankedFirst(_ pair: Pair) {
        _ = NSApplication.shared
        let a = Self.pane(pair.a, 0), b = Self.pane(pair.b, 1)
        let window = makeWindow(title: "pair")
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        content.addSubview(a)
        content.addSubview(b)
        window.contentView = content
        defer { window.close() }
        let shown = Tako.TabBarView(frame: .zero).pillSurfaceState(for: window)
        #expect(shown == Self.first(pair.a, pair.b), "shows \(shown.specName)")
    }
}

/// The sidebar ranks a session's panes as the tab bar does.
@Suite(.serialized) @MainActor
struct MotionSidebarPriorityTests {
    @Test(arguments: [(Tako.SurfaceState.working, Tako.SurfaceState.progress(0.4)), (.progress(0.4), .working),
                      (.progress(0.4), .idle), (.done, .progress(0.4))])
    func aSessionRowOfTwoPanesShowsTheOneRankedFirst(_ pair: (Tako.SurfaceState, Tako.SurfaceState)) {
        _ = NSApplication.shared
        let a = MotionPriorityTests.pane(pair.0, 0), b = MotionPriorityTests.pane(pair.1, 1)
        let window = makeWindow(title: "pair")
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        content.addSubview(a)
        content.addSubview(b)
        window.contentView = content
        defer { window.close() }
        let progress = Tako.aggregateProgress(for: window)
        let crab = Tako.aggregateCrab(for: window)
        let item = SessionSidebarItem(id: "pair", index: 0, isSelected: false, title: "pair",
                                      status: crab?.paneStatus ?? .idle, crabState: crab?.state ?? .idle,
                                      progress: progress?.progress.map { Double($0) / 100 }, progressState: progress?.state ?? .none)
        #expect(item.surfaceState == MotionPriorityTests.first(pair.0, pair.1), "shows \(item.surfaceState.specName)")
    }
}
