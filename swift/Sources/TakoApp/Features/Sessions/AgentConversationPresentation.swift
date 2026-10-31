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

@MainActor
enum AgentConversationPresentation {
    private static var warnedAboutSaveFailure = false

    static func warnAboutSaveFailure(in window: NSWindow?) {
        guard !warnedAboutSaveFailure, let window,
              let app = (NSApp.delegate as? AppDelegate)?.tako else { return }
        warnedAboutSaveFailure = true
        Task { @MainActor in
            _ = await TerminalDialogView.choose(in: window, title: "Agent Conversation Not Saved",
                lines: TUIText.plain("Tako could not save an observed conversation ID. Check storage before relying on recovery.", width: 56),
                choices: [.init(title: "OK", kind: .normal)], cancelIndex: 0, theme: app.config.theme)
        }
    }

    static func show(app: Tako.App) {
        guard let window = AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows)
                ?? TerminalController.preferredParent?.window else { return }
        Task { @MainActor in
            let entries: [AgentConversationStore.Entry]
            do { entries = try AgentConversationStore.shared.entries() }
            catch {
                _ = await TerminalDialogView.choose(in: window, title: "Agent Conversations Unavailable",
                    lines: TUIText.plain("Tako could not safely read the saved conversation IDs. Check storage and try again.", width: 56),
                    choices: [.init(title: "OK", kind: .normal)], cancelIndex: 0, theme: app.config.theme)
                return
            }
            guard !entries.isEmpty else {
                _ = await TerminalDialogView.choose(in: window, title: "Agent Conversations",
                    lines: TUIText.plain("No agent conversation IDs have been observed yet.", width: 56),
                    choices: [.init(title: "OK", kind: .normal)], cancelIndex: 0, theme: app.config.theme)
                return
            }
            for (index, entry) in entries.enumerated() {
                let message = "Observed conversation \(index + 1) of \(entries.count). Pane: \(entry.surface.uuidString). Provider: \(entry.provider). ID: \(entry.sessionID). This is a candidate; it may still be running."
                let choice = await TerminalDialogView.choose(in: window, title: "Agent Conversations",
                    lines: TUIText.plain(message, width: 56),
                    choices: [.init(title: "Close", kind: .normal), .init(title: "Next", kind: .normal),
                              .init(title: "Copy Resume Command", kind: .primary)],
                    selected: 0, cancelIndex: 0, theme: app.config.theme)
                if choice == 0 || choice == nil { break }
                if choice == 2 {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.resumeCommand, forType: .string)
                    break
                }
            }
        }
    }
}
