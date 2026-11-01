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

@MainActor
enum SessionRecoveryPlacementChoice {
    enum WindowChoice {
        case existing(NSWindow)
        case newWindow
        case later
    }

    static func workspace(for record: SessionRecord, store: WorkspaceStore, window: NSWindow,
                          theme: TerminalTheme?) async -> UUID? {
        if let id = record.workspaceID, store.workspace(for: id) != nil { return id }
        if store.workspaces.count == 1 { return store.workspaces.first?.id }
        for workspace in store.workspaces {
            let message = "The previous workspace for session \(record.id.uuidString) is unknown. Restore it in \(workspace.name)?"
            let answer = await TerminalDialogView.choose(in: window, title: "Choose Workspace",
                lines: TUIText.plain(message, width: 56),
                choices: [.init(title: "Later", kind: .normal), .init(title: "Next", kind: .normal),
                          .init(title: "Use This", kind: .primary)], selected: 0, cancelIndex: 0, theme: theme)
            guard let answer, answer != 0 else { return nil }
            if answer == 2 { return workspace.id }
        }
        return nil
    }

    static func window(for decision: SessionRecoveryWindowPlacement.Decision, record: SessionRecord,
                       parent: NSWindow, theme: TerminalTheme?) async -> WindowChoice {
        switch decision {
        case .existing(let window): return .existing(window)
        case .newWindow: return .newWindow
        case .choose(let windows):
            for (index, window) in windows.enumerated() {
                let cleaned = String(window.title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(48))
                let title = cleaned.isEmpty ? "Untitled" : cleaned
                let message = "The previous window for session \(record.id.uuidString) is uncertain. Restore it in window \(index + 1) of \(windows.count), ‘\(title)’?"
                let answer = await TerminalDialogView.choose(in: parent, title: "Choose Window",
                    lines: TUIText.plain(message, width: 56),
                    choices: [.init(title: "Later", kind: .normal), .init(title: "Next", kind: .normal),
                              .init(title: "Use This", kind: .primary)], selected: 0, cancelIndex: 0, theme: theme)
                guard let answer, answer != 0 else { return .later }
                if answer == 2 { return .existing(window) }
            }
            let answer = await TerminalDialogView.choose(in: parent, title: "New Window",
                lines: TUIText.plain("Restore this session in a separate window?", width: 56),
                choices: [.init(title: "Later", kind: .normal), .init(title: "New Window", kind: .primary)],
                selected: 0, cancelIndex: 0, theme: theme)
            return answer == 1 ? .newWindow : .later
        }
    }
}
