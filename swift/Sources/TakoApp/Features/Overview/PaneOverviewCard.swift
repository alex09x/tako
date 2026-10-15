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

/// A single card in the Pane Overview 4b grid (Spec 1b §6).
struct PaneOverviewCard: View, Equatable {
    let item: PaneOverviewItem
    let isSelected: Bool
    var now: Date = Date()
    var reduceMotion: Bool = false

    private typealias T = Tako.LivingTokens

    static func == (lhs: PaneOverviewCard, rhs: PaneOverviewCard) -> Bool {
        lhs.item == rhs.item && lhs.isSelected == rhs.isSelected && lhs.reduceMotion == rhs.reduceMotion && lhs.now == rhs.now
    }

    var body: some View {
        let state = item.surfaceState
        let elapsedInState = LivingAnimationState.shared.elapsedInState(
            for: "overview-\(item.id.uuidString)",
            state: state,
            now: now
        )
        let radius: CGFloat = 10

        VStack(alignment: .leading, spacing: 6) {
            // Row 1 (gap 8): Ring L=18 -> title mono 13 semibold #FAF7F2 -> timer mono 10 #8A7F76 (dim, NOT ember)
            HStack(spacing: 8) {
                StatusRingView(
                    state: state,
                    size: .large,
                    now: now,
                    elapsedInState: elapsedInState,
                    reduceMotion: reduceMotion,
                    shakeRingOnly: true
                )

                Text(item.title)
                    .font(Font(T.monoFont(size: 13, weight: .semibold)))
                    .foregroundColor(Color(nsColor: state == .offline ? T.faint : T.textActive))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 4)

                if let meta = item.metaDisplayText {
                    Text(meta)
                        .font(Font(T.monoFont(size: 10, weight: .regular)))
                        .foregroundColor(Color(nsColor: T.dim))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            // Row 2 (gap 7): Status Chip -> statusText mono 10.5 #8A7F76
            HStack(spacing: 7) {
                LivingStatusChipView(status: item.status)

                if let text = item.statusText, !text.isEmpty {
                    Text(text)
                        .font(Font(T.monoFont(size: 10.5, weight: .regular)))
                        .foregroundColor(Color(nsColor: T.dim))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)
            }

            // Live Thumbnail Preview (h 112, #14100E, r 7, border 1 #2A211B, bottom 24pt fade, 3px progress bar)
            thumbnailView(item: item)

            // Card Footer (gap 6): "~/…" mono 10.5 #8A7F76 on left, "Workspace › N" mono 10.5 #6B6259 on right
            HStack(spacing: 6) {
                Text(item.directoryDisplay)
                    .font(Font(T.monoFont(size: 10.5, weight: .regular)))
                    .foregroundColor(Color(nsColor: T.dim))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                Spacer(minLength: 4)

                Text(item.provenanceLabel)
                    .font(Font(T.monoFont(size: 10.5, weight: .regular)))
                    .foregroundColor(Color(nsColor: T.faint))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: radius)
                .fill(Color(nsColor: T.surfaceActive))
        )
        .overlay(
            baseBorderOverlay(state: state, radius: radius)
        )
        .overlay(
            LivingSurfaceEffectsOverlay(
                state: state,
                cornerRadius: radius,
                cometLineWidth: 1.5,
                showsCometForProgress: true,
                showsBottomProgressLine: false,
                isSelectedOverviewCard: isSelected,
                now: now,
                elapsedInState: elapsedInState,
                reduceMotion: reduceMotion
            )
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func baseBorderOverlay(state: Tako.SurfaceState, radius: CGFloat) -> some View {
        if isSelected && state != .waiting {
            // §6: Selected card has 2px solid Ember #F4581C border (unless waiting, which uses breatheSel in LivingSurfaceEffectsOverlay)
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(Color(nsColor: T.ember), lineWidth: 2.0)
        } else if state != .waiting && state != .offline {
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(Color(nsColor: T.hairline), lineWidth: 1.0)
        }
    }

    private func thumbnailView(item: PaneOverviewItem) -> some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                if item.thumbnailLines.isEmpty {
                    Text("~ $")
                        .font(Font(T.monoFont(size: 10, weight: .regular)))
                        .foregroundColor(Color(nsColor: T.dim))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    Text(item.thumbnailLines.prefix(7).joined(separator: "\n"))
                        .font(Font(T.monoFont(size: 10, weight: .regular)))
                        .foregroundColor(Color(nsColor: T.text))
                        .lineSpacing(3)
                        .lineLimit(7)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            // Bottom 24pt fade gradient from clear to #14100E over text (§6)
            LinearGradient(
                colors: [Color(nsColor: T.body).opacity(0), Color(nsColor: T.body)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .allowsHitTesting(false)

            // 3px Progress bar inside preview (§3.5): left 10, right 10, bottom 8, r 1.5, track #2A211B, fill Rust->Ember
            if item.progressState != .none {
                progressBarView(state: item.progressState, value: item.progressValue)
                    .frame(height: 3)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        .frame(height: 112)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: T.body))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color(nsColor: T.hairline), lineWidth: 1)
        )
    }

    private func progressBarView(state: TakoTerminalNSView.ProgressState, value: Int?) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = min(max(Double(value ?? (state == .indeterminate ? 40 : 0)) / 100.0, 0.05), 1.0)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(nsColor: T.hairline))

                if state == .error {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color(nsColor: T.error))
                        .frame(width: width * CGFloat(fraction))
                } else {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(
                            LinearGradient(
                                colors: [Color(nsColor: T.rust), Color(nsColor: T.ember)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: width * CGFloat(fraction))
                }
            }
        }
    }
}
