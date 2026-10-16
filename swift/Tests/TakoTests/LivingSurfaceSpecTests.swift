/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing
@testable import Tako

/// The rules of the Sessions UI 1b spec that are behaviour, not pixels.
@Suite
@MainActor
struct LivingSurfaceSpecTests {
    // "работает: только если команда идёт >3s"
    @Test func aShellCommandIsWorkingOnlyOnceTheCrabSaysItRanLongEnough() {
        #expect(Tako.PaneStatus.running.surfaceState(crabState: .idle) == .idle)
        #expect(Tako.PaneStatus.running.surfaceState(crabState: .running) == .working)
        // An agent's explicit status has no such wait.
        #expect(Tako.PaneStatus.working.surfaceState(crabState: .idle) == .working)
        // Progress still shows while the command is young.
        #expect(Tako.PaneStatus.running.surfaceState(progressState: .normal, progressFraction: 0.4, crabState: .idle) == .progress(0.4))

        var now = Date(timeIntervalSince1970: 0)
        let tracker = Tako.CrabTracker(now: { now })
        tracker.commandStarted()
        now = now.addingTimeInterval(1)
        tracker.tick()
        #expect(tracker.paneStatus.surfaceState(crabState: tracker.state) == .idle)
        now = now.addingTimeInterval(3)
        tracker.tick()
        #expect(tracker.paneStatus.surfaceState(crabState: tracker.state) == .working)

        let sidebarItem = SessionSidebarItem(id: "t", index: 0, isSelected: false, title: "ls", status: .running, crabState: .idle)
        #expect(sidebarItem.surfaceState == .idle)
        let overviewItem = PaneOverviewItem(id: UUID(), title: "ls", status: .running, crabState: .idle)
        #expect(overviewItem.surfaceState == .idle)
    }

    // "на активной вкладке «готово» и «ошибка» гаснут через 2s"
    @Test func aFailureInTheFocusedTabShowsThenFades() {
        var now = Date(timeIntervalSince1970: 0)
        let tracker = Tako.CrabTracker(now: { now })
        tracker.isFocused = true
        tracker.commandStarted()
        now = now.addingTimeInterval(4)
        tracker.commandEnded(exitCode: 7)
        #expect(tracker.paneStatus == .error)
        #expect(tracker.isFadePending)

        tracker.fadeSeenOutcome()
        #expect(tracker.paneStatus == .idle)
        #expect(tracker.state == .idle)
        #expect(tracker.unread == false)
    }

    @Test func anExplicitFailureInTheFocusedTabFadesToo() {
        let tracker = Tako.CrabTracker()
        tracker.isFocused = true
        tracker.setStatus(.error, text: "tests failed")
        #expect(tracker.paneStatus == .error)
        #expect(tracker.isFadePending)

        tracker.fadeSeenOutcome()
        #expect(tracker.paneStatus == .idle)
        #expect(tracker.statusText == nil)
    }

    // "...на фоновых держатся до фокуса"
    @Test func theFadeLeavesATabThatLostFocusAlone() {
        var now = Date(timeIntervalSince1970: 0)
        let tracker = Tako.CrabTracker(now: { now })
        tracker.isFocused = true
        tracker.commandStarted()
        now = now.addingTimeInterval(4)
        tracker.commandEnded(exitCode: 0)
        tracker.unfocused()

        tracker.fadeSeenOutcome()
        #expect(tracker.paneStatus == .done)
        #expect(tracker.state == .succeeded)
    }

    // "cwd у панелей скрыт, если совпадает с родительским"
    @Test func aPaneRowHidesTheDirectoryItsSessionShows() {
        let same = SessionSidebarItem(id: "c", index: 0, isSelected: false, title: "claude",
                                      workingDirectory: "/Users/a/tako/", parentWorkingDirectory: "/Users/a/tako",
                                      isChild: true)
        #expect(same.paneDirectoryToShow == nil)
        let other = SessionSidebarItem(id: "c", index: 0, isSelected: false, title: "npm",
                                       workingDirectory: "/Users/a/web", parentWorkingDirectory: "/Users/a/tako",
                                       isChild: true)
        #expect(other.paneDirectoryToShow == "/Users/a/web")
    }

    // "Чипы в шапке («2 need you», «2 working») заодно работают как фильтры"
    @Test func theHeaderChipsFilterTheStatesTheyCount() {
        let store = PaneOverviewStore()
        let approval = PaneOverviewItem(id: UUID(), title: "claude", status: .needsApproval)
        let input = PaneOverviewItem(id: UUID(), title: "gemini", status: .waitingForInput)
        let working = PaneOverviewItem(id: UUID(), title: "codex", status: .working)
        let progress = PaneOverviewItem(id: UUID(), title: "cargo build", status: .running, crabState: .running,
                                        progressState: .normal, progressValue: 68)
        let done = PaneOverviewItem(id: UUID(), title: "psql", status: .done)
        store.items = [approval, input, working, progress, done]

        store.statusFilter = .needsYou
        #expect(store.filteredItems.map(\.id) == [approval.id, input.id])
        store.statusFilter = .working
        #expect(store.filteredItems.map(\.id) == [working.id, progress.id])
        store.filterText = "cargo"
        #expect(store.filteredItems.map(\.id) == [progress.id])
        store.statusFilter = nil
        store.filterText = ""
        #expect(store.filteredItems.count == 5)
    }
}

