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

/// Grouped by status the sidebar reorders by itself. The arrow-key cursor,
/// and so Return, stays on the row it was on, not on its old position.
@Suite(.serialized) @MainActor
struct SidebarCursorKeeperTests {
    final class Model: ObservableObject {
        @Published var ids: [String]
        @Published var active: String?
        @Published var selected = 0
        var followed = 0
        init(_ ids: [String], active: String?) { self.ids = ids; self.active = active }
    }

    struct Harness: View {
        @ObservedObject var model: Model
        var body: some View {
            Color.clear.frame(width: 10, height: 10)
                .modifier(SidebarCursorKeeper(ids: model.ids, activeId: model.active, enabled: true,
                                              selectedIndex: $model.selected, followActive: { model.followed += 1 }))
        }
    }

    private func settle(_ view: NSView) {
        for _ in 0..<5 {
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    @Test func theCursorStaysOnItsRowWhenStatusReordersTheList() {
        // Source order A, B, C; A waiting, B running, C waiting: shown A, C, B.
        let model = Model(["A", "C", "B"], active: "A")
        let host = NSHostingView(rootView: Harness(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        settle(host)

        model.selected = 2          // arrow down twice: B
        settle(host)
        model.ids = ["A", "B", "C"] // C starts running and leaves Needs you
        settle(host)
        #expect(model.selected == 1, "the cursor (and Return) is still on B")
        #expect(model.ids[model.selected] == "B")
        #expect(model.followed == 0, "the active tab did not change, so the cursor does not jump to it")

        model.ids = ["A", "C"]      // B closes: the cursor stays in place, within the list
        settle(host)
        #expect(model.selected == 1)

        model.active = "C"          // a new active tab: the cursor goes with it
        settle(host)
        #expect(model.followed == 1)
    }
}
