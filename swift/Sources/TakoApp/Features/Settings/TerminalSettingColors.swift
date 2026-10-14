/*
 * tako — Settings color registry
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

extension TerminalSettingRegistry {
    static let colorSettings: [TerminalSettingItem] = [
        .init(id: "background", title: "Terminal Background Color", category: "Terminal Colors",
              type: .color(defaultValue: "#14100e"), description: "Background color; Enter to edit HEX, D to restore theme"),
        .init(id: "foreground", title: "Terminal Text Color", category: "Terminal Colors",
              type: .color(defaultValue: "#ede6df"), description: "Default text color; Enter to edit HEX, D to restore theme"),
        .init(id: "cursor-color", title: "Terminal Cursor Color", category: "Terminal Colors",
              type: .color(defaultValue: "#f4581c"), description: "Cursor color; Enter to edit HEX, D to restore theme"),
        .init(id: "selection-background", title: "Terminal Selection Color", category: "Terminal Colors",
              type: .color(defaultValue: "#352b23"), description: "Selection background; Enter to edit HEX, D to restore theme"),
        .init(id: "tab-status-color-working", title: "Tab Working Color", category: "Tab Status Colors",
              type: .color(defaultValue: "#f4581c"), description: "Agent working / running; Enter to edit HEX"),
        .init(id: "tab-status-color-waiting", title: "Tab Waiting / Approval Color", category: "Tab Status Colors",
              type: .color(defaultValue: "#ff7a3d"), description: "Waiting for input, approval, or attention; Enter to edit HEX"),
        .init(id: "tab-status-color-done", title: "Tab Done Color", category: "Tab Status Colors",
              type: .color(defaultValue: "#7bd88f"), description: "Completed with unread output; Enter to edit HEX"),
        .init(id: "tab-status-color-error", title: "Tab Error Color", category: "Tab Status Colors",
              type: .color(defaultValue: "#d54e53"), description: "Failed / error; Enter to edit HEX"),
        .init(id: "tab-status-color-idle", title: "Tab Idle / Disconnected Color", category: "Tab Status Colors",
              type: .color(defaultValue: "#8a7f76"), description: "Idle, acknowledged, or disconnected; Enter to edit HEX"),
    ]
}