/// The smaller 4a/4b details: the dirty count and a bell in the overview.
@Suite
@MainActor
struct LivingSurfaceSpecDetailTests {
    // "~/tako-core · ⎇ feat/sidebar ±3"
    @Test func theBranchCarriesTheChangedFileCount() {
        #expect(LocalGitInspection.changedFileCount(porcelain: " M a.swift\n?? b.swift\nA  c.swift\n") == 3)
        #expect(LocalGitInspection.changedFileCount(porcelain: "") == 0)

        func item(dirty: Bool?, count: Int?) -> SessionSidebarItem {
            SessionSidebarItem(id: "t", index: 0, isSelected: false, title: "cargo build",
                               gitBranch: "feat/sidebar", gitDirty: dirty, gitChangedFiles: count)
        }
        #expect(item(dirty: true, count: 3).gitDirtySuffix == " ±3")
        #expect(item(dirty: true, count: nil).gitDirtySuffix == " ±")
        #expect(item(dirty: false, count: 0).gitDirtySuffix == "")
        #expect(LocalGitInspection.GitInfo(branch: "main", isDirty: false).changedFiles == 0)
    }

    // A bell on a quiet pane waits for you in the overview as in the sidebar.
    @Test func aBellOnAQuietPaneIsWaitingInTheOverview() {
        let rang = PaneOverviewItem(id: UUID(), title: "make", status: .idle, hasUnread: true)
        #expect(rang.surfaceState == .waiting)
        #expect(PaneOverviewStore.StatusFilter.needsYou.matches(rang))
        // Something louder keeps its own state.
        let failed = PaneOverviewItem(id: UUID(), title: "make", status: .error, hasUnread: true)
        #expect(failed.surfaceState == .failed)
        #expect(PaneOverviewItem(id: UUID(), title: "make", status: .idle).surfaceState == .idle)
    }
}

/// The done glint drawn as the design's `.shim::before` is.
@Suite
struct DoneGlintGeometryTests {
    /// Gradient location (0...1) at a point of a `g`×`h` tile, from unit end
    /// points interpreted in points -- what SwiftUI does.
    private func location(_ x: CGFloat, _ y: CGFloat, g: CGFloat, h: CGFloat) -> CGFloat {
        let e = DoneGlint.unitEndpoints(tileWidth: g, height: h)
        let s = CGPoint(x: e.start.x * g, y: e.start.y * h), t = CGPoint(x: e.end.x * g, y: e.end.y * h)
        let d = CGPoint(x: t.x - s.x, y: t.y - s.y)
        return ((x - s.x) * d.x + (y - s.y) * d.y) / (d.x * d.x + d.y * d.y)
    }

    @Test func theBandSweepsFromJustLeftToJustRightOfTheSurface() {
        let w: CGFloat = 140
        // The band's centre sits at the tile's centre: 120% -> -60%.
        #expect(abs(DoneGlint.tileOrigin(progress: 0, width: w) + 1.25 * w - (-0.55 * w)) < 0.001)
        #expect(abs(DoneGlint.tileOrigin(progress: 1, width: w) + 1.25 * w - 2.15 * w) < 0.001)
        #expect(DoneGlint.progress(elapsed: 0) == 0)
        #expect(DoneGlint.progress(elapsed: 0.96) == nil)
    }

    @Test func aTileHasNoGreenAtItsEdgesSoTheGlintHasNoHardEdge() {
        for (w, h) in [(CGFloat(139.4), CGFloat(28)), (340, 245), (264, 47)] {
            let g = DoneGlint.tileScale * w
            for y in stride(from: CGFloat(0), through: h, by: h / 8) {
                #expect(location(0, y, g: g, h: h) <= DoneGlint.locations[0])
                #expect(location(g, y, g: g, h: h) >= DoneGlint.locations[2])
            }
        }
    }

    @Test func theLayerEndpointsGiveTheSameBandAsCSS() {
        // CAGradientLayer runs its gradient perpendicular in unit space; the
        // layer end points must reproduce the point-space CSS gradient.
        let g: CGFloat = 349, h: CGFloat = 28
        let e = DoneGlint.layerEndpoints(tileWidth: g, height: h)
        func caLocation(_ x: CGFloat, _ yDown: CGFloat) -> CGFloat {
            let u = x / g, v = 1 - yDown / h
            let d = CGPoint(x: e.end.x - e.start.x, y: e.end.y - e.start.y)
            return ((u - e.start.x) * d.x + (v - e.start.y) * d.y) / (d.x * d.x + d.y * d.y)
        }
        for (x, y) in [(0.0, 0.0), (g / 2, h / 2), (g, h), (g / 3, 0), (2 * g / 3, h)] as [(CGFloat, CGFloat)] {
            #expect(abs(caLocation(x, y) - location(x, y, g: g, h: h)) < 0.001)
        }
    }
}
