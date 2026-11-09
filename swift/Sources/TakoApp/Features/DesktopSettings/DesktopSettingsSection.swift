/*
 * tako — Native settings sections and the settings/actions/fonts search index
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

enum DesktopSettingsSection: String, CaseIterable, Identifiable {
    case general, interface, terminalAppearance, input, windows, quickTerminal
    case status, keys, agents, notifications, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "Основные"
        case .interface: "Интерфейс"
        case .terminalAppearance: "Оформление терминала"
        case .input: "Input & Cursor"
        case .windows: "Окна и пространства"
        case .quickTerminal: "Быстрый терминал"
        case .status: "Status & Activity"
        case .keys: "Сочетания клавиш"
        case .agents: "Agents"
        case .notifications: "Уведомления и доступ"
        case .advanced: "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .interface: "macwindow"
        case .terminalAppearance: "paintpalette"
        case .input: "character.cursor.ibeam"
        case .windows: "rectangle.3.group"
        case .quickTerminal: "rectangle.topthird.inset.filled"
        case .status: "circle.dotted.circle"
        case .keys: "keyboard"
        case .agents: "sparkles"
        case .notifications: "bell.badge"
        case .advanced: "doc.text"
        }
    }

    /// Registry categories whose settings this section edits.
    var registryCategories: Set<String> {
        switch self {
        case .interface: ["Interface", "Sidebar"]
        case .terminalAppearance: ["Appearance"]
        case .input: ["Terminal"]
        case .windows: ["Window", "Workspaces"]
        case .quickTerminal: ["Quick Terminal"]
        case .status: ["Activity"]
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
        for item in settings where !seen.contains(item.id) && hit(item.title, item.id, item.description) {
            seen.insert(item.id)
            results.append(.init(title: item.title, detail: item.id,
                                 section: .section(forCategory: item.category), kind: .setting(item.id)))
        }
        for action in actions where hit(action.title, action.id) {
            results.append(.init(title: action.title, detail: action.id, section: .keys, kind: .action(action.id)))
        }
        for font in fonts where hit(font) {
            results.append(.init(title: font, detail: "Font", section: .terminalAppearance, kind: .font(font)))
        }
        return results
    }
}
