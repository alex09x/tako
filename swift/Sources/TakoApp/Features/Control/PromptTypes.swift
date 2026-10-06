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

extension PromptManager {
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
}
