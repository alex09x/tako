/*
 * tako — Persisted desktop presentation settings
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

extension TerminalSettingRegistry {
    static let desktopSettings: [TerminalSettingItem] = [
        .init(id: "app-appearance", title: "App Appearance", category: "Interface",
              type: .options(options: ["system", "light", "dark"], defaultValue: "system"),
              description: "Colors of the sidebar, workspace and settings, independent of terminal themes"),
        .init(id: "status-show", title: "Show Status Indicators", category: "Activity",
              type: .boolean(defaultValue: true),
              description: "Show status rings and borders; terminal status continues to be tracked when hidden"),
        .init(id: "status-animate", title: "Animate Status Indicators", category: "Activity",
              type: .boolean(defaultValue: true),
              description: "Animate visible status indicators; Reduce Motion always uses static indicators"),
        .init(id: "activity-alert", title: "Activity Sounds", category: "Activity",
              type: .options(options: ActivityAlertPolicy.allCases.map(\.rawValue), defaultValue: "unfocused"),
              description: "When a terminal that needs you, finishes or fails plays its sound: while you are not looking at it, always, or never"),
        .init(id: "activity-sound-needs-you", title: "Sound: Needs You", category: "Activity",
              type: .options(options: ActivitySounds.choices, defaultValue: ActivityEvent.needsYou.defaultSound),
              description: "A macOS system sound, or none"),
        .init(id: "activity-sound-done", title: "Sound: Done", category: "Activity",
              type: .options(options: ActivitySounds.choices, defaultValue: ActivityEvent.done.defaultSound),
              description: "A macOS system sound, or none"),
        .init(id: "activity-sound-failed", title: "Sound: Failed", category: "Activity",
              type: .options(options: ActivitySounds.choices, defaultValue: ActivityEvent.failed.defaultSound),
              description: "A macOS system sound, or none"),
        .init(id: "sidebar-style", title: "Sidebar Style", category: "Sidebar",
              type: .options(options: SidebarStyle.allCases.map(\.rawValue), defaultValue: "classic"),
              description: "How sessions look in the sidebar: classic (two lines), minimal (one line, more air) or compact (one small line)"),
        .init(id: "sidebar-group", title: "Group Sessions By", category: "Sidebar",
              type: .options(options: SidebarGrouping.allCases.map(\.rawValue), defaultValue: "workspace"),
              description: "Under their workspaces, or by what they need: Needs you, Running, Done, Quiet"),
        .init(id: "sidebar-text-size", title: "Sidebar Text Size", category: "Sidebar",
              type: .options(options: SidebarTextSize.allCases.map(\.rawValue), defaultValue: "default"),
              description: "Smaller or larger sidebar text, in any style"),
        .init(id: "sidebar-secondary-text", title: "Sidebar Second Line", category: "Sidebar",
              type: .options(options: SidebarSecondaryText.allCases.map(\.rawValue), defaultValue: "default"),
              description: "How strongly folders, branches and ports read; status colors stay"),
        .init(id: "sidebar-count-waiting", title: "Show Waiting Count", category: "Sidebar",
              type: .boolean(defaultValue: true), description: "Show how many terminals need a response"),
        .init(id: "sidebar-count-error", title: "Show Error Count", category: "Sidebar",
              type: .boolean(defaultValue: true), description: "Show how many terminals report an error"),
        .init(id: "sidebar-count-done", title: "Show Unread Completion Count", category: "Sidebar",
              type: .boolean(defaultValue: true), description: "Show finished terminals whose result has not been viewed"),
    ]
}
