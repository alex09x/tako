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

/// What the motion costs the main thread (1b «производительность»: only Core
/// Animation, nothing redrawn per frame). A SwiftUI clock in a sidebar row
/// laid the whole window out on every frame: one working row kept a third
/// of a core busy and a few stalled every row for 75-140 ms.
@Suite(.serialized) @MainActor
struct MotionCostTests {
    final class CountingHost<Content: View>: NSHostingView<Content> {
        var layouts = 0
        override func layout() {
            layouts += 1
            super.layout()
        }
    }

    /// Layout passes of `view`, on screen, over `seconds` after it settled.
    private func layouts<V: View>(of view: V, size: CGSize, over seconds: TimeInterval = 0.6) -> Int {
        let host = CountingHost(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 40, y: 40), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        TerminalTestSupport.waitUntil(timeout: 0.3) { false }
        host.layouts = 0
        TerminalTestSupport.waitUntil(timeout: seconds) { false }
        return host.layouts
    }

    private func row(_ state: Tako.SurfaceState, child: Bool = false) -> some View {
        SessionSidebarRowView(item: MotionSurfaceHarness.item(state, isChild: child, pulses: 0), index: 0, selectedIndex: -1,
                              targetWindow: nil, editingItemId: .constant(nil), editingDescriptionText: .constant(""),
                              isPresented: .constant(true), now: nil, reduceMotion: false, onSelect: {})
            .frame(width: 280)
    }

    /// The measure itself: a ring on a SwiftUI clock, as rows had it, lays
    /// its view out frame after frame here. Without this the next test
    /// could pass on a window that never drew.
    @Test func aRingOnASwiftUIClockLaysItsViewOutEveryFrame() {
        let clocked = TimelineView(.animation) { context in
            StatusRingView(state: .working, size: .small, now: context.date, elapsedInState: 1, reduceMotion: false)
                .frame(width: CGFloat(14 + Int(context.date.timeIntervalSinceReferenceDate * 60) % 2))
        }
        let count = layouts(of: clocked, size: CGSize(width: 60, height: 30))
        #expect(count > 10, "a running clock gave \(count) layouts in 0.6 s: the window is not drawing")
    }

    @Test func movingSidebarRowsLayNothingOutWhileTheyMove() {
        let rows = VStack(spacing: 0) {
            row(.working)
            row(.waiting)
            row(.progress(0.4))
            row(.live(flowing: true))
            row(.working, child: true)
            row(.waiting, child: true)
        }
        let count = layouts(of: rows, size: CGSize(width: 280, height: 320))
        #expect(count <= 2, "six moving rows laid out \(count) times in 0.6 s")
    }
}
