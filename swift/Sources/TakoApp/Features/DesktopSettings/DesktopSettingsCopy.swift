/*
 * tako — Desktop settings wording: the reference's titles, explanations and option labels
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// People-facing text for registry keys, from the frozen reference's PF_SET
/// (prefs-model.js and prefs-detail.js). Keys and values stay the registry's.
struct DesktopSettingCopy {
    let title: String
    var detail = ""
    /// When the change takes effect, shown after the key: «key · immediately».
    var when = "immediately"
    /// Option value → label, in display order; empty for booleans and numbers.
    var options: [(value: String, label: String)] = []
    var unit = ""
    /// Section the reference shows the row in (registry categories differ).
    let section: DesktopSettingsSection

    static func of(_ key: String) -> DesktopSettingCopy? { catalog[key] }

    private static let statusColors: [(String, String)] = [
        ("working", "Working"), ("waiting", "Waiting for input or approval"), ("done", "Done"),
        ("error", "Error"), ("idle", "Idle or disconnected"),
    ]

    static let catalog: [String: DesktopSettingCopy] = {
        var c: [String: DesktopSettingCopy] = [
            "confirm-close-surface": .init(title: "Confirm before closing",
                detail: "Ask before closing a terminal or tab with a running process.",
            options: [("true", "When Running"), ("always", "Always"), ("false", "Never")], section: .general),
            "window-inherit-working-directory": .init(title: "Open terminals in the current directory",
                detail: "New tabs and split panes start in the current terminal’s directory.",
                when: "For new terminals", section: .general),
            "window-inherit-font-size": .init(title: "Inherit font size in new windows",
                detail: "New windows inherit the current terminal’s font size, including zoom.", when: "For new windows", section: .general),
            "app-appearance": .init(title: "App Appearance",
                detail: "Colors the sidebar, canvas, menus and settings independently of terminal themes.",
                options: [("system", "System"), ("light", "Light"), ("dark", "Dark")], section: .interface),
            "sidebar-style": .init(title: "Sidebar style",
                detail: "Classic: two lines per session. Minimal: one line unless a session needs you, more air. Compact: one small line, the most sessions on screen.",
                options: [("classic", "Classic"), ("minimal", "Minimal"), ("compact", "Compact")], section: .interface),
            "sidebar-group": .init(title: "Group sessions by",
                detail: "Status puts what needs you first — Needs you, Running, Done, Quiet — and shows the workspace as a colored dot.",
                options: [("workspace", "Workspace"), ("status", "Status")], section: .interface),
            "cursor-style": .init(title: "Cursor shape", detail: "A cursor shape set by the terminal theme takes precedence.",
                options: [("block", "Block"), ("bar", "Bar"), ("underline", "Underline")], section: .input),
            "cursor-style-blink": .init(title: "Blink cursor", section: .input),
            "mouse-hide-while-typing": .init(title: "Hide pointer while typing", section: .input),
            "copy-on-select": .init(title: "Copy selected text",
                detail: "Paste the selection with ⇧⌘V, or paste the clipboard with ⌘V.",
                options: [("true", "To the selection buffer"), ("clipboard", "To the clipboard"), ("false", "None")], section: .input),
            "safe-paste": .init(title: "Confirm multiline paste",
                detail: "Ask before pasting multiple lines into a shell prompt.", section: .input),
            "shell-integration": .init(title: "Shell integration",
                detail: "Adds command markers, prompt navigation and durations. Preserves explicit launch commands and does not install on remote hosts.",
                when: "For new terminals",
                options: [("detect", "Automatic"), ("zsh", "zsh"), ("fish", "fish"), ("bash", "bash"), ("none", "Off")], section: .input),
            "workspace-sync-window-frame": .init(title: "Keep window position across workspaces",
                detail: "Keep the window’s position and size when switching workspaces.", when: "On the next switch",
                section: .windows),
            "background-blur": .init(title: "Background blur", detail: "Set to 0 to disable. Visible when the terminal background is transparent.",
                unit: "px", section: .windows),
            "quick-terminal-position": .init(title: "Position", when: "The next time it opens",
                options: [("top", "Top"), ("bottom", "Bottom"), ("left", "Left"), ("right", "Right"), ("center", "Center")],
                section: .quickTerminal),
            "quick-terminal-autohide": .init(title: "Hide when focus moves to another window", section: .quickTerminal),
            "status-show": .init(title: "Show status indicators",
                detail: "Show status rings, colored borders and error indicators. Turning these off preserves status tracking and history.",
                section: .status),
            "status-animate": .init(title: "Animate status indicators",
                detail: "Animate working and waiting indicators. Turn off for static colors. macOS Reduce Motion always keeps them static.",
                section: .status),
            "sidebar-count-waiting": .init(title: "Waiting count",
                detail: "Terminals where an agent is waiting for input or approval.", section: .status),
            "sidebar-count-error": .init(title: "Error count",
                detail: "Terminals where a command exited with an error.", section: .status),
            "sidebar-count-done": .init(title: "Unread completion count",
                detail: "Terminals with completed work you have not viewed yet.", section: .status),
        ]
        for (state, title) in statusColors {
            c["tab-status-color-\(state)"] = .init(title: title, section: .status)
        }
        return c
    }()
}
