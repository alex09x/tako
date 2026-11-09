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

        center.statusChanged(surface, to: .error)
        #expect(center.toasts.map(\.state) == [.failed])
        #expect(center.toasts.first?.message == "процесс завершился с ошибкой")
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

    @Test func theExitCodeComesFromTheCrab() {
        #expect(PaneToastCenter.exitCode(.succeeded) == 0)
        #expect(PaneToastCenter.exitCode(.failed(code: 101)) == 101)
        #expect(PaneToastCenter.exitCode(.idle) == nil)
    }
}
