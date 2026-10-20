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

/// A session row's states that stand still (4a): the active session's fill
/// and its Ember bar at the sidebar's edge, a waiting session's question in
/// Claw, the unread dot.
@Suite(.serialized) @MainActor
struct MotionSidebarLookTests {
    private static let size = CGSize(width: 280, height: 52)

    private func snapshot(_ item: SessionSidebarItem) -> WindowSnapshot {
        let row = SessionSidebarRowView(item: item, index: 0, selectedIndex: -1, targetWindow: nil,
                                        editingItemId: .constant(nil), editingDescriptionText: .constant(""),
                                        isPresented: .constant(true), now: nil, reduceMotion: true, onSelect: {})
        return WindowSnapshot(ZStack(alignment: .topLeading) {
            Color.black
            row.frame(width: Self.size.width)
        }, size: Self.size)
    }

    private func item(status: Tako.PaneStatus = .idle, selected: Bool = false, unread: Int = 0,
                      notification: String? = nil) -> SessionSidebarItem {
        SessionSidebarItem(id: "look", index: 0, isSelected: selected, title: "psql", status: status,
                           workingDirectory: "/tmp", latestNotification: notification, unreadCount: unread,
                           indentationLevel: 1, workspaceId: UUID(), tabId: "look-tab")
    }

    /// Ember pixels in the sidebar's first `width` points, top to bottom.
    private func edgeBar(_ frame: WindowSnapshot, width: CGFloat) -> [CGPoint] {
        frame.weighed(in: CGRect(x: 0, y: 0, width: width, height: Self.size.height), Weights.near(MotionSpec.ember))
            .filter { $0.w > 0.5 }.map(\.p)
    }

    @Test func theActiveSessionIsFilledAndMarkedByAnEmberBarAtTheSidebarsEdge() throws {
        let frame = snapshot(item(selected: true))
        let bar = edgeBar(frame, width: 4)
        let xs = bar.map(\.x), ys = bar.map(\.y)
        let minX = try #require(xs.min()), maxX = try #require(xs.max())
        #expect(minX < 0.6 && maxX < 2.1, "the bar spans x \(minX)...\(maxX), not the sidebar's first 2 pt")
        let height = (ys.max() ?? 0) - (ys.min() ?? 0)
        #expect(height > 10, "the bar is \(height) pt tall")
        let fill = frame.sample(CGPoint(x: 250, y: Self.size.height / 2))
        let active = NSColor.spec(0x241C16)
        #expect(abs(fill.r - active.redComponent) < 0.03 && abs(fill.g - active.greenComponent) < 0.03,
                "the active row's fill is \(fill), not #241C16")
    }

    @Test func anotherSessionHasNoBar() {
        #expect(edgeBar(snapshot(item(selected: false)), width: 4).isEmpty)
    }

    @Test func aWaitingSessionAsksItsQuestionInClaw() {
        let question = "Allow cargo test --package auth?"
        // The second line's text alone, clear of the row's edges: a waiting
        // row's border is Claw too, and it was the border that a test of
        // the whole lower half saw.
        let text = CGRect(x: 40, y: 6, width: 200, height: Self.size.height / 2 - 8)
        let claw = { (f: WindowSnapshot) in f.mass(in: text, Weights.near(MotionSpec.claw)) }
        let waiting = claw(snapshot(item(status: .needsApproval, notification: question)))
        let idle = claw(snapshot(item(status: .idle, notification: question)))
        #expect(waiting > 3, "no Claw text on the second line: \(waiting)")
        #expect(idle < 0.5, "an idle row's second line is Claw: \(idle)")
    }

    @Test func anUnreadSessionHasAClawDotOfFivePoints() {
        let upperRight = CGRect(x: 200, y: Self.size.height / 2, width: 80, height: Self.size.height / 2)
        let dot = snapshot(item(unread: 1)).mass(in: upperRight, Weights.near(MotionSpec.claw))
        let none = snapshot(item(unread: 0)).mass(in: upperRight, Weights.near(MotionSpec.claw))
        #expect(abs(dot - .pi * 2.5 * 2.5) < 8, "the dot covers \(dot) pt², not a 5 pt disc")
        #expect(none < 0.5)
    }
}
