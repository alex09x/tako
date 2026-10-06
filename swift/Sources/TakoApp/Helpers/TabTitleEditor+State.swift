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

extension TabTitleEditor {
    struct TabUIState {
        /// Original hidden state for title labels that are temporarily hidden while editing.
        let labels: [(label: NSTextField, wasHidden: Bool)]
        /// Original hidden state for buttons that are temporarily hidden while editing.
        let buttons: [(button: NSButton, wasHidden: Bool)]
        /// Original button title state restored once editing finishes.
        let titleButton: (button: NSButton, title: String, attributedTitle: NSAttributedString?)?

        init(tabButton: NSView) {
            labels = tabButton
                .descendants(withClassName: "NSTextField")
                .compactMap { $0 as? NSTextField }
                .map { ($0, $0.isHidden) }
            buttons = tabButton
                .descendants(withClassName: "NSButton")
                .compactMap { $0 as? NSButton }
                .map { ($0, $0.isHidden) }
            if let button = tabButton as? NSButton {
                titleButton = (button, button.title, button.attributedTitle)
            } else {
                titleButton = nil
            }
        }

        func hide() {
            for (label, _) in labels {
                label.isHidden = true
            }
            for (btn, _) in buttons {
                btn.isHidden = true
            }
            titleButton?.button.title = ""
            titleButton?.button.attributedTitle = NSAttributedString(string: "")
        }

        func restore() {
            for (label, wasHidden) in labels {
                label.isHidden = wasHidden
            }
            for (btn, wasHidden) in buttons {
                btn.isHidden = wasHidden
            }
            if let titleButton {
                titleButton.button.title = titleButton.title
                if let attributedTitle = titleButton.attributedTitle {
                    titleButton.button.attributedTitle = attributedTitle
                }
            }
        }
    }
}
