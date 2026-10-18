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

/// The live ring's look (Sessions UI 5a), shared by the SwiftUI ring and the
/// tab's layer ring.
enum LiveRingStyle {
    /// A quiet program that prints nothing: Ember, dimmed.
    static let quietOpacity: Double = 0.45
    /// The ripple: a Claw ring that grows and fades once per burst.
    static let rippleScale: CGFloat = 1.7
    static let rippleOpacity: Double = 0.95
    static let rippleDuration: TimeInterval = 0.3
}

/// One Claw ring growing out of the live ring each time `pulses` changes.
/// Nothing moves between ripples, so nothing redraws between them.
struct LiveRingRipple: View {
    let pulses: Int
    let diameter: CGFloat
    @State private var phase: CGFloat = 1

    var body: some View {
        Circle()
            .inset(by: 0.75)
            .stroke(Color(nsColor: Tako.LivingTokens.claw), lineWidth: 1.5)
            .frame(width: diameter, height: diameter)
            .scaleEffect(1 + (LiveRingStyle.rippleScale - 1) * phase)
            .opacity(LiveRingStyle.rippleOpacity * Double(1 - phase))
            .onChange(of: pulses) { _ in
                phase = 0
                withAnimation(.easeOut(duration: LiveRingStyle.rippleDuration)) { phase = 1 }
            }
    }
}

/// A live program's name as an Overview chip: Ember text on an Ember
/// hairline, no fill -- not a status, so not a status chip's colors.
struct LiveProgramChip: View {
    let program: String

    var body: some View {
        Text(program)
            .font(Font(Tako.LivingTokens.monoFont(size: 10, weight: .medium)))
            .foregroundColor(Color(nsColor: Tako.LivingTokens.ember))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .frame(height: 18)
            .overlay(Capsule().strokeBorder(Color(nsColor: Tako.LivingTokens.ember).opacity(0.3), lineWidth: 1))
    }
}
