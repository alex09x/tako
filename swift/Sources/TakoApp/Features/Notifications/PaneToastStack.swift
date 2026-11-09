/*
 * tako — The toast stack over a window's canvas (reference style.css .toasts)
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

/// Toasts in the key window's top right corner: 12 pt in, 300 pt wide, 8
/// apart, the small status ring, «title — state», what it says and where it
/// is, «minimized →» in Claw. Only the key window shows them, so two windows
/// never repeat one. Accessibility: `PaneToast-<pane uuid>`.
struct PaneToastStack: View {
    @ObservedObject var center: PaneToastCenter = .shared
    @Environment(\.controlActiveState) private var activeState
    private typealias T = Tako.LivingTokens

    var body: some View {
        if activeState == .key, !center.toasts.isEmpty {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(center.toasts) { toast in row(toast) }
            }
            .frame(width: 300)
            .padding(12)
        }
    }

    private func row(_ toast: PaneToast) -> some View {
        Button { center.open(toast) } label: {
            HStack(alignment: .top, spacing: 10) {
                SidebarStatusLayerView(state: toast.state, ringCenter: nil, cornerRadius: 0,
                                       reduceMotion: true, paused: true, pulses: 0, ringOnly: 11)
                    .frame(width: 11, height: 11)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(toast.headline)
                        .font(Font(T.monoFont(size: 12, weight: .semibold)))
                        .foregroundColor(Color(nsColor: T.textActive))
                        .lineLimit(1)
                    if !toast.message.isEmpty {
                        Text(toast.message)
                            .font(Font(T.monoFont(size: 11, weight: .regular)))
                            .foregroundColor(Color(nsColor: T.dim))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(toast.place) →")
                    .font(Font(T.monoFont(size: 10.5, weight: .medium)))
                    .foregroundColor(Color(nsColor: T.claw))
                    .lineLimit(1)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: T.surfaceActive)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: T.badge)))
            .shadow(color: .black.opacity(0.5), radius: 15, x: 0, y: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("PaneToast-\(toast.surfaceID.uuidString.lowercased())")
        .accessibilityAddTraits(.isButton)
    }
}
