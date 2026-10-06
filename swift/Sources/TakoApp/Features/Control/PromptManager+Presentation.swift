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

extension PromptManager {
    func checkPromptLiveness(promptId: String, timer: Timer) {
        guard let prompt = activePrompts[promptId] else {
            timer.invalidate()
            return
        }

        // 1. Check if client disconnected / was killed (ControlServer socket closed)
        if prompt.clientGone() {
            timer.invalidate()
            resolve(promptId: promptId, result: .failure(ControlError(.timeout, "client disconnected")))
            return
        }

        // 2. Check if surface was deallocated
        if prompt.surface == nil {
            timer.invalidate()
            resolve(promptId: promptId, result: .failure(ControlError(.notFound, "pane closed while waiting for answer")))
            return
        }

        // 3. Check timeout if one was specified
        if let timeout = prompt.timeout {
            let elapsed = Date().timeIntervalSince(prompt.createdAt)
            if elapsed >= timeout {
                timer.invalidate()
                handleTimeout(promptId: promptId)
                return
            }
        }
    }

    func handleTimeout(promptId: String) {
        guard let prompt = activePrompts[promptId] else { return }
        if let def = prompt.defaultValue {
            // Default value returned as success on timeout!
            let isConfirmYes = (prompt.type == .confirm(confirmText: "Confirm", cancelText: "Cancel")
                && (def.lowercased() == "yes" || def.lowercased() == "confirm" || def.lowercased() == "true"))
            resolve(promptId: promptId, result: .success(PromptAnswer(
                answer: def,
                type: prompt.type,
                confirmed: isConfirmYes ? true : nil,
                choiceIndex: nil,
                isDefault: true
            )))
        } else {
            resolve(promptId: promptId, result: .failure(ControlError(.timeout, "timed out waiting for user answer")))
        }
    }

