/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import simd

/// How instance colors are encoded for the render target.
///
/// Metal converts nothing on its own: a `.bgra8Unorm` drawable stores exactly
/// the components the fragment shader returns, while a `.bgra8Unorm_srgb` one
/// encodes them from linear on write. `MetalImageCache` hands out plain
/// `.bgra8Unorm` textures holding display-encoded bytes, so `displayEncoded`
/// (the default) is what keeps cell colors, glyph colors and Kitty images in
/// the same space.
@frozen public enum TerminalMetalColorEncoding: Sendable, Equatable {
    /// Components stay as the terminal delivered them, for a non-sRGB target.
    case displayEncoded
    /// Components are linearized, for a `_srgb` render target that re-encodes.
    case linear
}

/// Gamut used by the render target. Terminal RGB triples are defined in sRGB;
/// Display-P3 output converts them through linear light before encoding.
@frozen public enum TerminalMetalColorSpace: Sendable, Equatable {
    case sRGB
    case displayP3
}

/// Color conversion shared by every pass.
public enum TerminalMetalColor {
    @inline(__always)
    private static func decodeSRGB(_ value: Float) -> Float {
        if value <= 0 { return 0 }
        if value >= 1 { return 1 }
        return value <= 0.04045 ? value / 12.92 : powf((value + 0.055) / 1.055, 2.4)
    }

    @inline(__always)
    private static func encodeSRGB(_ value: Float) -> Float {
        let v = max(0, min(1, value))
        if v <= 0 { return 0 }
        if v >= 1 { return 1 }
        return v <= 0.0031308 ? v * 12.92 : 1.055 * powf(v, 1 / 2.4) - 0.055
    }

    /// One 0...255 channel as the shader wants to see it.
    @inline(__always)
    public static func component(_ byte: UInt8, encoding: TerminalMetalColorEncoding) -> Float {
        let value = Float(byte) / 255
        switch encoding {
        case .displayEncoded:
            return value
        case .linear:
            return decodeSRGB(value)
        }
    }

    /// A straight (non-premultiplied) RGBA color from terminal bytes.
    @inline(__always)
    public static func rgba(
        r: UInt8,
        g: UInt8,
        b: UInt8,
        alpha: Float = 1,
        encoding: TerminalMetalColorEncoding = .displayEncoded,
        colorSpace: TerminalMetalColorSpace = .sRGB
    ) -> SIMD4<Float> {
        var linear = SIMD3<Float>(decodeSRGB(Float(r) / 255), decodeSRGB(Float(g) / 255), decodeSRGB(Float(b) / 255))
        if colorSpace == .displayP3 {
            linear = SIMD3<Float>(
                0.8225929 * linear.x + 0.1775340 * linear.y,
                0.0331995 * linear.x + 0.9667835 * linear.y,
                0.0170854 * linear.x + 0.0723957 * linear.y + 0.9103015 * linear.z
            )
        }
        if encoding == .displayEncoded {
            linear = SIMD3<Float>(encodeSRGB(linear.x), encodeSRGB(linear.y), encodeSRGB(linear.z))
        }
        return SIMD4<Float>(linear.x, linear.y, linear.z, max(0, min(1, alpha)))
    }

    /// Every pass blends with `.one, .oneMinusSourceAlpha`, so colors reach
    /// the GPU already multiplied by their own alpha.
    @inline(__always)
    public static func premultiplied(_ color: SIMD4<Float>) -> SIMD4<Float> {
        let alpha = max(0, min(1, color.w))
        guard alpha > 0 else { return .zero }
        return SIMD4<Float>(color.x * alpha, color.y * alpha, color.z * alpha, alpha)
    }

    /// Raises foreground contrast without changing alpha. The interpolation
    /// is performed in linear light and chooses the nearer of black or white.
    public static func enforcingMinimumContrast(
        foreground: SIMD4<Float>,
        background: SIMD4<Float>,
        ratio minimumRatio: Float,
        encoding: TerminalMetalColorEncoding,
        colorSpace: TerminalMetalColorSpace = .sRGB
    ) -> SIMD4<Float> {
        guard foreground.w > 0 else { return .zero }
        let target = max(1, minimumRatio)
        func linear(_ color: SIMD4<Float>) -> SIMD3<Float> {
            let rgb = SIMD3<Float>(color.x, color.y, color.z)
            return encoding == .linear ? rgb : SIMD3<Float>(decodeSRGB(rgb.x), decodeSRGB(rgb.y), decodeSRGB(rgb.z))
        }
        func luminance(_ rgb: SIMD3<Float>) -> Float {
            colorSpace == .displayP3
                ? 0.2289746 * rgb.x + 0.6917385 * rgb.y + 0.0792869 * rgb.z
                : 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
        }
        let fg = linear(foreground)
        let bg = linear(background)
        let fgL = luminance(fg)
        let bgL = luminance(bg)
        let current = (max(fgL, bgL) + 0.05) / (min(fgL, bgL) + 0.05)
        guard current < target else { return foreground }
        let towardWhite = (1.05 / (bgL + 0.05)) >= ((bgL + 0.05) / 0.05)
        let wantedL = towardWhite
            ? min(1, target * (bgL + 0.05) - 0.05)
            : max(0, (bgL + 0.05) / target - 0.05)
        let endpoint = towardWhite ? SIMD3<Float>(repeating: 1) : .zero
        let endpointL: Float = towardWhite ? 1 : 0
        let denominator = endpointL - fgL
        let amount = denominator == 0 ? 1 : max(0, min(1, (wantedL - fgL) / denominator))
        var adjusted = fg + (endpoint - fg) * amount
        if encoding == .displayEncoded {
            adjusted = SIMD3<Float>(encodeSRGB(adjusted.x), encodeSRGB(adjusted.y), encodeSRGB(adjusted.z))
        }
        return SIMD4<Float>(adjusted.x, adjusted.y, adjusted.z, foreground.w)
    }
}
