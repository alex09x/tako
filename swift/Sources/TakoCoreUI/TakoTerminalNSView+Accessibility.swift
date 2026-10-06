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

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

extension TakoTerminalNSView {
    func setupAccessibility() {
        setAccessibilityIdentifier("terminal")
    }

    override public func isAccessibilityElement() -> Bool { true }
    override public func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override public func accessibilityLabel() -> String? { "Terminal" }

    override public func accessibilityValue() -> Any? {
        plainText(startRow: 0, maxRows: rows)
    }

    override public func accessibilitySelectedText() -> String? {
        core.selectedText()
    }

    /// In UTF-16 units, as accessibility ranges are: a cluster counts once
    /// per unit, not once.
    override public func accessibilityNumberOfCharacters() -> Int {
        (accessibilityValue() as? String)?.utf16.count ?? 0
    }
}
#endif
