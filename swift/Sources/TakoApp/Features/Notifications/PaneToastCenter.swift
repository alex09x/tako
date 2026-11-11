/*
 * tako — Toasts for what finishes or waits out of sight (reference app.js notify)
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Combine
import UserNotifications

/// One toast: a pane that became done, failed or started waiting for you
/// while you were not looking at it.
struct PaneToast: Identifiable, Equatable {
    let id: UUID
    let surfaceID: UUID
    let state: Tako.SurfaceState
    /// «claude · auth — needs your attention»
    let headline: String
    /// What it asks, the session, or «The process exited with an error».
    let message: String
    /// «minimized», the session's title, or «in the background».
    let place: String
}

/// The reference's toasts (app.js notify, style.css `.toasts`): at most
/// three, newest on top, each gone after 4 s or when clicked, which goes to
/// the pane (its tab, restored from the shelf, focused). A pane has one toast
/// at most: a new state replaces its old toast instead of stacking. Nothing
/// runs between changes: a status change adds a toast, one delayed call
/// takes it away.
@MainActor
final class PaneToastCenter: ObservableObject {
    static let shared = PaneToastCenter()

    static let limit = 3
    static let lifetime: TimeInterval = 4

    @Published private(set) var toasts: [PaneToast] = []
    /// How many notify-on-command-finish signals each pane had when last seen here.
    private var seenSignals: [UUID: Int] = [:]
    /// Tests replace it; the app schedules on the main queue.
    var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) }
    }

    /// A pane's status changed; out of sight, a finish, a failure or a wait
    /// shows a toast, with its sound (ActivityAlert decides which way).
    func statusChanged(_ surface: Tako.SurfaceView, to status: Tako.PaneStatus) {
        // «status-show» calms the indicators only; notifications are separate
        // (Settings › Status: «Notifications are independent of appearance»). Mute still silences.
        // notify-on-command-finish signals a long command's end on its own;
        // a signal not yet seen here belongs to this end.
        let signals = surface.commandFinishSignals
        let alreadySignalled = signals > (seenSignals[surface.id] ?? 0)
        seenSignals[surface.id] = signals
        guard let kind = Self.kind(status), let event = ActivityEvent(status) else { return }
        let preferences = DesktopPresentation.shared.preferences
        let decision = ActivityAlert.decide(.init(
            policy: preferences.activityAlert, sound: preferences.activitySound(event),
            lookedAt: surface.isBeingLookedAt, muted: AttentionManager.shared.isMuted(surfaceId: surface.id),
            takoInFront: ActivityAlert.takoInFront(), reportsItself: surface.crab.osc7501StatusActive,
            alreadySignalled: alreadySignalled))
        if let sound = decision.appSound { ActivityAlert.play(sound) }
        guard decision.toast else { return }
        let controller = BaseTerminalController.owningController(for: surface)
        let minimized = controller?.isMinimizedInFloatingCanvas(surface.id) == true
        let session = controller?.window?.title ?? ""
        let elsewhere = controller?.window.map { !$0.isKeyWindow || !NSApp.isActive } ?? true
        let place = minimized ? "minimized" : (elsewhere && !session.isEmpty ? session : "in the background")
        let title = surface.paneTitleOverride ?? (surface.title.isEmpty ? "terminal" : surface.title)
        // A program's own status (OSC 7501) is not a process exit: no exit code, its own words.
        let reported = surface.crab.explicitStatus != nil
        let exit = reported ? nil : Self.exitCode(surface.crab.state)
        let said = surface.crab.statusText.flatMap { $0.isEmpty ? nil : $0 }
        let toast: PaneToast
        switch kind {
        case .waiting:
            toast = .init(id: UUID(), surfaceID: surface.id, state: .waiting, headline: "\(title) — needs your attention",
                          message: said ?? "", place: place)
        case .done:
            toast = .init(id: UUID(), surfaceID: surface.id, state: .done,
                          headline: "\(title) — done\(exit.map { " · exit \($0)" } ?? "")",
                          message: said ?? session, place: place)
        case .failed:
            let message = said ?? (exit != nil ? "The command exited with an error" : "The terminal reported an error")
            toast = .init(id: UUID(), surfaceID: surface.id, state: .failed,
                          headline: "\(title) — error\(exit.map { " · exit \($0)" } ?? "")",
                          message: message, place: place)
        }
        show(toast)
        if decision.systemNotification {
            postNotification(for: toast, surface: surface, title: title, sounds: decision.notificationSounds)
        }
    }

    /// Out of sight, the toast's news goes to macOS too, with the sound.
    private func postNotification(for toast: PaneToast, surface: Tako.SurfaceView, title: String, sounds: Bool) {
        let id = ActivityAlert.requestID(surface.id)
        let content = Tako.buildNotificationContent(
            title: toast.headline, body: toast.message, surfaceId: surface.id, paneTitle: title,
            pwd: surface.pwd, command: nil, id: id, urgency: 1, onlyWhenUnfocused: true)
        content.sound = sounds ? ActivitySounds.notificationSound : nil
        ActivityAlert.post(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func show(_ toast: PaneToast) {
        var next = toasts.filter { $0.surfaceID != toast.surfaceID }
        next.insert(toast, at: 0)
        toasts = Array(next.prefix(Self.limit))
        let id = toast.id
        schedule(Self.lifetime) { [weak self] in self?.dismiss(id) }
    }

    func dismiss(_ id: UUID) {
        guard toasts.contains(where: { $0.id == id }) else { return }
        toasts.removeAll { $0.id == id }
    }

    /// The pane, in front and focused; the toast goes.
    func open(_ toast: PaneToast) {
        dismiss(toast.id)
        guard let surface = Tako.SurfaceView.find(for: toast.surfaceID),
              let controller = BaseTerminalController.owningController(for: surface) else { return }
        controller.window?.makeKeyAndOrderFront(nil)
        controller.revealAndFocusFloatingPane(surface)
    }

    /// The pane's toasts go when you look at it.
    func seen(_ surfaceID: UUID) {
        ActivityAlert.withdraw(ActivityAlert.requestID(surfaceID))
        guard toasts.contains(where: { $0.surfaceID == surfaceID }) else { return }
        toasts.removeAll { $0.surfaceID == surfaceID }
    }

    /// The last command's exit, when the crab knows it.
    static func exitCode(_ state: Tako.CrabState) -> Int32? {
        switch state {
        case .succeeded: 0
        case .failed(let code): code
        default: nil
        }
    }

    private enum Kind { case waiting, done, failed }

    private static func kind(_ status: Tako.PaneStatus) -> Kind? {
        switch status {
        case .needsApproval, .waitingForInput: .waiting
        case .done: .done
        case .error: .failed
        default: nil
        }
    }

    func resetForTesting() { toasts = [] }
}
