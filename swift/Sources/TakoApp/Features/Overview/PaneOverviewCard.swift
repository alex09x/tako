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
    var showsAnimatedEffects: Bool = true

    private typealias T = Tako.LivingTokens

    static func == (lhs: PaneOverviewCard, rhs: PaneOverviewCard) -> Bool {
        lhs.item == rhs.item && lhs.isSelected == rhs.isSelected && lhs.reduceMotion == rhs.reduceMotion && lhs.now == rhs.now && lhs.showsAnimatedEffects == rhs.showsAnimatedEffects
    }

    var body: some View {
        let state = item.surfaceState
        let hasSweepBorder: Bool = {
            if state == .working { return true }
            if case .progress = state { return true }
            return false
        }()
        let elapsedInState = LivingAnimationState.shared.elapsedInState(
            for: "overview-\(item.id.uuidString)",
            state: state,
            now: now
        )
        let radius: CGFloat = 10

        VStack(alignment: .leading, spacing: 9) {
            // Row 1 (gap 8): Ring L=18 -> title mono 13 semibold #FAF7F2 -> timer mono 10 #8A7F76 (dim, NOT ember)
            HStack(spacing: 8) {
                StatusRingView(
                    state: state,
                    size: .large,
                    now: now,
                    elapsedInState: elapsedInState,
                    reduceMotion: reduceMotion || !showsAnimatedEffects,
                    shakeRingOnly: true,
                    pulses: item.live?.pulses ?? 0
                )

                Text(item.title)
                    .font(Font(T.monoFont(size: 13, weight: .bold)))
                    .foregroundColor(Color(nsColor: state == .offline ? T.faint : T.textActive))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let meta = item.metaDisplayText {
                    SessionSidebarMetaLabel(text: meta, style: .dim)
                }
            }
            .frame(height: 18)

            // Row 2 (gap 7): Status Chip -> statusText mono 10.5 #8A7F76
            HStack(spacing: 7) {
                if state.isLive, let live = item.live {
                    // A live program: its name, Ember-outlined, and where it runs.
                    LiveProgramChip(program: live.program ?? "live")
                    if let place = live.detail ?? item.pwd.map(Tako.formatCompactDirectory) {
                        Text(place)
                            .font(Font(T.monoFont(size: 10.5, weight: .regular)))
                            .foregroundColor(Color(nsColor: T.dim))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    LivingStatusChipView(status: item.status)
                }

                if !state.isLive, let text = item.statusText, !text.isEmpty {
                    Text(text)
                        .font(Font(T.monoFont(size: 10.5, weight: .regular)))
                        .foregroundColor(Color(nsColor: T.dim))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)
            }
            .frame(height: 18)
            .offset(y: 0.5)

            // Live Thumbnail Preview (h 112, #14100E, r 7, border 1 #2A211B, bottom 24pt fade, 3px progress bar)
            thumbnailView(item: item)

            // Card Footer (gap 6): "~/…" mono 10.5 #8A7F76 on left, "Workspace › N" mono 10.5 #6B6259 on right
            HStack(spacing: 6) {
                Text(item.directoryDisplay)
                    .font(Font(T.monoFont(size: 10.5, weight: .regular)))
                    .foregroundColor(Color(nsColor: T.dim))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(item.provenanceLabel)
                    .font(Font(T.monoFont(size: 10.5, weight: .regular)))
                    .foregroundColor(Color(nsColor: T.faint))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: 16)
            .offset(y: -1)
        }
        .padding(.horizontal, hasSweepBorder ? 13 : 12)
        .padding(.top, hasSweepBorder ? 13 : 12)
        .padding(.bottom, hasSweepBorder ? 11 : 12)
        .background(
            DoneGlintBackground(
                state: showsAnimatedEffects ? state : .idle,
                cornerRadius: radius,
                elapsedInState: elapsedInState,
                reduceMotion: reduceMotion
            )
        )
        .background(
            LivingSurfaceOuterGlow(
                state: showsAnimatedEffects ? state : .idle,
                cornerRadius: radius,
                backingColor: T.surfaceActive,
                alwaysFillBacking: true,
                isSelectedOverviewCard: isSelected,
                now: now,
                reduceMotion: reduceMotion
            )
        )
        .overlay(
            baseBorderOverlay(state: showsAnimatedEffects ? state : .idle, radius: radius)
        )
        .overlay {
            if showsAnimatedEffects {
                LivingSurfaceEffectsOverlay(
                    state: state,
                    cornerRadius: radius,
                    cometLineWidth: 1.5,
                    showsCometForProgress: true,
                    showsBottomProgressLine: false,
                    drawsDoneGlint: false,
                    isSelectedOverviewCard: isSelected,
                    now: now,
                    elapsedInState: elapsedInState,
                    reduceMotion: reduceMotion
                )
            }
        }
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
                    styledThumbnailText(item.thumbnailLines.prefix(7))
                        .font(Font(T.monoFont(size: 10, weight: .regular)))
                        .lineSpacing(1.85)
                        .lineLimit(7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 8)
            .frame(height: 112, alignment: .topLeading)

            // Bottom 24pt fade gradient from clear to #14100E over text (§6)
            LinearGradient(
                colors: [Color(nsColor: T.body).opacity(0), Color(nsColor: T.body)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .allowsHitTesting(false)

            // 3px Progress bar inside preview (§3.5): left 10, right 10, bottom 8, r 1.5, track #2A211B, fill Rust->Ember
            // Only a progress that has a number: one without is drawn as
            // working, not as a bar of made-up length.
            if item.progressState != .none, item.progressState != .indeterminate {
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

    private func styledThumbnailText(_ lines: ArraySlice<String>) -> Text {
        let needsRich = lines.contains {
            $0.hasPrefix("? ") || $0.hasPrefix("$ ") || $0.hasPrefix("● ") ||
            $0.hasPrefix("❯ 1.") || $0.hasPrefix("error:") ||
            $0.hasSuffix(" ok") || $0.hasSuffix(" FAILED")
        }
        if !needsRich {
            return Text(lines.joined(separator: "\n")).foregroundColor(Color(nsColor: T.text))
        }
        var result = Text("")
        for (idx, line) in lines.enumerated() {
            if idx > 0 { result = result + Text("\n") }
            result = result + styledTerminalLine(line)
        }
        return result
    }

    private func styledTerminalLine(_ line: String) -> Text {
        let baseColor = Color(nsColor: T.text)
        let dimColor = Color(nsColor: T.dim)
        let clawColor = Color(nsColor: T.claw)
        let okColor = Color(nsColor: T.ok)
        let errColor = Color(nsColor: T.error)

        if line.hasPrefix("? ") {
            return Text(line).foregroundColor(clawColor)
        }
        if line.hasPrefix("$ ") {
            return Text("$").foregroundColor(dimColor) + Text(String(line.dropFirst())).foregroundColor(baseColor)
        }
        if line.hasPrefix("● ") {
            return Text("●").foregroundColor(dimColor) + Text(String(line.dropFirst())).foregroundColor(baseColor)
        }
        if line.hasPrefix("❯ 1. High Contrast Ember") {
            let prefix = "❯ 1. High Contrast Ember"
            let suffix = String(line.dropFirst(prefix.count))
            return Text(prefix).foregroundColor(clawColor) + Text(suffix).foregroundColor(baseColor)
        }
        if line.hasPrefix("error:") {
            let suffix = String(line.dropFirst(6))
            return Text("error:").foregroundColor(errColor) + Text(suffix).foregroundColor(baseColor)
        }
        if line.hasSuffix(" ok") {
            let prefix = String(line.dropLast(2))
            return Text(prefix).foregroundColor(baseColor) + Text("ok").foregroundColor(okColor)
        }
        if line.hasSuffix(" FAILED") {
            let prefix = String(line.dropLast(6))
            return Text(prefix).foregroundColor(baseColor) + Text("FAILED").foregroundColor(errColor)
        }
        return Text(line).foregroundColor(baseColor)
    }

    private func progressBarView(state: TakoTerminalNSView.ProgressState, value: Int?) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = min(max(Double(value ?? 0) / 100.0, 0.05), 1.0)

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
