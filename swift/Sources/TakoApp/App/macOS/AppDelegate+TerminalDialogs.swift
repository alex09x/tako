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

extension AppDelegate {
    static func configureTerminalDialogHandlers() {
        TakoTerminalNSView.confirmOpenURL = { url, warning, window, completion in
            guard let targetWindow = window
                ?? AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows)
                ?? TerminalController.preferredParent?.window
                ?? NSApp.windows.first(where: { $0.isVisible }) else {
                completion(false)
                return
            }
            let theme = (NSApp.delegate as? AppDelegate)?.tako.config.theme
            Task { @MainActor in
                let title: String
                let lines: [TUIText.Line]
                let choices: [TerminalDialogView.Choice]
                let selected: Int
                let cancelIndex: Int

                switch warning {
                case .unsafeScheme(let scheme):
                    title = "Open External Application?"
                    lines = [
                        TUIText.Line(runs: [TUIText.Run(text: "This link uses the \"\(scheme)\" protocol:", kind: .plain)]),
                        TUIText.Line(runs: []),
                        TUIText.Line(runs: [TUIText.Run(text: url.absoluteString, kind: .bold)]),
                        TUIText.Line(runs: []),
                        TUIText.Line(runs: [TUIText.Run(text: "Opening it will launch an external application.", kind: .muted)])
                    ]
                    choices = [
                        .init(title: "Cancel", kind: .normal),
                        .init(title: "Open", kind: .primary)
                    ]
                    selected = 1
                    cancelIndex = 0

                case .urlMismatch(let displayedText, let targetURL):
                    title = "Suspicious Link Destination"
                    lines = [
                        TUIText.Line(runs: [TUIText.Run(text: "The visible link text appears to point to:", kind: .plain)]),
                        TUIText.Line(runs: [TUIText.Run(text: displayedText, kind: .muted)]),
                        TUIText.Line(runs: []),
                        TUIText.Line(runs: [TUIText.Run(text: "However, the real destination is:", kind: .plain)]),
                        TUIText.Line(runs: [TUIText.Run(text: targetURL.absoluteString, kind: .bold)]),
                        TUIText.Line(runs: []),
                        TUIText.Line(runs: [TUIText.Run(text: "Are you sure you want to open this link?", kind: .plain)])
                    ]
                    choices = [
                        .init(title: "Cancel", kind: .normal),
                        .init(title: "Open Anyway", kind: .destructive)
                    ]
                    selected = 0
                    cancelIndex = 0

                case .unconfirmedDestination(let targetURL):
                    title = "Open Link?"
                    lines = [
                        TUIText.Line(runs: [TUIText.Run(text: "Are you sure you want to open this link?", kind: .plain)]),
                        TUIText.Line(runs: []),
                        TUIText.Line(runs: [TUIText.Run(text: targetURL.absoluteString, kind: .bold)])
                    ]
                    choices = [
                        .init(title: "Cancel", kind: .normal),
                        .init(title: "Open", kind: .primary)
                    ]
                    selected = 1
                    cancelIndex = 0
                }

                let answer = await TerminalDialogView.choose(
                    in: targetWindow,
                    title: title,
                    lines: lines,
                    choices: choices,
                    selected: selected,
                    cancelIndex: cancelIndex,
                    theme: theme
                )
                if let answer {
                    completion(answer != cancelIndex && answer >= 0)
                } else {
                    completion(false)
                }
            }
        }

        TakoTerminalNSView.presentAlert = { alert, window in
            guard let targetWindow = window
                ?? AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows)
                ?? TerminalController.preferredParent?.window
                ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
            let theme = (NSApp.delegate as? AppDelegate)?.tako.config.theme
            Task { @MainActor in
                await TerminalDialogView.alert(
                    in: targetWindow,
                    title: alert.messageText,
                    message: alert.informativeText.isEmpty ? alert.messageText : alert.informativeText,
                    button: "OK",
                    theme: theme
                )
            }
        }
    }
}
