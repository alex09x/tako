/*
 * tako — Shell scheme for SwiftUI chrome: re-resolve shell colours in place
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import SwiftUI

/// Shell colours are dynamic LivingTokens. Giving chrome the shell's colour
/// scheme as its environment makes SwiftUI resolve them again on a switch,
/// in place: no rebuilt identity, so search text, scroll and focus stay.
/// Only chrome gets it -- terminal surfaces keep the system appearance their
/// light/dark theme pairs follow.
struct ShellSchemeModifier: ViewModifier {
    @ObservedObject private var presentation = DesktopPresentation.shared

    func body(content: Content) -> some View {
        content.environment(\.colorScheme, presentation.isDark ? .dark : .light)
    }
}

extension View {
    func shellScheme() -> some View { modifier(ShellSchemeModifier()) }
}
