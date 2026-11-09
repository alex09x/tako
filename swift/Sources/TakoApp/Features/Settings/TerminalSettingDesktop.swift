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
        .init(id: "sidebar-count-waiting", title: "Show Waiting Count", category: "Sidebar",
              type: .boolean(defaultValue: true), description: "Show how many terminals need a response"),
        .init(id: "sidebar-count-error", title: "Show Error Count", category: "Sidebar",
              type: .boolean(defaultValue: true), description: "Show how many terminals report an error"),
        .init(id: "sidebar-count-done", title: "Show Unread Completion Count", category: "Sidebar",
              type: .boolean(defaultValue: true), description: "Show finished terminals whose result has not been viewed"),
    ]
}
