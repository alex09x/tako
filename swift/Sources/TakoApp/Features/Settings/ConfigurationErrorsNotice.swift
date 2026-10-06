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
    private static var pendingErrors: [String]?
    private static var pendingTheme: TerminalTheme?
    private static var keyWindowObserver: NSObjectProtocol?
    private static var retryCount = 0

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
    /// Never falls back to a native Cocoa window; queues presentation until a terminal window is ready.
    static func show(errors: [String], in window: NSWindow? = nil, theme: TerminalTheme? = nil) {
        guard !errors.isEmpty else {
            dismiss(in: window)
            return
        }

        guard let targetWindow = window ?? AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows) else {
            // Queue pending errors and wait for a terminal window to become available
            pendingErrors = errors
            pendingTheme = theme
            startAwaitingWindow()
            return
        }

        stopAwaitingWindow()
        present(errors: errors, in: targetWindow, theme: theme)
    }

    private static func startAwaitingWindow() {
        guard keyWindowObserver == nil else { return }
        retryCount = 0
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            checkAwaitingWindow()
        }
        scheduleRetry()
    }

    private static func scheduleRetry() {
        guard retryCount < 10 else { return }
        retryCount += 1
        let delay: TimeInterval = retryCount < 4 ? 0.25 : 0.6
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            checkAwaitingWindow()
        }
    }

    private static func checkAwaitingWindow() {
        guard let errors = pendingErrors, !errors.isEmpty else {
            stopAwaitingWindow()
            return
        }
        if let window = AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows) {
            let theme = pendingTheme
            stopAwaitingWindow()
            present(errors: errors, in: window, theme: theme)
        } else if retryCount < 10 {
            scheduleRetry()
        }
    }

    private static func stopAwaitingWindow() {
        if let observer = keyWindowObserver {
            NotificationCenter.default.removeObserver(observer)
            keyWindowObserver = nil
        }
        pendingErrors = nil
        pendingTheme = nil
        retryCount = 0
    }

    private static func present(errors: [String], in targetWindow: NSWindow, theme: TerminalTheme?) {
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

    /// Dismisses any visible configuration error TUI dialog and clears the pending queue.
    static func dismiss(in window: NSWindow? = nil) {
        stopAwaitingWindow()
        let targets = window != nil ? [window!] : NSApp.windows
        for target in targets {
            if let pending = TerminalDialogView.pending(in: target),
               pending.accessibilityLabel()?.hasPrefix("Configuration Errors") == true {
                pending.withdraw()
            }
        }
    }
}
