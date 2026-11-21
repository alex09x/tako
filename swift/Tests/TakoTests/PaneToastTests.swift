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

/// Toasts (reference app.js notify): a pane out of sight that finishes, fails
/// or waits shows one; three at most, one per pane, each gone after 4 s, when
/// the pane is seen, or when clicked, which goes to the pane.
@Suite(.serialized) @MainActor
struct PaneToastTests {
    private func center() -> (PaneToastCenter, () -> Void) {
        let center = PaneToastCenter()
        var pending: [() -> Void] = []
        center.schedule = { delay, work in
            #expect(delay == PaneToastCenter.lifetime)
            pending.append(work)
        }
        return (center, { let due = pending; pending = []; due.forEach { $0() } })
    }

    private func toast(_ pane: UUID, _ headline: String) -> PaneToast {
        PaneToast(id: UUID(), surfaceID: pane, state: .done, headline: headline, message: "", place: "in the background")
    }

    @Test func aToastGoesAfterItsLifetimeAndANewStateReplacesItsPanesToast() {
        let (center, fire) = center()
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        center.show(toast(a, "a done"))
        center.show(toast(a, "a failed"))
        #expect(center.toasts.map(\.headline) == ["a failed"], "one pane stacked two toasts")
        center.show(toast(b, "b"))
        center.show(toast(c, "c"))
        center.show(toast(d, "d"))
        #expect(center.toasts.map(\.headline) == ["d", "c", "b"], "more than three, or not newest first")
        fire()
        #expect(center.toasts.isEmpty)
    }

    @Test func aPaneOutOfSightShowsWhatHappenedAndSeeingItTakesItAway() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        let surface = try #require(controller.focusedSurface)
        #expect(!surface.isBeingLookedAt, "the test window is looked at")
        let (center, _) = center()

        center.statusChanged(surface, to: .running)
        #expect(center.toasts.isEmpty, "a running command made a toast")
        center.statusChanged(surface, to: .needsApproval)
        let waiting = try #require(center.toasts.first)
        #expect(waiting.headline.hasSuffix("— needs your attention") && waiting.state == .waiting)

        AttentionManager.shared.setMuted(true, for: surface.id)
        center.statusChanged(surface, to: .error)
        AttentionManager.shared.setMuted(false, for: surface.id)
        #expect(center.toasts.first?.state == .waiting, "a muted pane made a toast")

