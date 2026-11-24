/*
 * tako — Native settings sections and the settings/actions/fonts search index
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// The reference's section list (prefs-detail.js PF_SECS). Raw values are the
/// accessibility suffixes: `DesktopSettingsSection-<rawValue>`.
enum DesktopSettingsSection: String, CaseIterable, Identifiable {
    case general
    case interface
    case terminalAppearance = "appearance"
    case input
    case windows
    case quickTerminal
    case status = "activity"
    case keys, agents, notifications, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .interface: "App Appearance"
        case .terminalAppearance: "Terminal Appearance"
        case .input: "Input & Cursor"
        case .windows: "Windows & Workspaces"
        case .quickTerminal: "Quick Terminal"
        case .status: "Status & Activity"
        case .keys: "Keyboard Shortcuts"
        case .agents: "Agents"
        case .notifications: "Notifications & Permissions"
        case .advanced: "Advanced"
        }
    }

    /// The line under the title; appearance shows its level chips instead,
    /// agents and permissions carry their own lead.
    var subtitle: String? {
        switch self {
        case .terminalAppearance, .agents, .notifications: nil
        default: "Application settings for all workspaces and terminals"
        }
    }

    /// SF Symbols closest to the reference's line icons (PF_IC).
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .interface: "sidebar.left"
        case .terminalAppearance: "paintpalette"
        case .input: "apple.terminal"
        case .windows: "macwindow"
        case .quickTerminal: "menubar.dock.rectangle"
        case .status: "smallcircle.filled.circle"
        case .keys: "keyboard"
        case .agents: "star"
        case .notifications: "checkmark.shield"
        case .advanced: "slider.horizontal.3"
        }
    }

    /// Registry categories whose settings this section edits.
    var registryCategories: Set<String> {
        switch self {
        case .interface: ["Interface"]
        case .terminalAppearance: ["Appearance"]
        case .input: ["Terminal"]
        case .windows: ["Window", "Workspaces"]
        case .quickTerminal: ["Quick Terminal"]
        case .status: ["Activity", "Sidebar", "Tab Status Colors"]
        default: []
        }
    }

    var keywords: [String] {
        switch self {
        case .general: ["version", "version", "configuration"]
        case .interface: ["app appearance", "appearance", "light", "dark", "sidebar"]
        case .terminalAppearance: ["theme", "theme", "font", "font", "color", "color", "size"]
        case .input: ["cursor", "cursor", "mouse", "paste", "paste"]
        case .windows: ["window", "window", "tab", "tab", "workspace"]
        case .quickTerminal: ["quick", "quick"]
        case .status: ["status", "status", "animation", "count"]
        case .keys: ["shortcut", "keybind", "keys", "shortcut"]
        case .agents: ["agent", "agent", "hooks"]
        case .notifications: ["notification", "notifications", "permission", "permission"]
        case .advanced: ["config", "file", "reload", "errors"]
        }
    }

    static func section(forCategory category: String) -> DesktopSettingsSection {
        allCases.first { $0.registryCategories.contains(category) } ?? .advanced
    }
}

struct DesktopSettingsSearchResult: Identifiable, Equatable {
    enum Kind: Equatable { case section, setting(String), action(String), font(String) }
    let title: String
    let detail: String
    let section: DesktopSettingsSection
    let kind: Kind
    var id: String { "\(section.rawValue)|\(title)|\(detail)" }
}

/// Searches the real registries: sections, persisted settings, keybinding
/// actions and installed font families. Nothing here is sample data.
enum DesktopSettingsSearch {
    static func results(_ query: String, fonts: [String],
                        settings: [TerminalSettingItem] = TerminalSettingRegistry.allSettings,
                        actions: [KeybindActionItem] = KeybindRegistry.allActions) -> [DesktopSettingsSearchResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        func hit(_ values: String...) -> Bool { values.contains { $0.lowercased().contains(needle) } }
        var results: [DesktopSettingsSearchResult] = []
        for section in DesktopSettingsSection.allCases where hit(section.title, section.rawValue)
            || section.keywords.contains(where: { $0.contains(needle) }) {
            results.append(.init(title: section.title, detail: "Section", section: section, kind: .section))
        }
        var seen: Set<String> = []
        for item in settings where !seen.contains(item.id) {
            let copy = DesktopSettingCopy.of(item.id)
            guard hit(item.title, item.id, item.description, copy?.title ?? "", copy?.detail ?? "") else { continue }
            seen.insert(item.id)
            results.append(.init(title: copy?.title ?? item.title, detail: item.id,
                                 section: copy?.section ?? .section(forCategory: item.category), kind: .setting(item.id)))
        }
        for action in actions where DesktopKeysCopy.searchTexts(action.id, current: nil).contains(where: { hit($0) }) {
            results.append(.init(title: DesktopKeysCopy.title(action.id), detail: action.id, section: .keys, kind: .action(action.id)))
        }
        for font in fonts where hit(font) {
            results.append(.init(title: font, detail: "Font", section: .terminalAppearance, kind: .font(font)))
        }
        return results
    }
}
