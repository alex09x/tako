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
import TakoKit

/// Presents configuration errors as an in-terminal TUI card matching the TakoCore palette,
/// allowing the user to view diagnostics, open config, reload config, or ignore.
@MainActor
enum ConfigurationErrorsNotice {
    /// Formatted TUI lines for configuration errors.
    static func lines(errors: [String], width: Int = 62) -> [TUIText.Line] {
        var result: [TUIText.Line] = [
            TUIText.Line(runs: [
                TUIText.Run(text: "\(errors.count) error(s) found while loading configuration:", kind: .bold)
            ]),
            TUIText.Line(runs: [])
        ]

        for error in errors {
            let splitLines = error.components(separatedBy: "\n")
            for (idx, line) in splitLines.enumerated() {
                let prefix = idx == 0 ? "• " : "  "
                result.append(TUIText.Line(runs: [
                    TUIText.Run(text: prefix, kind: .muted),
                    TUIText.Run(text: line, kind: .plain)
                ]))
            }
        }

        result.append(TUIText.Line(runs: []))
        result.append(TUIText.Line(runs: [
            TUIText.Run(text: "Edit your configuration or reload after correcting errors.", kind: .muted)
        ]))

        return result
    }

    /// Shows configuration errors in the specified or frontmost terminal window.
    static func show(errors: [String], in window: NSWindow? = nil, theme: TerminalTheme? = nil) {
        guard !errors.isEmpty else { return }

        guard let targetWindow = window ?? AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows) else {
            // If no terminal window is available yet, wait briefly at launch or fall back
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let lateWindow = AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows) {
                    show(errors: errors, in: lateWindow, theme: theme)
                } else {
                    let c = ConfigurationErrorsController.sharedInstance
                    c.errors = errors
                    c.showWindow(nil)
                }
            }
            return
        }

        if let existing = TerminalDialogView.pending(in: targetWindow) {
            existing.withdraw()
        }

        let activeTheme = theme ?? (NSApp.delegate as? AppDelegate)?.tako.config.theme
        let contentLines = lines(errors: errors, width: 62)

        Task { @MainActor in
            let answer = await TerminalDialogView.choose(
                in: targetWindow,
                title: "Configuration Errors (\(errors.count))",
                lines: contentLines,
                choices: [
                    .init(title: "Ignore", kind: .normal),
                    .init(title: "Open Config", kind: .normal),
                    .init(title: "Reload Config", kind: .primary)
                ],
                selected: 2,
                cancelIndex: 0,
                theme: activeTheme
            )

            guard let answer else { return }
            switch answer {
            case 1:
                (NSApp.delegate as? AppDelegate)?.tako.openConfig()
            case 2:
                (NSApp.delegate as? AppDelegate)?.reloadConfig(nil)
            default:
                break
            }
        }
    }

    /// Dismisses any visible configuration error TUI dialog.
    static func dismiss(in window: NSWindow? = nil) {
        let target = window ?? AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows)
        if let target, let pending = TerminalDialogView.pending(in: target),
           pending.accessibilityLabel()?.hasPrefix("Configuration Errors") == true {
            pending.withdraw()
        }
    }
}
