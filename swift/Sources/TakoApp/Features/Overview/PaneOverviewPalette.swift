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

/// Color palette for the Pane Overview modal and cards, backed by `Tako.LivingTokens` (Spec 1b §0 & §6).
enum PaneOverviewPalette {
    static let modalBackground = Tako.LivingTokens.chrome
    static let modalBorder = Tako.LivingTokens.hairline
    static let cardBackground = Tako.LivingTokens.surfaceActive
    static let selectedCardBackground = Tako.LivingTokens.surfaceActive
    static let terminalBackground = Tako.LivingTokens.body
    static let terminalText = Tako.LivingTokens.text
    static let activeText = Tako.LivingTokens.textActive
    static let inactiveText = Tako.LivingTokens.textInactive
    static let dim = Tako.LivingTokens.dim
    static let faint = Tako.LivingTokens.faint
    static let hairline = Tako.LivingTokens.hairline
    static let searchBackground = Tako.LivingTokens.body
    static let badge = Tako.LivingTokens.badge
    static let buttonBackground = Tako.LivingTokens.badge
    static let progressGradientStart = Tako.LivingTokens.rust
    static let progressGradientEnd = Tako.LivingTokens.ember
}
