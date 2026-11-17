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
    @ObservedObject private var motion = LivingAnimationState.shared
    @Environment(\.controlActiveState) private var activeState
    private typealias T = Tako.LivingTokens

    /// `.toast` `tin .22s` in and `.out` .18 s: one easing per change, none under Reduce Motion.
    static let duration: Double = 0.22

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: duration)
    }

    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : .move(edge: .trailing).combined(with: .opacity)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if activeState == .key {
                ForEach(center.toasts) { toast in
                    PaneToastRow(toast: toast) { center.open(toast) }
                        .transition(Self.transition(reduceMotion: motion.reduceMotion))
                }
            }
        }
        .frame(width: 300)
        .padding(center.toasts.isEmpty ? 0 : 12)
        // An overlay over the terminals: it never resizes them.
        .animation(Self.animation(reduceMotion: motion.reduceMotion), value: center.toasts.map(\.id))
        .allowsHitTesting(!center.toasts.isEmpty)
    }
}

/// One toast: ring, «title — state», what it says, and where it is.
struct PaneToastRow: View {
    let toast: PaneToast
    let open: () -> Void
    private typealias T = Tako.LivingTokens

    var body: some View {
        label
            .accessibilityHidden(true)
            .overlay {
                PaneToastButton(action: open,
                                label: [toast.headline, toast.message, "\(toast.place) →"].filter { !$0.isEmpty }.joined(separator: ", "),
                                identifier: "PaneToast-\(toast.surfaceID.uuidString.lowercased())")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
    }

    private var label: some View {
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
            // The row's own height: the overlay offers the whole window, and the
            // label's maxHeight would otherwise stretch the toast down to its bottom.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: T.surfaceActive)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: T.badge)))
            .shadow(color: .black.opacity(0.5), radius: 15, x: 0, y: 12)
            .contentShape(Rectangle())
    }
}
