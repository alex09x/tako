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
enum ClipboardPasteDialog {
    static func choose(in window: NSWindow, contents: String, theme: TerminalTheme?) async -> ClipboardConfirmationView.Action {
        let limit = 16_384
        let preview = String(contents.prefix(limit)).replacingOccurrences(of: "\r", with: "␍")
        var lines = TUIText.plain("Pasting this text to the terminal may be dangerous.", width: 52)
        lines.append(TUIText.Line(runs: []))
        lines += TUIText.plain(preview, width: 52)
        if contents.count > limit {
            lines.append(TUIText.Line(runs: [TUIText.Run(text: "… preview truncated", kind: .muted)]))
        }
        let answer = await TerminalDialogView.choose(
            in: window, title: "Confirm Paste", lines: lines,
            choices: [.init(title: "Cancel", kind: .normal),
                      .init(title: "Always Paste", kind: .normal),
                      .init(title: "Paste", kind: .primary)],
            selected: 2, cancelIndex: 0, theme: theme)
        switch answer {
        case 1: return .confirmAlways
        case 2: return .confirm
        default: return .cancel
        }
    }
}
