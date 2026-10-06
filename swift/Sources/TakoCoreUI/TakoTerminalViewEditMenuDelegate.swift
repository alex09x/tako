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

#if canImport(UIKit)
import UIKit

/// Backing delegate for `TakoTerminalView`'s `UIEditMenuInteraction`.
@available(iOS 16.0, *)
@MainActor
final class TakoTerminalViewEditMenuDelegate: NSObject, UIEditMenuInteractionDelegate {
    private weak var terminalView: TakoTerminalView?

    init(terminalView: TakoTerminalView) {
        self.terminalView = terminalView
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard let terminalView, terminalView.core.hasSelection() else {
            return UIMenu(children: [])
        }
        let copyAction = UIAction(title: "Copy") { [weak terminalView] _ in
            terminalView?.copy(nil)
        }
        return UIMenu(children: [copyAction])
    }
}
#endif
