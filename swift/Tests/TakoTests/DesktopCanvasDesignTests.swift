/*
 * tako — Desktop canvas modes, migration, counts and status policy tests
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation
import Testing
@testable import Tako

@Suite
@MainActor
struct DesktopCanvasDesignTests {
    private let area = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let a = UUID(), b = UUID(), c = UUID()
    private var tree: CanvasTileNode<UUID> {
        .split(horizontal: true, ratio: 0.5, left: .leaf(a),
               right: .split(horizontal: false, ratio: 0.5, left: .leaf(b), right: .leaf(c)))
    }

    @Test func referenceMetricsAndSavedSidebarWidth() {
        #expect(DesktopCanvasMetrics.sidebarWidth(saved: nil) == 248)
        #expect(DesktopCanvasMetrics.sidebarWidth(saved: 310) == 310)
        #expect(DesktopCanvasMetrics.sessionRowHeight == 46)
        #expect(DesktopCanvasMetrics.childRowHeight == 23)
        #expect(DesktopCanvasMetrics.paneHeaderHeight == 28)
        #expect(DesktopCanvasMetrics.paneGap == 8 && DesktopCanvasMetrics.paneRadius == 10)
        #expect(DesktopCanvasMetrics.shelfHeight == 30)
        #expect(DesktopCanvasMetrics.minimumHitTarget >= DesktopCanvasMetrics.controlSize)
    }

    @Test func tileFloatReturnPreservesPreferredRectangle() {
        var pane = CanvasPanePresentation(surfaceId: a)
        let custom = CGRect(x: 40, y: 50, width: 400, height: 300)
        pane.detach(defaultRect: custom)
        #expect(pane.mode == .floating)
        pane.preferredRect = CGRect(x: 70, y: 80, width: 420, height: 310)
        pane.returnToGrid()
        #expect(pane.mode == .tiled)
        pane.detach(defaultRect: custom)
        #expect(pane.preferredRect == CGRect(x: 70, y: 80, width: 420, height: 310))
        pane.maximize(); pane.restore()
        #expect(pane.mode == .floating)
        pane.returnToGrid(); pane.maximize(); pane.minimize(); pane.restore()
        #expect(pane.mode == .maximized)
        pane.restore()
        #expect(pane.mode == .tiled)
    }

    @Test func mixedModesExcludeFloatingAndMinimizedFromTiling() {
        let float = CGRect(x: 100, y: 100, width: 300, height: 200)
        let panes: [UUID: CanvasPanePresentation] = [
            a: .init(surfaceId: a),
            b: .init(surfaceId: b, mode: .floating, restoreMode: .floating, preferredRect: float),
            c: .init(surfaceId: c, mode: .minimized),
        ]
        let original = tree
        let frames = DesktopCanvasLayout.frames(tree: tree, panes: panes, in: area)
        #expect(frames[a] == area) // sole tiled pane takes the full grid
        #expect(frames[b] == float)
        #expect(frames[c] == nil)
        #expect(tree == original) // allocation never mutates the split tree

        let all = DesktopCanvasLayout.frames(tree: tree, panes: [:], in: area)
        #expect(all[a]?.width == 496)
        #expect(all[b]!.minX - all[a]!.maxX == 8)
        #expect(all[c]!.minY - all[b]!.maxY == 8)
    }

    /// `area` is the grid, already inset: a maximized pane takes all of it, as a sole tiled pane does.
    @Test func soleMaximizedPaneTakesTheWholeGrid() {
        let panes: [UUID: CanvasPanePresentation] = [
            a: .init(surfaceId: a), b: .init(surfaceId: b, mode: .maximized),
        ]
        let frames = DesktopCanvasLayout.frames(tree: tree, panes: panes, in: area)
        #expect(frames == [b: area])
    }

    @Test func snapshotRoundTripAndV1Migration() throws {
        let v2 = CanvasPresentationSnapshot(panes: [
            .init(surfaceId: a, mode: .floating, restoreMode: .floating,
                  preferredRect: CGRect(x: 1, y: 2, width: 300, height: 200), zOrder: 3),
            .init(surfaceId: b, mode: .minimized, restoreMode: .tiled),
        ])
        let decoded = try CanvasPresentationSnapshot.decode(JSONEncoder().encode(v2))
        #expect(decoded == v2)

        let v1 = FloatingCanvasSnapshot(panes: [
            FloatingPaneState(surfaceId: a, mode: .normal, rect: CGRect(x: 5, y: 6, width: 300, height: 200), zOrder: 0),
            FloatingPaneState(surfaceId: b, mode: .maximized, rect: CGRect(x: 0, y: 0, width: 300, height: 200), zOrder: 1),
            FloatingPaneState(surfaceId: c, mode: .minimized, restoreMode: .maximized,
                              rect: CGRect(x: 0, y: 0, width: 300, height: 200), zOrder: 2),
        ])
        var migrated = try CanvasPresentationSnapshot.decode(JSONEncoder().encode(v1))
        #expect(migrated.version == 2)
        #expect(migrated.pane(a)?.mode == .floating)
        #expect(migrated.pane(a)?.preferredRect == CGRect(x: 5, y: 6, width: 300, height: 200))
        #expect(migrated.pane(b)?.mode == .maximized)
        #expect(migrated.pane(c)?.mode == .minimized)
        migrated.panes[2].restore()
        #expect(migrated.panes[2].mode == .maximized)
        migrated.panes[1].restore()
        #expect(migrated.panes[1].mode == .floating)
    }

    @Test func countsUseIdentityAndIndependentPreferences() {
        let all = DesktopPreferences { _ in nil }
        let rows: [(id: UUID, kind: SidebarAttentionCounts.Kind)] = [
            (a, .waiting), (a, .waiting), (b, .error), (c, .done), (c, .done),
        ]
        #expect(SidebarAttentionCounts(panes: rows, unread: [c], preferences: all)
            == SidebarAttentionCounts(waiting: 1, errors: 1, unreadDone: 1))
        #expect(SidebarAttentionCounts(panes: rows, unread: [], preferences: all).unreadDone == 0)
        let noErrors = DesktopPreferences { $0 == "sidebar-count-error" ? "false" : nil }
        #expect(SidebarAttentionCounts(panes: rows, unread: [c], preferences: noErrors)
            == SidebarAttentionCounts(waiting: 1, errors: 0, unreadDone: 1))
        // Hiding status is presentation-only and does not change counts.
        let hidden = DesktopPreferences { $0 == "status-show" ? "false" : nil }
        #expect(SidebarAttentionCounts(panes: rows, unread: [c], preferences: hidden).waiting == 1)
    }

    @Test func statusEffectTogglesPauseLayers() {
        let on = DesktopPreferences { _ in nil }
        #expect(CanvasStatusEffect.resolve(activity: .working, preferences: on, reduceMotion: false, isVisible: true) == .comet)
        #expect(CanvasStatusEffect.resolve(activity: .waiting, preferences: on, reduceMotion: false, isVisible: true) == .breathe)
        #expect(!CanvasStatusEffect.resolve(activity: .working, preferences: on, reduceMotion: true, isVisible: true).animates)
        #expect(!CanvasStatusEffect.resolve(activity: .working, preferences: on, reduceMotion: false, isVisible: false).animates)
        let still = DesktopPreferences { $0 == "status-animate" ? "false" : nil }
        #expect(CanvasStatusEffect.resolve(activity: .working, preferences: still, reduceMotion: false, isVisible: true) == .staticIndicator)
        let hidden = DesktopPreferences { $0 == "status-show" ? "false" : nil }
        #expect(CanvasStatusEffect.resolve(activity: .working, preferences: hidden, reduceMotion: false, isVisible: true) == .hidden)
    }

    @Test func titleColorFollowsPaneNotAppPalette() {
        let lightFg = NSColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1)
        let darkFg = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        #expect(CanvasPaneTitleColor.color(foreground: lightFg, background: .black) == lightFg)
        #expect(CanvasPaneTitleColor.color(foreground: darkFg, background: .white) == darkFg)
        #expect(CanvasPaneTitleColor.color(foreground: darkFg, background: .black) == .white)
        // App palette is independent of either terminal theme.
        #expect(DesktopPalette.dark.text != lightFg && DesktopPalette.light.text != darkFg)
    }
}
