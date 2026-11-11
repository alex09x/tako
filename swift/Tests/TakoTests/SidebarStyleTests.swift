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

    @Test func textSizeAndSecondLineAreSettingsThatLeaveTodayAlone() {
        #expect(prefs([:]).sidebarTextSize == .standard && prefs([:]).sidebarSecondaryText == .standard)
        #expect(prefs(["sidebar-text-size": "large", "sidebar-secondary-text": "strong"]).sidebarTextSize == .large)
        #expect(prefs(["sidebar-secondary-text": "soft"]).sidebarSecondaryText == .soft)
        #expect(prefs(["sidebar-text-size": "huge"]).sidebarTextSize == .standard)
        #expect(SidebarSecondaryText.standard.color == Tako.LivingTokens.dim, "default is today's dim second line")
        let one = SidebarRowMetrics.of(.classic, textScale: 1), large = SidebarRowMetrics.of(.classic, textScale: 1.15)
        #expect(one.titleFont.pointSize == 12.5 && one.titleHeight == 18)
        #expect(large.titleFont.pointSize > 12.5 && large.titleHeight > 18 && large.gap == 7)
        #expect(SidebarRowMetrics.of(.compact, textScale: 0.9).metaFont.pointSize < 10)
    }

    private func group(_ name: String, color: String?, _ items: [SessionSidebarItem]) -> SessionSidebarWorkspaceGroup {
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
        #expect(buckets[3].rows.map(\.workspace?.color) == ["#8ABEB7", nil], "the dot is the session's, not the pane's")
        #expect(buckets[3].rows.map { $0.workspace?.name } == ["Default", nil])
        #expect(SidebarStatusBucket.buckets(from: []).isEmpty)
    }

    private func row(_ id: String, _ status: Tako.PaneStatus, attention: Bool) -> SessionSidebarItem {
        SessionSidebarItem(id: id, index: 0, isSelected: false, title: id, status: status, workingDirectory: "/tmp",
                           needsAttention: attention, indentationLevel: 1, workspaceId: UUID(), tabId: id)
    }

    /// An unread done or running session stays Done or Running: the bucket
    /// is the state its ring shows. Only an idle one somebody has to look at
    /// is waiting, and so Needs you.
    @Test func unreadDoesNotPullDoneOrRunningIntoNeedsYou() {
        let buckets = SidebarStatusBucket.buckets(from: [group("W", color: nil, [
            row("done", .done, attention: true), row("running", .working, attention: true),
            row("looked-for", .idle, attention: true), row("quiet", .idle, attention: false),
        ])])
        #expect(buckets.map(\.kind) == [.needsYou, .running, .done, .quiet])
        #expect(buckets.map { $0.rows.map(\.item.id) } == [["looked-for"], ["running"], ["done"], ["quiet"]])
        // A workspace with the automatic colour still names and badges its sessions.
        #expect(buckets.allSatisfy { $0.rows.allSatisfy { $0.workspace?.name == "W" && $0.workspace?.color == nil } })
    }

    /// The sidebar's list is rebuilt whenever its look changes (the lazy stack
    /// kept rows it had built with the old style and no workspace badge).
    @Test func everySettingOfTheLookChangesTheListsIdentity() {
        let base = prefs([:]).sidebarLook
        for (key, value) in [("sidebar-style", "minimal"), ("sidebar-group", "status"),
                             ("sidebar-text-size", "large"), ("sidebar-secondary-text", "soft")] {
            #expect(prefs([key: value]).sidebarLook != base, "\(key)")
        }
        #expect(prefs(["sidebar-count-done": "false"]).sidebarLook == base, "a counter is not part of the rows' look")
    }

    /// Needs you chosen in Classic, then Minimal or Status grouping hides the
    /// segments: the filter goes with them (nothing on screen would say the
    /// list is filtered), the text search stays. Classic keeps both.
    @Test func hidingTheSegmentsClearsTheirNeedsYouFilterButNotTheSearch() {
        let store = SessionSidebarStore.shared
        defer { store.setFilterNeedsAttention(false, for: nil); store.setFilterText("", for: nil) }
        for change in [["sidebar-style": "minimal"], ["sidebar-group": "status"]] {
            store.setFilterNeedsAttention(true, for: nil)
            store.setFilterText("deploy", for: nil)
            store.dropHiddenAttentionFilter(prefs([:]), for: nil)
            #expect(store.filterNeedsAttention(for: nil), "Classic shows the segments: the filter stays")
            store.dropHiddenAttentionFilter(prefs(change), for: nil)
            #expect(!store.filterNeedsAttention(for: nil), "\(change): the hidden filter is cleared")
            #expect(store.filterText(for: nil) == "deploy", "the text search stays")
        }
    }

    @Test func minimalAndCompactDrawTheirRingsAndPaneRowsAsDesigned() {
        let c = SidebarRowMetrics.of(.classic), mi = SidebarRowMetrics.of(.minimal), co = SidebarRowMetrics.of(.compact)
        #expect(c.ringScale == 1 && c.showsChildTag && c.childRadius == 6, "Classic is the reference")
        #expect(mi.ringScale == 0.78 && !mi.showsChildTag)
        #expect(co.ringScale == 0.8 && co.childRadius == 4)
        #expect(SidebarRowMetrics.of(.minimal, textScale: 1.15).ringScale == 0.78, "a text size keeps the style's ring")
        // The direct status layer draws the ring at that scale about its centre, its place unchanged.
        let layer = Tako.TabStatusLayer()
        layer.geometry = .init(cornerRadius: 8, ringOrigin: CGPoint(x: 20, y: 10), ringScale: 0.8)
        layer.apply(state: .working, in: CGRect(x: 0, y: 0, width: 220, height: 46), hideRing: false, reduceMotion: true,
                    paused: true, pulses: 0, palette: nil)
        #expect(layer.ringContainer.frame == CGRect(x: 20, y: 10, width: 14, height: 14))
        #expect(CATransform3DEqualToTransform(layer.ringContainer.sublayerTransform, CATransform3DMakeScale(0.8, 0.8, 1)))
        layer.geometry.ringScale = 1
        layer.apply(state: .working, in: CGRect(x: 0, y: 0, width: 220, height: 46), hideRing: false, reduceMotion: true,
                    paused: true, pulses: 0, palette: nil)
        #expect(CATransform3DIsIdentity(layer.ringContainer.sublayerTransform))
    }

    @Test func theStyleShapesTheWholeSidebarAndClassicStaysTheReference() {
        let c = SidebarChromeMetrics.of(.classic)
        #expect(c.searchHeight == 28 && c.searchFilled && c.headingUppercased && c.headingTop == 10)
        #expect(c.rowRadius == 8 && c.rowLeading == 4 && c.rowTrailing == 6)
        #expect(!SidebarChromeMetrics.of(.minimal).searchFilled && !SidebarChromeMetrics.of(.minimal).headingUppercased)
        #expect(SidebarChromeMetrics.of(.compact).searchHeight == 24 && SidebarChromeMetrics.of(.compact).rowRadius == 4)
        #expect(SidebarChromeMetrics.showsSegments(style: .classic, grouping: .workspace))
        #expect(SidebarChromeMetrics.showsSegments(style: .compact, grouping: .workspace))
        #expect(!SidebarChromeMetrics.showsSegments(style: .minimal, grouping: .workspace))
        #expect(!SidebarChromeMetrics.showsSegments(style: .classic, grouping: .status))
    }
}
