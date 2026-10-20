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
import SwiftUI

/// The text right of a sidebar row's title, drawn like the pill's: the
/// timer dim, a live program's name dim, an exit code in a red chip
/// (Sessions UI 5a).
struct SessionSidebarMetaLabel: View {
    let text: String
    let style: Tako.TabBarView.PillMetaStyle

    private typealias T = Tako.LivingTokens

    var body: some View {
        switch style {
        case .dim:
            Text(text)
                .font(Font(T.monoFont(size: 10, weight: .regular)))
                .foregroundColor(Color(nsColor: T.dim))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        case .exitCode:
            Text(text)
                .font(Font(T.monoFont(size: 9.5, weight: .semibold)))
                .foregroundColor(Color(nsColor: T.error))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: T.error).opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: T.error).opacity(0.3), lineWidth: 1))
        }
    }
}
