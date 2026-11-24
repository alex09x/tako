/*
 * tako — Setup reentry from the in-terminal settings card
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

extension TerminalSettingsDialog {
    func setupFirstRunControl() {
        guard presetEditor == nil, scopedAppearance == nil else { return }
        let button = DialogButton(choice: .init(title: "Setup…", kind: .normal),
            style: .init(font: style.font, background: style.background, foreground: style.foreground,
                         accent: style.accent, accentEnd: style.accentEnd, muted: style.muted))
        button.target = self
        button.action = #selector(openFirstRunSetup)
        button.setAccessibilityIdentifier("SettingsSetupButton")
        addSubview(button)
    }

    func layoutFirstRunControl() {
        guard let button = subviews.first(where: { $0.accessibilityIdentifier() == "SettingsSetupButton" }) else { return }
        let origin = cell(3, totalRows - 3)
        button.frame = NSRect(x: origin.x, y: origin.y, width: 10 * cellWidth, height: cellHeight)
    }

    @objc private func openFirstRunSetup() {
        guard let window, let app = (window.windowController as? TerminalController)?.tako
            ?? (NSApp.delegate as? AppDelegate)?.tako else { return }
        withdraw()
        SetupCoordinator.shared.show(app: app, in: window)
    }
}