    func postSystemNotification(promptId: String, prompt: ActivePrompt, surface: Tako.SurfaceView) {
        guard let center = AppDelegate.notificationCenterProvider() else { return }

        let categoryId = "tako-ask-\(promptId)"
        var actions: [UNNotificationAction] = []

        switch prompt.type {
        case .choice(let choices):
            actions = choices.prefix(4).enumerated().map { idx, choice in
                UNNotificationAction(
                    identifier: "choice_\(idx)",
                    title: Tako.sanitizeNotificationText(choice),
                    options: [] // Background action: does not switch tabs or bring app front!
                )
            }
        case .confirm(let confirmText, let cancelText):
            actions = [
                UNNotificationAction(
                    identifier: "confirm_yes",
                    title: Tako.sanitizeNotificationText(confirmText),
                    options: []
                ),
                UNNotificationAction(
                    identifier: "confirm_no",
                    title: Tako.sanitizeNotificationText(cancelText),
                    options: [.destructive]
                )
            ]
        case .text(let placeholder, _):
            actions = [
                UNTextInputNotificationAction(
                    identifier: "action_text",
                    title: "Reply",
                    options: [],
                    textInputButtonTitle: "Send",
                    textInputPlaceholder: placeholder.isEmpty ? "Type an answer..." : placeholder
                )
            ]
        }

        let category = UNNotificationCategory(
            identifier: categoryId,
            actions: actions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        center.getNotificationCategories { [weak self] existing in
            var updated = existing
            updated.insert(category)
            center.setNotificationCategories(updated)
            Task { @MainActor [weak self] in
                self?.registeredCategories.insert(categoryId)
            }
        }

        let content = UNMutableNotificationContent()
        content.title = Tako.sanitizeNotificationText(prompt.title)
        content.body = Tako.sanitizeNotificationText(prompt.message)
        content.categoryIdentifier = categoryId
        content.userInfo = [
            Tako.notificationSurfaceKey: surface.id.uuidString,
            "tako_prompt_id": promptId,
            Tako.notificationFromControlKey: true
        ]
        content.sound = .default

        let req = UNNotificationRequest(identifier: promptId, content: content, trigger: nil)
        center.add(req, withCompletionHandler: nil)
    }

    func presentDialogIfPossible(promptId: String, prompt: ActivePrompt, surface: Tako.SurfaceView) {
        guard let window = surface.window, window.contentView != nil else { return }
        guard TerminalDialogView.pending(in: window) == nil else { return }
        let theme = (NSApp.delegate as? AppDelegate)?.tako.config.theme

        Task { @MainActor [weak self] in
            guard let self = self, self.activePrompts[promptId] != nil else { return }
            guard TerminalDialogView.pending(in: window) == nil else { return }

            switch prompt.type {
            case .choice(let choices):
                let dialogChoices = choices.map { TerminalDialogView.Choice(title: $0, kind: .normal) }
                let lines = TUIText.plain(prompt.message, width: 52)
                let selectedIndex = await TerminalDialogView.choose(
                    in: window,
                    title: prompt.title,
                    lines: lines,
                    choices: dialogChoices,
                    selected: 0,
                    cancelIndex: -1,
                    promptId: promptId,
                    theme: theme
                )
                if let idx = selectedIndex, idx >= 0 && idx < choices.count {
                    self.answerChoice(promptId: promptId, index: idx)
                } else if selectedIndex == -1 {
                    self.cancel(promptId: promptId, reason: "dialog cancelled")
                }

            case .confirm(let confirmText, let cancelText):
                let confirmed = await TerminalDialogView.ask(
                    in: window,
                    title: prompt.title,
                    message: prompt.message,
                    confirm: confirmText,
                    cancel: cancelText,
                    promptId: promptId,
                    theme: theme
                )
                if let confirmed = confirmed {
                    if confirmed {
                        self.answerConfirm(promptId: promptId, confirmed: true, text: confirmText)
                    } else {
                        self.cancel(promptId: promptId, reason: "dialog cancelled")
                    }
                }

            case .text(let placeholder, let defaultText):
                let answerText = await TerminalDialogView.askText(
                    in: window,
                    title: prompt.title,
                    label: prompt.message,
                    value: defaultText,
                    hint: placeholder.isEmpty ? nil : placeholder,
                    confirm: "Submit",
                    cancel: "Cancel",
                    promptId: promptId,
                    theme: theme
                )
                if let answerText = answerText {
                    self.answerText(promptId: promptId, text: answerText)
                } else {
                    self.cancel(promptId: promptId, reason: "dialog cancelled")
                }
            }
        }
    }

    func presentNextDialogIfPossible(in window: NSWindow) {
        guard TerminalDialogView.pending(in: window) == nil else { return }
        for (id, prompt) in activePrompts {
            if let s = prompt.surface, s.window === window {
                presentDialogIfPossible(promptId: id, prompt: prompt, surface: s)
                break
            }
        }
    }

    /// Handles an incoming notification action or text input response from macOS notification center.
    func handleNotificationResponse(promptId: String, response: UNNotificationResponse) {
        guard let prompt = activePrompts[promptId] else { return }

        if response.actionIdentifier == UNNotificationDismissActionIdentifier {
            cancel(promptId: promptId, reason: "notification dismissed")
            return
        }

        if let textResponse = response as? UNTextInputNotificationResponse {
            let userText = textResponse.userText
            answerText(promptId: promptId, text: userText)
            return
        }

        if response.actionIdentifier == "confirm_yes" {
            if case .confirm(let confirmText, _) = prompt.type {
                answerConfirm(promptId: promptId, confirmed: true, text: confirmText)
            } else {
                answerConfirm(promptId: promptId, confirmed: true, text: "Confirm")
            }
            return
        }

        if response.actionIdentifier == "confirm_no" {
            cancel(promptId: promptId, reason: "cancelled by user")
            return
        }

        if response.actionIdentifier.hasPrefix("choice_") {
            let indexStr = String(response.actionIdentifier.dropFirst(7))
            if let idx = Int(indexStr) {
                answerChoice(promptId: promptId, index: idx)
                return
            }
        }

        // If the user clicked the notification banner body itself (default action):
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            if let surface = prompt.surface {
                NSApp.activate(ignoringOtherApps: true)
                ControlLayout.focus(surface)
            }
        }
    }
}
