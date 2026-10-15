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

/// Renders the Spec 1b Surface Effects (§3) on top of a rounded rectangle surface in SwiftUI (Sidebar & Overview).
struct LivingSurfaceEffectsOverlay: View {
    let state: Tako.SurfaceState
    let cornerRadius: CGFloat
    var cometLineWidth: CGFloat = 1.0
    var showsCometForProgress: Bool = false
    var showsBottomProgressLine: Bool = false
    var progressInsetLeft: CGFloat = 0
    var isSelectedOverviewCard: Bool = false
    var now: Date = Date()
    var elapsedInState: TimeInterval = 10.0
    var reduceMotion: Bool = false

    private typealias T = Tako.LivingTokens

    @ViewBuilder
    var body: some View {
        if state == .idle {
            EmptyView()
        } else {
            let t = now.timeIntervalSinceReferenceDate
            let doneFrac = (state == .done && !reduceMotion) ? LivingAnimationState.doneFlashFraction(elapsed: elapsedInState) : nil
            let needsGeo = (doneFrac != nil) || (showsBottomProgressLine && { if case .progress = state { return true }; return false }())

            ZStack(alignment: .bottom) {
                if state == .failed {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(Color(nsColor: T.error))
                            .frame(height: 2)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                } else if needsGeo {
                    GeometryReader { geo in
                        let w = geo.size.width
                        let h = geo.size.height
                        ZStack(alignment: .bottomLeading) {
                            if let frac = doneFrac {
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: Color(nsColor: T.ok).opacity(0.26), location: 0.5),
                                        .init(color: .clear, location: 1.0),
                                    ],
                                    startPoint: UnitPoint(x: 0, y: 0.41),
                                    endPoint: UnitPoint(x: 1, y: 0.59)
                                )
                                .frame(width: max(1, w), height: h + 8)
                                .offset(x: frac * w - w * 0.5, y: -4)
                            }
                            if showsBottomProgressLine, case .progress(let p) = state {
                                let clamped = CGFloat(min(1.0, max(0.0, p)))
                                let availW = max(0, w - progressInsetLeft)
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(LinearGradient(colors: [Color(nsColor: T.rust), Color(nsColor: T.ember)], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(2, availW * clamped), height: 2)
                                    .offset(x: progressInsetLeft)
                            }
                        }
                        .frame(width: w, height: h, alignment: .bottomLeading)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                }

                borderEffect(at: t)
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func borderEffect(at t: TimeInterval) -> some View {
        switch state {
        case .working:
            cometBorder(at: t)
        case .progress:
            if showsCometForProgress {
                cometBorder(at: t)
            }
        case .waiting:
            let s = reduceMotion ? 1.0 : LivingAnimationState.breatheFactor(at: t)
            if isSelectedOverviewCard {
                // breatheSel (§3.2): 2px border #F4581C <-> #FF7A3D, blur 22 (radius 11), opacity 0 <-> 0.32
                let r = (0xF4 / 255.0) + ((0xFF - 0xF4) / 255.0) * s
                let g = (0x58 / 255.0) + ((0x7A - 0x58) / 255.0) * s
                let b = (0x1C / 255.0) + ((0x3D - 0x1C) / 255.0) * s
                let borderColor = Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(borderColor, lineWidth: 2.0)
                    .shadow(
                        color: Color(nsColor: T.claw).opacity(reduceMotion ? 0.20 : 0.32 * s),
                        radius: 11
                    )
            } else {
                let alpha = reduceMotion ? 0.90 : (0.40 + 0.55 * s)
                let shadowAlpha = reduceMotion ? 0.20 : (0.30 * s)
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color(nsColor: T.claw).opacity(alpha), lineWidth: 1.0)
                    .shadow(color: Color(nsColor: T.claw).opacity(shadowAlpha), radius: 8)
            }
        case .offline:
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    Color(nsColor: T.ghostBorder),
                    style: StrokeStyle(lineWidth: 1.0, dash: [3, 3])
                )
        case .idle, .done, .failed:
            EmptyView()
        }
    }

    @ViewBuilder
    private func cometBorder(at t: TimeInterval) -> some View {
        if reduceMotion {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color(nsColor: T.ember).opacity(0.8), lineWidth: cometLineWidth)
        } else {
            let phase = LivingAnimationState.cometDegrees(at: t)
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .clear, location: 0.62),
                            .init(color: Color(nsColor: T.rust), location: 0.78),
                            .init(color: Color(nsColor: T.claw), location: 0.88),
                            .init(color: .clear, location: 1.0),
                        ]),
                        center: .center,
                        angle: .degrees(phase - 90)
                    ),
                    lineWidth: cometLineWidth
                )
        }
    }
}

/// Unified Status Chip per Spec 1b (§6): h 18, padding 0 7, capsule, mono 10 medium, gap 5.
struct LivingStatusChipView: View {
    let status: Tako.PaneStatus
    var customLabel: String? = nil

    private typealias T = Tako.LivingTokens

    var body: some View {
        let label = customLabel ?? status.overviewChipLabel
        let spec = styleSpec(for: status)
        HStack(spacing: 5) {
            Text(label)
                .font(Font(T.monoFont(size: 10, weight: .medium)))
                .foregroundColor(spec.text)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Capsule().fill(spec.fill))
        .overlay(Capsule().strokeBorder(spec.border, lineWidth: 1))
    }

    private func styleSpec(for status: Tako.PaneStatus) -> (text: Color, fill: Color, border: Color) {
        switch status {
        case .needsApproval, .waitingForInput:
            let c = Color(nsColor: T.claw)
            return (c, c.opacity(0.10), c.opacity(0.28))
        case .working, .running:
            let c = Color(nsColor: T.ember)
            return (c, c.opacity(0.08), c.opacity(0.22))
        case .done:
            let c = Color(nsColor: T.ok)
            return (c, c.opacity(0.10), c.opacity(0.25))
        case .error:
            let c = Color(nsColor: T.error)
            return (c, c.opacity(0.10), c.opacity(0.25))
        case .idle, .disconnected, .unknown:
            return (
                Color(nsColor: T.dim),
                Color.clear,
                Color(nsColor: T.badge)
            )
        }
    }
}

/// L-shaped tree connector line for Level 2 split-pane and subagent rows in Session Sidebar (§5.6).
/// Vertical from `(minX - 12, minY - 4)` to `midY`, rounded corner `r = 4`, horizontal `9pt` right.
struct SidebarPaneTreeConnectorShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let startX: CGFloat = -12
        let startY: CGFloat = -4
        let midY = rect.midY
        let endX: CGFloat = -3
        let r: CGFloat = 4
        path.move(to: CGPoint(x: startX, y: startY))
        path.addLine(to: CGPoint(x: startX, y: max(startY, midY - r)))
        path.addQuadCurve(
            to: CGPoint(x: startX + r, y: midY),
            control: CGPoint(x: startX, y: midY)
        )
        path.addLine(to: CGPoint(x: endX, y: midY))
        return path
    }
}
