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
import Foundation
import UserNotifications

/// Coordinates interactive prompts (`takoctl ask`) across terminal surface,
/// notification center, system desktop notifications, and terminal modal dialogs (B10).
@MainActor
final class PromptManager: NSObject {
    static let shared = PromptManager()

    var activePrompts: [String: ActivePrompt] = [:]
    var surfacePrompts: [UUID: Set<String>] = [:]
    var timers: [String: Timer] = [:]
    var registeredCategories: Set<String> = []

    var activeCount: Int { activePrompts.count }

    func activePrompt(for promptId: String) -> ActivePrompt? {
        activePrompts[promptId]
    }

    func activePrompts(for surfaceId: UUID) -> [ActivePrompt] {
        guard let ids = surfacePrompts[surfaceId] else { return [] }
        return ids.compactMap { activePrompts[$0] }
    }

    func reset() {
        for (_, timer) in timers {
            timer.invalidate()
        }
        timers.removeAll()
        for (_, prompt) in activePrompts {
            prompt.once.answer(.failure(ControlError(.disabled, "reset")))
        }
        activePrompts.removeAll()
        surfacePrompts.removeAll()
    }

    /// Presents an interactive prompt for an agent in `surface`.
    func ask(
        request: ControlRequest,
        surface: Tako.SurfaceView,
        reply: @escaping @Sendable (ControlResponse) -> Void
    ) throws {
        let message = try ControlInput.text(request.args, "message")
        guard !message.isEmpty else {
            throw ControlError(.invalid, "message cannot be empty")
        }

        let promptId = UUID().uuidString.lowercased()
        let title: String = {
            if let t = request.args["title"]?.string, !t.isEmpty {
                return t
            }
            let tabTitle = surface.window?.windowController.flatMap { ($0 as? BaseTerminalController)?.titleOverride }
                ?? surface.window?.title
            return tabTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Tako"
        }()

        let defaultValue = request.args["default"]?.string

        let timeout: TimeInterval? = {
            guard let t = request.args["timeout"] else { return nil }
            if case .number(let n) = t, n.isFinite && n > 0 && n <= 7 * 24 * 3600 {
                return n
            }
            return nil
        }()

        let promptType: PromptType
        if let choicesArray = request.args["choices"]?.array, !choicesArray.isEmpty {
            let choices = choicesArray.compactMap { $0.string }.filter { !$0.isEmpty }
            guard !choices.isEmpty else {
                throw ControlError(.invalid, "choices list cannot be empty")
            }
            promptType = .choice(choices: choices)
        } else if request.args["confirm"] == .bool(true) {
            let confirmText = request.args["confirm_text"]?.string ?? "Confirm"
            let cancelText = request.args["cancel_text"]?.string ?? "Cancel"
            promptType = .confirm(confirmText: confirmText, cancelText: cancelText)
        } else {
            let placeholder = request.args["placeholder"]?.string ?? ""
            let def = defaultValue ?? ""
            promptType = .text(placeholder: placeholder, defaultText: def)
        }

        let once = ControlCommands.OnceReply(reply)

        let prompt = ActivePrompt(
            id: promptId,
            surfaceId: surface.id,
            message: message,
            title: title,
            type: promptType,
            defaultValue: defaultValue,
            timeout: timeout,
            createdAt: Date(),
            once: once,
            clientGone: request.clientGone,
            surface: surface,
            dialog: nil
        )

        activePrompts[promptId] = prompt
        surfacePrompts[surface.id, default: []].insert(promptId)

        // 1. Surface Status: waiting_for_input in pane header and tab
        surface.crab.setStatus(Tako.PaneStatus.waitingForInput, text: message, ttl: timeout)

        // 2. Notification Center: add persistent NotificationRecord
        NotificationStore.shared.addNotification(
            id: promptId,
            surfaceId: surface.id,
            paneTitle: surface.title ?? "Terminal",
            title: title,
            body: message,
            urgency: 1,
            unread: true
        )

        // 3. System desktop notification via UNUserNotificationCenter
        postSystemNotification(promptId: promptId, prompt: prompt, surface: surface)

        // 4. Modal dialog in terminal window (if window is attached)
        presentDialogIfPossible(promptId: promptId, prompt: prompt, surface: surface)

        // 5. Liveness and timeout timer: observes clientGone, surface deallocation, and timeout
        let pollInterval: TimeInterval = {
            if let timeout = timeout {
                return min(0.25, max(0.02, timeout / 2))
            }
            return 0.25
        }()
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] t in
            guard let self = self else {
                t.invalidate()
                return
            }
            self.checkPromptLiveness(promptId: promptId, timer: t)
        }
        timers[promptId] = timer
    }

    func answerText(promptId: String, text: String) {
        guard let prompt = activePrompts[promptId] else { return }
        resolve(promptId: promptId, result: .success(PromptAnswer(
            answer: text,
            type: prompt.type,
            confirmed: nil,
            choiceIndex: nil,
            isDefault: false
        )))
    }

    func answerChoice(promptId: String, index: Int) {
        guard let prompt = activePrompts[promptId] else { return }
        if case .choice(let choices) = prompt.type, index >= 0 && index < choices.count {
            let choice = choices[index]
            resolve(promptId: promptId, result: .success(PromptAnswer(
                answer: choice,
                type: prompt.type,
                confirmed: nil,
                choiceIndex: index,
                isDefault: false
            )))
        }
    }

    func answerConfirm(promptId: String, confirmed: Bool, text: String) {
        guard let prompt = activePrompts[promptId] else { return }
        resolve(promptId: promptId, result: .success(PromptAnswer(
            answer: text,
            type: prompt.type,
            confirmed: confirmed,
            choiceIndex: nil,
            isDefault: false
        )))
    }

    func cancel(promptId: String, reason: String = "cancelled") {
        resolve(promptId: promptId, result: .failure(ControlError(.invalid, reason)))
    }

    /// Notifies PromptManager that a pane was closed, failing any pending prompts on that pane.
    func paneClosed(surfaceId: UUID) {
        guard let ids = surfacePrompts[surfaceId] else { return }
        for promptId in ids {
            resolve(promptId: promptId, result: .failure(ControlError(.notFound, "pane closed while waiting for answer")))
        }
    }

    func resolve(promptId: String, result: Result<PromptAnswer, ControlError>) {
        guard let prompt = activePrompts.removeValue(forKey: promptId) else { return }

        // Remove from surface mapping
        surfacePrompts[prompt.surfaceId]?.remove(promptId)
        if surfacePrompts[prompt.surfaceId]?.isEmpty == true {
            surfacePrompts.removeValue(forKey: prompt.surfaceId)
        }

        // Invalidate timer
        timers.removeValue(forKey: promptId)?.invalidate()

        // Dismiss modal dialog in window if present for this specific prompt
        if let window = prompt.surface?.window {
            TerminalDialogView.pending(in: window, for: promptId)?.withdraw()
            presentNextDialogIfPossible(in: window)
        }

        // Clean up desktop notifications and categories
        if let center = AppDelegate.notificationCenterProvider() {
            center.removeDeliveredNotifications(withIdentifiers: [promptId])
            center.removePendingNotificationRequests(withIdentifiers: [promptId])
            let categoryId = "tako-ask-\(promptId)"
            center.getNotificationCategories { existing in
                let updated = existing.filter { $0.identifier != categoryId }
                center.setNotificationCategories(updated)
            }
        }

        // Clean up Notification Center record
        NotificationStore.shared.markNotificationRead(id: promptId)

        // Clear surface status if it was waiting_for_input and no other prompt is waiting on this surface
        if let surface = prompt.surface {
            if surfacePrompts[surface.id] == nil || surfacePrompts[surface.id]?.isEmpty == true {
                if surface.crab.paneStatus == .waitingForInput {
                    surface.crab.clearStatus()
                }
            }
        }

        let typeStr: String = {
            switch prompt.type {
            case .choice: return "choice"
            case .confirm: return "confirm"
            case .text: return "text"
            }
        }()

        switch result {
        case .success(let answer):
            // Publish terminal event to TerminalEventHub
            var eventPayload: [String: JSON] = [
                "id": .string(promptId),
                "type": .string(typeStr),
                "answer": .string(answer.answer)
            ]
            if let confirmed = answer.confirmed {
                eventPayload["confirmed"] = .bool(confirmed)
            }
            if let idx = answer.choiceIndex {
                eventPayload["index"] = .number(Double(idx))
            }
            if answer.isDefault {
                eventPayload["default"] = .bool(true)
            }
            prompt.surface?.publishEvent(type: "ask_answered", payload: eventPayload)

            // Reply to control client
            var responseDict: [String: JSON] = [
                "id": .string(promptId),
                "surface": .string(prompt.surfaceId.uuidString.lowercased()),
                "type": .string(typeStr),
                "answer": .string(answer.answer)
            ]
            if let confirmed = answer.confirmed {
                responseDict["confirmed"] = .bool(confirmed)
            }
            if let idx = answer.choiceIndex {
                responseDict["index"] = .number(Double(idx))
                responseDict["choice"] = .string(answer.answer)
            }
            if answer.isDefault {
                responseDict["default"] = .bool(true)
            }
            prompt.once.answer(.ok(responseDict))

        case .failure(let error):
            prompt.once.answer(.failure(error))
        }
    }
}