        PaneTitleStore.shared.setTitle("миграции", for: surface.id)
        defer { PaneTitleStore.shared.setTitle(nil, for: surface.id) }
        center.statusChanged(surface, to: .error)
        #expect(center.toasts.map(\.state) == [.failed])
        #expect(center.toasts.first?.headline.hasPrefix("миграции — error") == true, "the toast ignores the pane's name")
        #expect(center.toasts.first?.message == "The terminal reported an error", "an error that is no exit was called one")
        #expect(center.toasts.first?.headline.contains("exit") == false)
        center.seen(surface.id)
        #expect(center.toasts.isEmpty)
    }

    @Test func clickingAToastRestoresItsPaneFromTheShelf() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        window.setContentSize(NSSize(width: 1000 + SessionSidebarWidth.current(), height: 700))
        controller.showWindow(nil)
        let p1 = try #require(controller.focusedSurface)
        let p2 = try #require(controller.newSplit(at: p1, direction: .right))
        controller.minimizeFloatingPane(p2)
        TerminalTestSupport.waitUntil(timeout: 1) { controller.isMinimizedInFloatingCanvas(p2.id) }
        let (center, _) = center()

        center.statusChanged(p2, to: .done)
        let toast = try #require(center.toasts.first)
        #expect(toast.place == "minimized")
        center.open(toast)
        #expect(center.toasts.isEmpty)
        TerminalTestSupport.waitUntil(timeout: 1) { !controller.isMinimizedInFloatingCanvas(p2.id) }
        #expect(!controller.isMinimizedInFloatingCanvas(p2.id), "the toast did not bring its pane back")
        #expect(controller.focusedSurface === p2)
    }

    /// A checkpoint restore brings a pane's status back; it is no news. A
    /// live status from the program is, and says what the program said.
    /// Async: the status sink posts to the main queue, which runs only once
    /// this test (itself a main-queue job) suspends; a nested run loop would not.
    @Test func aRestoredStatusMakesNoToastAndALiveOneDoes() async throws {
        // No window is needed for this observation contract. A loading window
        // can asynchronously attach/focus the pane and acknowledge the outcome.
        let app = Tako.App()
        let surface = Tako.SurfaceView(app)
        defer { surface.close() }
        surface.crab.isFocused = false
        PaneToastCenter.shared.resetForTesting()
        defer { PaneToastCenter.shared.resetForTesting() }
        func error(_ revision: UInt64, _ msg: String) -> TerminalProgramStatusSnapshot {
            let record = TerminalProgramStatusRecord(id: "default", state: .error, app: "AGY", resolvedApp: "AGY",
                                                     msg: msg, revision: revision)
            return TerminalProgramStatusSnapshot(revision: revision, osc7501Active: true, effective: record, records: [record])
        }

        surface.applyProgramStatusEvent(.restored(error(1, "restored failure")))
        let deadline = Date().addingTimeInterval(1)
        while surface.crab.paneStatus != .error && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(surface.crab.paneStatus == .error, "the restored status was not applied")
        #expect(PaneToastCenter.shared.toasts.isEmpty, "a restored status was announced: \(PaneToastCenter.shared.toasts)")

        surface.applyProgramStatusEvent(.restored(TerminalProgramStatusSnapshot(revision: 2, osc7501Active: true,
                                                                                effective: nil, records: [])))
        let cleared = surface.crab.paneStatus
        let live = error(3, "migration failed")
        surface.applyProgramStatusEvent(.updated(TerminalProgramStatusUpdate(revision: 3, mutations: [], effective: live.effective),
                                                 snapshot: live))
        let toastDeadline = Date().addingTimeInterval(1)
        while PaneToastCenter.shared.toasts.isEmpty && Date() < toastDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let toast = try #require(PaneToastCenter.shared.toasts.first,
                                 "a live error made no toast: cleared \(cleared), now \(surface.crab.paneStatus)")
        #expect(toast.message == "migration failed")
        #expect(!toast.headline.contains("exit"), "a program's error showed an exit code: \(toast.headline)")
    }

    /// «status-show = false» calms the rings; notifications are separate and
    /// still come. Mute still silences a pane.
    @Test func hiddenStatusesStillNotifyAndMuteStillSilences() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        let surface = try #require(controller.focusedSurface)
        let anim = LivingAnimationState.shared
        anim.applyStatusPreferences(DesktopPreferences { $0 == "status-show" ? "false" : nil })
        defer { anim.applyStatusPreferences(DesktopPreferences { _ in nil }) }
        #expect(!anim.statusShown, "the preference did not hide statuses")
        let (center, _) = center()

        center.statusChanged(surface, to: .done)
        #expect(center.toasts.map(\.state) == [.done], "hidden statuses silenced a done toast")
        center.statusChanged(surface, to: .needsApproval)
        #expect(center.toasts.map(\.state) == [.waiting], "hidden statuses silenced a waiting toast")

        center.resetForTesting()
        AttentionManager.shared.setMuted(true, for: surface.id)
        defer { AttentionManager.shared.setMuted(false, for: surface.id) }
        center.statusChanged(surface, to: .done)
        #expect(center.toasts.isEmpty, "a muted pane made a toast")
    }

    @Test func aToastEasesIn220msAndReduceMotionShowsItAtOnce() {
        #expect(PaneToastStack.duration == 0.22)
        #expect(PaneToastStack.animation(reduceMotion: false) != nil)
        #expect(PaneToastStack.animation(reduceMotion: true) == nil, "Reduce Motion still animates toasts")
        // A transition is opaque; the reduced one must be the identity (no move, no fade).
        #expect(String(describing: PaneToastStack.transition(reduceMotion: true)) == String(describing: AnyTransition.identity))
        #expect(String(describing: PaneToastStack.transition(reduceMotion: false)) != String(describing: AnyTransition.identity))
    }

    @Test func theExitCodeComesFromTheCrab() {
        #expect(PaneToastCenter.exitCode(.succeeded) == 0)
        #expect(PaneToastCenter.exitCode(.failed(code: 101)) == 101)
        #expect(PaneToastCenter.exitCode(.idle) == nil)
    }
}
