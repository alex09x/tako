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
import AppKit
@preconcurrency import UserNotifications

extension ControlCommands {
    /// `takoctl dialog`: the questions Tako has up in its windows. With
    /// `press`, answers the only one by pressing that button -- allowed only
    /// with `remote-control = on`: a confirmation a script in a pane could
    /// answer itself would not protect anything.
    static func dialog(_ args: [String: JSON]) throws -> [String: JSON] {
        let open: [(window: String, view: TerminalDialogView)] = TerminalController.all.compactMap { controller in
            guard let window = controller.window, let view = TerminalDialogView.pending(in: window) else { return nil }
            return ("window-\(ObjectIdentifier(Tako.CustomTabGroup.group(for: window)).hexString)", view)
        }
        guard case .string(let label)? = args["press"] else {
            return ["dialogs": .array(open.map { item in
                var summary = item.view.summary
                summary["window"] = .string(item.window)
                return .object(summary)
            })]
        }
        guard ControlCommands.mode == .on else {
            throw ControlError(.disabled, "answering a question needs remote-control = on")
        }
        guard let only = open.first, open.count == 1 else {
            throw ControlError(open.isEmpty ? .notFound : .ambiguous,
                               open.isEmpty ? "no question is up" : "\(open.count) questions are up")
        }
        let summary = only.view.summary
        guard only.view.press(label) else {
            throw ControlError(.invalid, "no button \"\(label)\"; there are: \(summary["buttons"].map { "\($0.any)" } ?? "")")
        }
        TerminalEventHub.shared.publish(
            type: "ask_answered",
            window: only.window,
            payload: [
                "answer": .string(label),
                "title": summary["title"] ?? .null
            ]
        )
        return ["pressed": .string(label), "title": summary["title"] ?? .null]
    }

    /// `takoctl notify`: a system notification about `surface` -- titled
    /// `title`, or the tab's title -- that brings the pane forward when
    /// clicked, shown even while Tako is in front.
    /// Answered once the notification is with the system -- or with why it
    /// is not: notifications not allowed for Tako, or not accepted.
    /// How long `notify` waits for the system -- a first-time permission
    /// prompt may sit unanswered -- before it answers `timeout`: inside
    /// takoctl's own 30 s, so the client always hears why.
    nonisolated static let notifyWait: TimeInterval = 20

    static func notify(_ request: ControlRequest, _ surface: Tako.SurfaceView, text: String, title: String?,
                       reply: @escaping @Sendable (ControlResponse) -> Void) throws {
        guard !text.isEmpty else { throw ControlError(.invalid, "nothing to say") }
        let content = UNMutableNotificationContent()
        let tabTitle = surface.window?.windowController.flatMap { ($0 as? BaseTerminalController)?.titleOverride }
            ?? surface.window?.title
        content.title = title ?? tabTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Tako"
        content.body = text
        content.userInfo = [Tako.notificationSurfaceKey: surface.id.uuidString,
                            Tako.notificationFromControlKey: true]
        guard let center = AppDelegate.notificationCenterProvider() else {
            throw ControlError(.internalError, "notifications are unavailable")
        }
        let id = surface.id.uuidString.lowercased()
        // One answer, whichever comes first: the system, the deadline, or
        // the client going away. After that nothing is posted.
        let once = OnceReply(reply)
        let deadline = Date().addingTimeInterval(notifyWait)
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            // Cancels only while the system has not been asked to post; once
            // it has, its own answer comes.
            if once.done {
                timer.invalidate()
            } else if request.clientGone() {
                if once.cancel(.failure(ControlError(.timeout, "the client went away"))) { timer.invalidate() }
            } else if Date() >= deadline {
                if once.cancel(.failure(ControlError(.timeout,
                    "no answer from the system in \(Int(notifyWait)) s -- is a notification permission prompt waiting?"))) {
                    timer.invalidate()
                }
            }
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            // Cancelled already: nothing is posted.
            guard once.claim() else { return }
            guard granted else {
                return once.answer(.failure(ControlError(.disabled,
                    "notifications are not allowed for Tako (System Settings → Notifications)"
                        + (error.map { ": \($0.localizedDescription)" } ?? ""))))
            }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                if let error {
                    once.answer(.failure(ControlError(.internalError, "not posted: \(error.localizedDescription)")))
                } else {
                    DispatchQueue.main.async {
                        surface.publishEvent(
                            type: "notification",
                            payload: [
                                "title": .string(content.title),
                                "body": .string(text),
                                "action": .string("posted")
                            ]
                        )
                    }
                    once.answer(.ok(["id": .string(id)]))
                }
            }
        }
    }

    /// A reply that goes out at most once, and an action it guards: while
    /// `pending`, the deadline or a departed client may `cancel` it; once
    /// the action has `claim`ed it, only the action answers -- so nothing is
    /// done after a cancel, and nothing done is reported as cancelled.
    final class OnceReply: @unchecked Sendable {
        enum State { case pending, acting, answered }
        private let lock = NSLock()
        private var state = State.pending
        private let reply: @Sendable (ControlResponse) -> Void
        init(_ reply: @escaping @Sendable (ControlResponse) -> Void) { self.reply = reply }
        var done: Bool { lock.withLock { state == .answered } }

        /// Takes the right to act; false when already cancelled or answered.
        func claim() -> Bool {
            lock.withLock {
                guard state == .pending else { return false }
                state = .acting
                return true
            }
        }

        /// Answers only if nothing has started: false otherwise.
        @discardableResult
        func cancel(_ response: ControlResponse) -> Bool {
            let won = lock.withLock { () -> Bool in
                guard state == .pending else { return false }
                state = .answered
                return true
            }
            if won { reply(response) }
            return won
        }

        /// The answer from whoever holds the right to act, or from a
        /// pending one; once.
        func answer(_ response: ControlResponse) {
            let first = lock.withLock { () -> Bool in
                guard state != .answered else { return false }
                state = .answered
                return true
            }
            if first { reply(response) }
        }
    }
}
