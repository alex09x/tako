/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Cocoa

class TerminalToolbar: NSToolbar, NSToolbarDelegate {
    private let titleTextField = CenteredDynamicLabel(labelWithString: "Tako")

    var titleText: String {
        get {
            titleTextField.stringValue
        }

        set {
            titleTextField.stringValue = newValue
        }
    }

    var titleFont: NSFont? {
        get {
            titleTextField.font
        }

        set {
            titleTextField.font = newValue
        }
    }

    var titleIsHidden: Bool {
        get {
            titleTextField.isHidden
        }

        set {
            titleTextField.isHidden = newValue
        }
    }

    override init(identifier: NSToolbar.Identifier) {
        super.init(identifier: identifier)

        delegate = self
        centeredItemIdentifiers.insert(.titleText)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        var item: NSToolbarItem

        switch itemIdentifier {
        case .titleText:
            item = NSToolbarItem(itemIdentifier: .titleText)
            item.view = self.titleTextField
            item.visibilityPriority = .user

            // This ensures the title text field doesn't disappear when shrinking the view
            self.titleTextField.translatesAutoresizingMaskIntoConstraints = false
            self.titleTextField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            self.titleTextField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

            // Add constraints to the toolbar item's view
            NSLayoutConstraint.activate([
                // Set the height constraint to match the toolbar's height
                self.titleTextField.heightAnchor.constraint(equalToConstant: 22), // Adjust as needed
            ])

            item.isEnabled = true
        case .resetZoom:
            item = NSToolbarItem(itemIdentifier: .resetZoom)
        default:
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
        }

        return item
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [.titleText, .flexibleSpace, .space, .resetZoom]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // These space items are here to ensure that the title remains centered when it starts
        // getting smaller than the max size so starts clipping. Lucky for us, two of the
        // built-in spacers plus the un-zoom button item seems to exactly match the space
        // on the left that's reserved for the window buttons.
        return [.flexibleSpace, .titleText, .flexibleSpace]
    }
}
