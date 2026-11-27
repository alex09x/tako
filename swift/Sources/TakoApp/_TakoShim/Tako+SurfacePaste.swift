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
import TakoCoreUI
import TakoKit

extension Tako.SurfaceView {
    func setupConfirmPasteHandler() {
        confirmPasteHandler = { [weak self] text, completion in
            guard let window = self?.window
                ?? AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows)
                ?? TerminalController.preferredParent?.window
                ?? NSApp.windows.first(where: { $0.isVisible }) else {
                completion(true)
                return
            }
            let theme = self?.theme ?? (NSApp.delegate as? AppDelegate)?.tako.config.theme
            let lineCount = text.components(separatedBy: .newlines).count
            let lines: [TUIText.Line] = [
                TUIText.Line(runs: [TUIText.Run(text: "The text to be pasted contains multiple lines or line breaks, and bracketed paste mode is disabled. Pasting it may execute commands immediately without confirmation.", kind: .plain)]),
                TUIText.Line(runs: []),
                TUIText.Line(runs: [TUIText.Run(text: "Lines: \(lineCount)   Characters: \(text.count)", kind: .muted)])
            ]
            Task { @MainActor in
                let answer = await TerminalDialogView.choose(
                    in: window,
                    title: "Confirm Multiline Paste",
                    lines: lines,
                    choices: [.init(title: "Cancel", kind: .normal), .init(title: "Paste", kind: .primary)],
                    selected: 1,
                    cancelIndex: 0,
                    theme: theme
                )
                completion(answer == 1)
            }
        }
    }

    func handleSafePaste(_ text: String) {
        let isMultiLine = text.contains("\n") || text.contains("\r")
        if safePaste && isMultiLine && core.cursorIsAtPrompt() && !isCommandRunning {
            NotificationCenter.default.post(
                name: Tako.Notification.confirmClipboard,
                object: self,
                userInfo: [
                    Tako.Notification.ConfirmClipboardStrKey: text,
                    Tako.Notification.ConfirmClipboardRequestKey: Tako.ClipboardRequest.paste,
                ]
            )
            return
        }
        pasteText(text)
    }

    func copyFinishedSelection() {
        guard copyOnSelect != .off, let text = core.selectedText(), !text.isEmpty else { return }
        var targets = [Self.selectionPasteboard]
        if copyOnSelect == .clipboard { targets.append(clipboard) }
        for pasteboard in targets {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
}
