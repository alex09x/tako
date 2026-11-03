/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import CoreText
import Foundation

extension TerminalRenderer.Metrics {
    static func weightedStyle(
        _ face: (font: CTFont, emboldened: Bool),
        weight: Int?, style: TerminalTheme.FontStyle, regular: CTFont
    ) -> (font: CTFont, emboldened: Bool) {
        guard style != .disabled else { return (regular, false) }
        guard let weight, (100...900).contains(weight) else { return face }
        // An explicit numeric weight requests a real face/instance, rather
        // than an extra synthetic bold stroke on top of that weight.
        return (weightedFace(face.font, weight: weight), false)
    }

    static func weightedFace(_ font: CTFont, weight: Int?) -> CTFont {
        guard let weight, (100...900).contains(weight) else { return font }
        if let axis = weightAxis(font) {
            var variations = CTFontCopyVariation(font) as? [NSNumber: NSNumber] ?? [:]
            var coordinate = Double(weight)
            if axis.max < 100 {
                // Legacy GX fonts (notably system Skia) use a small native
                // scale rather than OpenType's CSS units. Anchor CSS 400 at
                // the axis default and map each side to its declared bounds.
                coordinate = weight <= 400
                    ? axis.defaultValue + (Double(weight) - 400) / 300 * (axis.defaultValue - axis.min)
                    : axis.defaultValue + (Double(weight) - 400) / 500 * (axis.max - axis.defaultValue)
            }
            variations[axis.id] = NSNumber(value: min(max(coordinate, axis.min), axis.max))
            let descriptor = CTFontDescriptorCreateWithAttributes(
                [kCTFontVariationAttribute: variations] as CFDictionary)
            return CTFontCreateCopyWithAttributes(font, CTFontGetSize(font), nil, descriptor)
        }

        // Static fonts cannot represent an arbitrary CSS weight. Enumerate
        // actual family faces of the same slant and choose the nearest CSS
        // weight, preferring the lighter face on an exact tie. Keep the
        // original transform (including a synthesised italic) and size.
        let family = CTFontCopyFamilyName(font) as String
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute: family] as CFDictionary)
        let mandatory = Set([kCTFontFamilyNameAttribute as String]) as CFSet
        let matches = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, mandatory) as? [CTFontDescriptor] ?? []
        let italic = CTFontGetSymbolicTraits(font).contains(.traitItalic)
        var best = font
        var bestWeight = cssWeight(font)
        var distance = abs(bestWeight - Double(weight))
        for match in matches {
            let candidate = CTFontCreateWithFontDescriptor(match, CTFontGetSize(font), nil)
            guard CTFontCopyFamilyName(candidate) as String == family,
                  CTFontGetSymbolicTraits(candidate).contains(.traitItalic) == italic else { continue }
            let candidateWeight = cssWeight(candidate)
            let candidateDistance = abs(candidateWeight - Double(weight))
            if candidateDistance < distance || (candidateDistance == distance && candidateWeight < bestWeight) {
                best = candidate
                bestWeight = candidateWeight
                distance = candidateDistance
            }
        }
        var matrix = CTFontGetMatrix(font)
        return CTFontCreateCopyWithAttributes(best, CTFontGetSize(font), &matrix, nil)
    }

    static func weightAxis(_ font: CTFont) -> (id: NSNumber, min: Double, max: Double, defaultValue: Double)? {
        let axes = CTFontCopyVariationAxes(font) as? [[CFString: Any]] ?? []
        for axis in axes {
            guard let id = axis[kCTFontVariationAxisIdentifierKey] as? NSNumber,
                  id.uint32Value == 0x77676874, // OpenType 'wght'
                  let min = axis[kCTFontVariationAxisMinimumValueKey] as? NSNumber,
                  let max = axis[kCTFontVariationAxisMaximumValueKey] as? NSNumber,
                  let defaultValue = axis[kCTFontVariationAxisDefaultValueKey] as? NSNumber else { continue }
            return (id, min.doubleValue, max.doubleValue, defaultValue.doubleValue)
        }
        return nil
    }

    private static func cssWeight(_ font: CTFont) -> Double {
        let traits = CTFontCopyTraits(font) as NSDictionary
        let weight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
        // CoreText's standard weight landmarks, interpolated to CSS units.
        let landmarks: [(trait: Double, css: Double)] = [
            (-0.8, 100), (-0.6, 200), (-0.4, 300), (0, 400),
            (0.23, 500), (0.3, 600), (0.4, 700), (0.56, 800), (0.62, 900),
        ]
        for (lower, upper) in zip(landmarks, landmarks.dropFirst()) where weight <= upper.trait {
            return lower.css + max(0, (weight - lower.trait) / (upper.trait - lower.trait)) * (upper.css - lower.css)
        }
        return 900
    }
}
