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

/// The sidebar styles the user chooses (`sidebar-style`, `sidebar-group`):
/// Classic is the reference unchanged; Minimal and Compact take room out;
/// grouping by status puts what needs you first and keeps pane rows with
/// their session.
@Suite(.serialized) @MainActor
struct SidebarStyleTests {
    private func prefs(_ text: [String: String]) -> DesktopPreferences { DesktopPreferences { text[$0] } }

    @Test func theSettingsReadTheirKeysAndFallBackToToday() {
        #expect(prefs([:]).sidebarStyle == .classic)
        #expect(prefs([:]).sidebarGrouping == .workspace)
        #expect(prefs(["sidebar-style": " Minimal ", "sidebar-group": "status"]).sidebarStyle == .minimal)
        #expect(prefs(["sidebar-group": "status"]).sidebarGrouping == .status)
        #expect(prefs(["sidebar-style": "tabs"]).sidebarStyle == .classic, "a style that does not exist reads as Classic")
        #expect(TerminalSettingRegistry.setting(for: "sidebar-style") != nil)
        #expect(TerminalSettingRegistry.setting(for: "sidebar-group") != nil)
    }

    @Test func classicKeepsTheReferenceMetrics() {
        let m = SidebarRowMetrics.of(.classic)
        #expect(m.titleFont.pointSize == 12.5 && m.metaFont.pointSize == 11 && m.childFont.pointSize == 11.5)
        #expect(m.gap == 7 && m.secondLineIndent == 33 && m.rowVerticalPadding == 6 && m.childIndent == 40)
        #expect(m.showsTreeLines && !m.inlineSecondLine)
        for state: Tako.SurfaceState in [.idle, .working, .waiting, .done, .failed, .offline] {
            #expect(m.showsSecondLine(for: state))
        }
    }

    private func height(_ state: Tako.SurfaceState, _ style: SidebarStyle) -> CGFloat {
        let view = SessionSidebarRowView(item: MotionSurfaceHarness.item(state, isChild: false, pulses: 0), index: 0,
                                         selectedIndex: -1, targetWindow: nil, editingItemId: .constant(nil),
                                         editingDescriptionText: .constant(""), isPresented: .constant(true),
                                         now: Date(timeIntervalSinceReferenceDate: 1), reduceMotion: true, onSelect: {},
                                         style: style)
        return NSHostingView(rootView: view.frame(width: 248)).fittingSize.height
    }

    @Test func minimalAndCompactTakeRoomOutAndSayWhatNeedsYou() {
        let classic = height(.idle, .classic), minimal = height(.idle, .minimal), compact = height(.idle, .compact)
        #expect(abs(classic - 48) < 0.01, "classic stays the reference 46 + 2")
        #expect(minimal < classic, "a quiet minimal row is one line: \(minimal)")
        #expect(compact < minimal, "a compact row is the smallest: \(compact)")
        #expect(height(.waiting, .minimal) > minimal, "a waiting session shows its question in minimal")
        #expect(abs(height(.waiting, .compact) - compact) < 0.01, "compact keeps one line, the question on the right")
    }

    private func group(_ name: String, color: String, _ items: [SessionSidebarItem]) -> SessionSidebarWorkspaceGroup {
        SessionSidebarWorkspaceGroup(id: UUID(), name: name, color: color, icon: nil, isActive: false, isCollapsed: false,
                                     sessionCount: items.filter { !$0.isChild }.count, paneCount: 0, attentionCount: 0,
                                     unreadCount: 0, dominantStatus: .idle, items: items)
    }

    @Test func groupingByStatusPutsWhatNeedsYouFirstAndKeepsPanesWithTheirSession() {
        let h = MotionSurfaceHarness.self
        let quiet = h.item(.idle, isChild: false, pulses: 0), pane = h.item(.working, isChild: true, pulses: 0)
        let waiting = h.item(.waiting, isChild: false, pulses: 0), running = h.item(.working, isChild: false, pulses: 0)
        let failed = h.item(.failed, isChild: false, pulses: 0), done = h.item(.done, isChild: false, pulses: 0)
        let buckets = SidebarStatusBucket.buckets(from: [
            group("Default", color: "#8ABEB7", [quiet, pane, running]),
            group("Infra", color: "#F0C674", [done, failed, waiting]),
        ])
        #expect(buckets.map(\.kind) == [.needsYou, .running, .done, .quiet])
        #expect(buckets[0].rows.map(\.item.surfaceState) == [.failed, .waiting])
        #expect(buckets[3].rows.map(\.item.isChild) == [false, true], "a working pane stays under its quiet session")
        #expect(buckets[3].sessionCount == 1)
        #expect(buckets[3].rows.map(\.workspaceColor) == ["#8ABEB7", nil], "the dot is the session's, not the pane's")
        #expect(SidebarStatusBucket.buckets(from: []).isEmpty)
    }
}
