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

/// The sidebar's rows hold the frozen desktop reference (A01): a session row
/// is 46 pt, a pane row 23 pt, each with a 1 pt margin above and below, in
/// every state. A working row once grew by its border's 1 pt, so the list
/// jumped as tabs started and finished.
@Suite(.serialized) @MainActor
struct SidebarRowReferenceTests {
    private func height(_ item: SessionSidebarItem) -> CGFloat {
        let view = SessionSidebarRowView(item: item, index: 0, selectedIndex: -1, targetWindow: nil,
                                         editingItemId: .constant(nil), editingDescriptionText: .constant(""),
                                         isPresented: .constant(true), now: Date(timeIntervalSinceReferenceDate: 1),
                                         reduceMotion: true, onSelect: {})
        let hosting = NSHostingView(rootView: view.frame(width: 248))
        return hosting.fittingSize.height
    }

    private static let states: [Tako.SurfaceState] = [.idle, .working, .progress(0.4), .waiting, .done, .failed, .offline]

    @Test func aSessionRowIs46ptInEveryState() {
        for state in Self.states {
            let item = MotionSurfaceHarness.item(state, isChild: false, pulses: 0)
            #expect(abs(height(item) - (46 + 2)) < 0.01, "\(state): \(height(item))")
        }
    }

    @Test func aPaneRowIs23pt() {
        let item = SessionSidebarItem(id: "pane-row", index: 0, isSelected: false, title: "zsh", status: .idle,
                                      workingDirectory: nil, isChild: true, parentId: UUID(),
                                      indentationLevel: 2, workspaceId: UUID(), tabId: "pane-tab")
        #expect(abs(height(item) - (23 + 2)) < 0.01, "\(height(item))")
    }
}
