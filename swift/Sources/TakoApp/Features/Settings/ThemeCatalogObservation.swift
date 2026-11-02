/*
 * tako — Keep the open theme catalog in sync with CLI changes
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

@MainActor final class ThemeCatalogObservation {
    private weak var dialog: TerminalSettingsDialog?
    private var tokens: [NSObjectProtocol] = []

    init(dialog: TerminalSettingsDialog) {
        self.dialog = dialog
        for name in [Notification.Name.takoThemePresetsDidChange, .takoConfigDidChange, .takoScopedAppearanceDidChange] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                if Thread.isMainThread { MainActor.assumeIsolated { self?.refresh() } }
                else { DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } } }
            })
        }
    }

    private func refresh() {
        guard let dialog, !dialog.isWithdrawing else { return }
        dialog.configFile.reload()
        guard dialog.activeTab == .themes, dialog.presetEditor == nil else { return }
        dialog.themePreviews.removeAll()
        dialog.statusMessage = nil
        dialog.filterItems(dialog.searchField?.stringValue ?? "")
    }

    deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
}
