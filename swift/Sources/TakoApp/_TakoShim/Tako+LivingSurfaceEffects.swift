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

/// Exact CSS cubic-bezier and per-segment keyframe evaluator matching `Sessions UI.dc.html` (§7).
enum CSSTiming {
    static func cubicBezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> (Double) -> Double {
        { x in
            if x <= 0.0 { return 0.0 }
            if x >= 1.0 { return 1.0 }
            var lo = 0.0
            var hi = 1.0
            for _ in 0..<60 {
                let u = 0.5 * (lo + hi)
                let om = 1.0 - u
                let bx = 3.0 * om * om * u * x1 + 3.0 * om * u * u * x2 + u * u * u
                if bx < x { lo = u } else { hi = u }
            }
            let u = 0.5 * (lo + hi)
            let om = 1.0 - u
            return 3.0 * om * om * u * y1 + 3.0 * om * u * u * y2 + u * u * u
        }
    }

    static let linear: (Double) -> Double = { $0 }
    static let easeInOut: (Double) -> Double = cubicBezier(0.42, 0.0, 0.58, 1.0)
    static let easeOut: (Double) -> Double = cubicBezier(0.0, 0.0, 0.58, 1.0)
    static let popOvershoot: (Double) -> Double = cubicBezier(0.3, 1.6, 0.5, 1.0)

    static func positiveMod(_ value: Double, _ period: Double) -> Double {
        let r = value.truncatingRemainder(dividingBy: period)
        return r < 0 ? r + period : r
    }

    static func keyframes(_ stops: [(ms: Double, value: Double)], ease: (Double) -> Double, atMs t: Double) -> Double {
        guard let first = stops.first, let last = stops.last else { return 0.0 }
        if t <= first.ms { return first.value }
        for i in 0..<(stops.count - 1) {
            let s0 = stops[i]
            let s1 = stops[i + 1]
            if t >= s0.ms && t <= s1.ms {
                guard s1.ms > s0.ms else { return s1.value }
                let p = (t - s0.ms) / (s1.ms - s0.ms)
                return s0.value + (s1.value - s0.value) * ease(p)
            }
        }
        return last.value
    }
}

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
                borderEffect(at: t)

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
                        let hLayer = max(1, h + 8)
                        let dy = Double(tan(10.0 * .pi / 180.0) * (w / hLayer))
                        ZStack(alignment: .bottomLeading) {
                            if let frac = doneFrac {
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: Color(nsColor: T.ok).opacity(0.26), location: 0.5),
                                        .init(color: .clear, location: 1.0),
                                    ],
                                    startPoint: UnitPoint(x: 0, y: 0.5 - dy / 2.0),
                                    endPoint: UnitPoint(x: 1, y: 0.5 + dy / 2.0)
                                )
                                .frame(width: max(1, w), height: hLayer)
                                .offset(x: frac * w - w * 0.5, y: -4)
                            }
                            if showsBottomProgressLine, case .progress(let p) = state {
                                let clamped = CGFloat(min(1.0, max(0.0, p)))
                                let availW = max(0, w - progressInsetLeft * 2)
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(LinearGradient(colors: [Color(nsColor: T.rust), Color(nsColor: T.ember)], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(2, availW * clamped), height: 2)
                                    .offset(x: progressInsetLeft, y: 0)
                            }
                        }
                        .frame(width: w, height: h, alignment: .bottomLeading)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                }
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
                // breatheSel (§3.2): 2px border #F4581C <-> #FF7A3D
                let r = (0xF4 / 255.0) + ((0xFF - 0xF4) / 255.0) * s
                let g = (0x58 / 255.0) + ((0x7A - 0x58) / 255.0) * s
                let b = (0x1C / 255.0) + ((0x3D - 0x1C) / 255.0) * s
                let borderColor = Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(borderColor, lineWidth: 2.0)
            } else {
                let alpha = reduceMotion ? 0.90 : (0.40 + 0.55 * s)
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color(nsColor: T.claw).opacity(alpha), lineWidth: 1.0)
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

/// Renders the outer breathing `box-shadow` for `.waiting` surfaces (`row.glow`, `card.glow`, `card.sel.glow`).
/// Placed in `.background` as a filled rounded rectangle with `.shadow` so CoreGraphics bitmap snapshots
/// and live GPU layers both produce the exact CSS `box-shadow: 0 0 16px` / `0 0 22px` outer glow falloff.
struct LivingSurfaceOuterGlow: View {
    let state: Tako.SurfaceState
    let cornerRadius: CGFloat
    let backingColor: NSColor
    var alwaysFillBacking: Bool = false
    var isSelectedOverviewCard: Bool = false
    var now: Date = Date()
    var reduceMotion: Bool = false

    private typealias T = Tako.LivingTokens

    @ViewBuilder
    var body: some View {
        if state == .waiting {
            let t = now.timeIntervalSinceReferenceDate
            let s = reduceMotion ? 1.0 : LivingAnimationState.breatheFactor(at: t)
            let alpha = isSelectedOverviewCard
                ? (reduceMotion ? 0.25 : 0.42 * s)
                : (reduceMotion ? 0.22 : 0.35 * s)
            if alpha > 0.005 {
                let radius: CGFloat = isSelectedOverviewCard ? 11.5 : 8.5
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(nsColor: backingColor))
                    .shadow(color: Color(nsColor: T.claw).opacity(alpha), radius: radius, x: 0, y: 0)
            } else if alwaysFillBacking {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(nsColor: backingColor))
            }
        } else if alwaysFillBacking {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color(nsColor: backingColor))
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
        .padding(.horizontal, 8)
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
/// Vertical from `(-11.5, -4)` to `10.5`, rounded corner `r = 4`, horizontal to `-3`.
struct SidebarPaneTreeConnectorShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let startX: CGFloat = -11.5
        let startY: CGFloat = -4
        let midY: CGFloat = 10.5
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
