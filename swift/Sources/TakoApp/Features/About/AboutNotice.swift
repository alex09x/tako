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

/// Presents an in-terminal "About Tako" card matching the TakoCore TUI palette,
/// displaying version details, build and commit information, project links, and quick actions.
@MainActor
enum AboutNotice {
    /// Formatted TUI lines for the About Tako dialog.
    static func lines(theme: TerminalTheme? = nil) -> [TUIText.Line] {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "0.1.8"
        let build = (info?["CFBundleVersion"] as? String) ?? ""
        let commit = (info?["TakoCommit"] as? String) ?? ""
        let copyright = (info?["NSHumanReadableCopyright"] as? String) ?? "Copyright © 2026 Alexander Panasenko"

        var buildRuns: [TUIText.Run] = [
            TUIText.Run(text: "Version:  ", kind: .muted),
            TUIText.Run(text: "v\(version)", kind: .bold)
        ]
        if !build.isEmpty {
            buildRuns.append(TUIText.Run(text: " (build \(build)", kind: .muted))
            if !commit.isEmpty {
                let shortCommit = String(commit.prefix(7))
                buildRuns.append(TUIText.Run(text: ", \(shortCommit)", kind: .muted))
            }
            buildRuns.append(TUIText.Run(text: ")", kind: .muted))
        }

        return [
            TUIText.Line(runs: [
                TUIText.Run(text: "Fast, native, GPU-accelerated terminal for macOS", kind: .bold)
            ]),
            TUIText.Line(runs: [
                TUIText.Run(text: "Powered by Rust and Metal", kind: .muted)
            ]),
            TUIText.Line(runs: []),
            TUIText.Line(runs: buildRuns),
            TUIText.Line(runs: [
                TUIText.Run(text: "Website:  ", kind: .muted),
                TUIText.Run(text: "https://takocore.com", kind: .plain)
            ]),
            TUIText.Line(runs: [
                TUIText.Run(text: "GitHub:   ", kind: .muted),
                TUIText.Run(text: "https://github.com/alex09x/tako", kind: .plain)
            ]),
            TUIText.Line(runs: []),
            TUIText.Line(runs: [
                TUIText.Run(text: copyright, kind: .muted)
            ])
        ]
    }

    /// Shows the About Tako dialog in the specified or frontmost terminal window.
    static func show(in window: NSWindow? = nil, theme: TerminalTheme? = nil) {
        guard let targetWindow = window ?? AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows) else {
            return
        }

        if let existing = TerminalDialogView.pending(in: targetWindow) {
            existing.withdraw()
            if existing.accessibilityLabel() == "About Tako" {
                return
            }
        }

        let activeTheme = theme ?? (NSApp.delegate as? AppDelegate)?.tako.config.theme
        let contentLines = lines(theme: activeTheme)

        Task { @MainActor in
            let answer = await TerminalDialogView.choose(
                in: targetWindow,
                title: "About Tako",
                lines: contentLines,
                choices: [
                    .init(title: "What's New", kind: .normal),
                    .init(title: "Settings & Hotkeys", kind: .normal),
                    .init(title: "GitHub", kind: .normal),
                    .init(title: "Check Updates", kind: .normal),
                    .init(title: "Close", kind: .primary)
                ],
                selected: 4,
                cancelIndex: 4,
                theme: activeTheme
            )

            switch answer {
            case 0:
                WhatsNewNotice.showWhatsNew(force: true, theme: activeTheme)
            case 1:
                TerminalSettingsDialog.show(in: targetWindow, theme: activeTheme)
            case 2:
                if let url = URL(string: "https://github.com/alex09x/tako") {
                    NSWorkspace.shared.open(url)
                }
            case 3:
                AppUpdater.shared.checkForUpdates(silent: false)
            default:
                break
            }
        }
    }
}
