import AppKit
import Foundation
import UserNotifications

/// Coordinates interactive prompts (`takoctl ask`) across terminal surface,
/// notification center, system desktop notifications, and terminal modal dialogs (B10).
@MainActor
final class PromptManager: NSObject {
    static let shared = PromptManager()

    enum PromptType: Equatable, Sendable {
        case choice(choices: [String])
        case confirm(confirmText: String, cancelText: String)
        case text(placeholder: String, defaultText: String)
    }

    struct PromptAnswer: Sendable {
        let answer: String
        let type: PromptType
        let confirmed: Bool?
        let choiceIndex: Int?
        let isDefault: Bool

        init(
            answer: String,
            type: PromptType,
            confirmed: Bool? = nil,
            choiceIndex: Int? = nil,
            isDefault: Bool = false
        ) {
            self.answer = answer
            self.type = type
            self.confirmed = confirmed
            self.choiceIndex = choiceIndex
            self.isDefault = isDefault
        }
    }

    struct ActivePrompt {
        let id: String
        let surfaceId: UUID
        let message: String
        let title: String
        let type: PromptType
        let defaultValue: String?
        let timeout: TimeInterval?
        let createdAt: Date
        let once: ControlCommands.OnceReply
        let clientGone: @Sendable () -> Bool
        weak var surface: Tako.SurfaceView?
        weak var dialog: TerminalDialogView?
    }

    private var activePrompts: [String: ActivePrompt] = [:]
    private var surfacePrompts: [UUID: Set<String>] = [:]
    private var timers: [String: Timer] = [:]
    private var registeredCategories: Set<String> = []

    var activeCount: Int { activePrompts.count }

    func activePrompt(for promptId: String) -> ActivePrompt? {
        activePrompts[promptId]
    }

    func activePrompts(for surfaceId: UUID) -> [ActivePrompt] {
        guard let ids = surfacePrompts[surfaceId] else { return [] }
        return ids.compactMap { activePrompts[$0] }
    }

    /// Resets all state and cancels all pending prompts (for tests/teardown).
    func reset() {
        for (id, prompt) in activePrompts {
            timers[id]?.invalidate()
            prompt.once.cancel(.failure(ControlError(.invalid, "reset")))
            prompt.dialog?.removeFromSuperview()
            prompt.surface?.crab.clearStatus()
        }
        timers.removeAll()
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

    private func checkPromptLiveness(promptId: String, timer: Timer) {
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

    private func handleTimeout(promptId: String) {
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

    private func postSystemNotification(promptId: String, prompt: ActivePrompt, surface: Tako.SurfaceView) {
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

    private func presentDialogIfPossible(promptId: String, prompt: ActivePrompt, surface: Tako.SurfaceView) {
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

    private func presentNextDialogIfPossible(in window: NSWindow) {
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

    private func resolve(promptId: String, result: Result<PromptAnswer, ControlError>) {
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
