/*
 * tako — Theme font previews use the same faces as the terminal
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import CoreText

extension TerminalSettingsDialog {
    func typographyPreviewFont(family: String? = nil, size: CGFloat? = nil, face: String = "font-weight") -> NSFont {
        var sample = presetEditor?.effectiveTheme ?? scopedAppearance?.effectiveTheme
            ?? TerminalTheme.parse(config: configFile.rawConfigLines.joined(separator: "\n"), configPath: configFile.configPath)
        if let family { sample.fontFamily = family }
        sample.fontSize = size ?? style.font.pointSize
        let metrics = TerminalRenderer.Metrics(theme: sample)
        let font: CTFont
        switch face {
        case "font-weight-bold": font = metrics.boldFont
        case "font-weight-italic": font = metrics.italicFont
        case "font-weight-bold-italic": font = metrics.boldItalicFont
        default: font = metrics.font
        }
        // NSFont and CTFont are toll-free bridged on macOS. Recreating from
        // the PostScript name would discard this instance's variable axes.
        return unsafeBitCast(font, to: NSFont.self)
    }
}
