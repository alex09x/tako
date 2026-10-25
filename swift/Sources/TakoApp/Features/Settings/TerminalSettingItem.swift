/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

public enum TerminalSettingType: Equatable, Sendable {
    case boolean(defaultValue: Bool)
    case options(options: [String], defaultValue: String)
    case number(defaultValue: Int, min: Int, max: Int, step: Int)
    case color(defaultValue: String)

    public var defaultStringValue: String {
        switch self {
        case .boolean(let def):
            return def ? "true" : "false"
        case .options(_, let def):
            return def
        case .number(let def, _, _, _):
            return String(def)
        case .color(let def):
            return def
        }
    }

    public func nextValue(current: String) -> String {
        switch self {
        case .color: return current
        case .boolean:
            let isTrue = current.lowercased() == "true" || current == "1"
            return isTrue ? "false" : "true"
        case .options(let opts, let def):
            guard !opts.isEmpty else { return def }
            if let idx = opts.firstIndex(of: current) {
                let nextIdx = (idx + 1) % opts.count
                return opts[nextIdx]
            }
            return opts.first ?? def
        case .number(_, let minVal, let maxVal, let step):
            let effectiveMin = min(minVal, maxVal)
            let effectiveMax = max(minVal, maxVal)
            let safeStep = max(1, step)
            guard let rawVal = Int(current) else {
                return String(effectiveMin)
            }
            let clamped = min(max(rawVal, effectiveMin), effectiveMax)
            let (nextVal, overflow) = clamped.addingReportingOverflow(safeStep)
            if overflow || nextVal > effectiveMax {
                return String(effectiveMin)
            }
            return String(nextVal)
        }
    }

    public func previousValue(current: String) -> String {
        switch self {
        case .color: return current
        case .boolean:
            return nextValue(current: current)
        case .options(let opts, let def):
            guard !opts.isEmpty else { return def }
            if let idx = opts.firstIndex(of: current) {
                let prevIdx = (idx - 1 + opts.count) % opts.count
                return opts[prevIdx]
            }
            return opts.last ?? def
        case .number(_, let minVal, let maxVal, let step):
            let effectiveMin = min(minVal, maxVal)
            let effectiveMax = max(minVal, maxVal)
            let safeStep = max(1, step)
            guard let rawVal = Int(current) else {
                return String(effectiveMax)
            }
            let clamped = min(max(rawVal, effectiveMin), effectiveMax)
            let (prevVal, overflow) = clamped.subtractingReportingOverflow(safeStep)
            if overflow || prevVal < effectiveMin {
                return String(effectiveMax)
            }
            return String(prevVal)
        }
    }
}

public struct TerminalSettingItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let category: String
    public let type: TerminalSettingType
    public let description: String
    public let aliases: [String]

    public init(
        id: String,
        title: String,
        category: String,
        type: TerminalSettingType,
        description: String = "",
        aliases: [String] = []
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.type = type
        self.description = description
        self.aliases = aliases
    }
}

public enum TerminalSettingRegistry {
    public static let allSettings: [TerminalSettingItem] = [
        // Workspaces
        TerminalSettingItem(
            id: "workspace-sync-window-frame",
            title: "Sync Window Frame on Workspace Switch",
            category: "Workspaces",
            type: .boolean(defaultValue: false),
            description: "Synchronize window position and size from the previous workspace",
            aliases: ["workspace-inherit-window-frame"]
        ),

        // Window & Tabs
        TerminalSettingItem(
            id: "tab-style",
            title: "Tab Bar Style",
            category: "Window",
            type: .options(options: ["pill", "classic"], defaultValue: "pill"),
            description: "Visual appearance of tabs (floating pills vs classic tabs)"
        ),
        TerminalSettingItem(
            id: "window-inherit-font-size",
            title: "New Windows Inherit Font Size",
            category: "Window",
            type: .boolean(defaultValue: true),
            description: "Inherit zoom / font size when opening a new window"
        ),
        TerminalSettingItem(
            id: "window-inherit-working-directory",
            title: "New Tabs Inherit Directory",
            category: "Window",
            type: .boolean(defaultValue: true),
            description: "Inherit working directory when opening a new tab or split"
        ),

        // Terminal Behavior
        TerminalSettingItem(
            id: "cursor-style",
            title: "Cursor Style",
            category: "Terminal",
            type: .options(options: ["block", "bar", "underline"], defaultValue: "block"),
            description: "Terminal text cursor appearance"
        ),
        TerminalSettingItem(
            id: "cursor-style-blink",
            title: "Cursor Blinking",
            category: "Terminal",
            type: .boolean(defaultValue: false),
            description: "Animate terminal cursor blinking"
        ),
        TerminalSettingItem(
            id: "mouse-hide-while-typing",
            title: "Hide Mouse While Typing",
            category: "Terminal",
            type: .boolean(defaultValue: false),
            description: "Hide mouse cursor while typing in the terminal"
        ),
        TerminalSettingItem(
            id: "copy-on-select",
            title: "Copy to Clipboard on Select",
            category: "Terminal",
            type: .options(options: ["true", "clipboard", "false"], defaultValue: "true"),
            description: "Automatically copy highlighted text (true = selection, clipboard, false = off)"
        ),
        TerminalSettingItem(
            id: "confirm-close-surface",
            title: "Confirm Closing Running Commands",
            category: "Terminal",
            type: .options(options: ["true", "always", "false"], defaultValue: "true"),
            description: "Prompt for confirmation before closing tabs (true = when busy, always, false = never)"
        ),
        TerminalSettingItem(
            id: "safe-paste",
            title: "Confirm Multi-line Paste",
            category: "Terminal",
            type: .boolean(defaultValue: true),
            description: "Ask before pasting several lines at a shell prompt (off = paste straight in)"
        ),
        TerminalSettingItem(
            id: "shell-integration",
            title: "Shell Integration",
            category: "Terminal",
            type: .options(options: ["detect", "none", "bash", "zsh", "fish"], defaultValue: "detect"),
            description: "Shell integration for prompt marks, jump to prompt, and command timing"
        ),

        // Quick Terminal
        TerminalSettingItem(
            id: "quick-terminal-position",
            title: "Quick Terminal Position",
            category: "Quick Terminal",
            type: .options(options: ["top", "bottom", "left", "right", "center"], defaultValue: "top"),
            description: "Screen anchor for the dropdown Quick Terminal"
        ),
        TerminalSettingItem(
            id: "quick-terminal-autohide",
            title: "Quick Terminal Auto-Hide",
            category: "Quick Terminal",
            type: .boolean(defaultValue: true),
            description: "Hide Quick Terminal automatically when losing focus"
        ),

        // Appearance
        TerminalSettingItem(
            id: "theme",
            title: "Color Theme",
            category: "Appearance",
            type: .options(options: ["tako", "tokyonight", "catppuccin-mocha", "dracula", "nord", "solarized-dark", "solarized-light"], defaultValue: "tako"),
            description: "Color scheme and syntax highlighting"
        ),
        TerminalSettingItem(
            id: "font-size",
            title: "Base Font Size",
            category: "Appearance",
            type: .number(defaultValue: 13, min: 9, max: 28, step: 1),
            description: "Default font size in points"
        ),
        TerminalSettingItem(
            id: "background-blur",
            title: "Background Blur",
            category: "Appearance",
            type: .number(defaultValue: 0, min: 0, max: 60, step: 5),
            description: "Window background blur radius in pixels (0 = disabled)"
        ),
    ] + colorSettings

    public static func setting(for id: String) -> TerminalSettingItem? {
        allSettings.first { $0.id == id || $0.aliases.contains(id) }
    }
}
