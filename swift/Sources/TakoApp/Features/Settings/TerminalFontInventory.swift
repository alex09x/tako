/*
 * tako — Installed font discovery and variable weight metadata
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import CoreText

extension TerminalAppearanceCatalog {
    @MainActor static func fontInventory() -> [String: JSON] {
        let families = fontFamilies()
        let details = families.map { family -> JSON in
            let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
            let styles = Set(members.compactMap { $0.count > 1 ? $0[1] as? String : nil }).sorted()
            let font = CTFontCreateWithName(family as CFString, 13, nil)
            let axes = (CTFontCopyVariationAxes(font) as? [[String: Any]]) ?? []
            let weightAxis = axes.first { ($0[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.uint32Value == 0x77676874 }
            var info: [String: JSON] = ["family": .string(family), "styles": .array(styles.map(JSON.string)),
                "variable_weight": .bool(weightAxis != nil)]
            if let weightAxis {
                for (name, key) in [("minimum_weight", kCTFontVariationAxisMinimumValueKey),
                                    ("maximum_weight", kCTFontVariationAxisMaximumValueKey),
                                    ("default_weight", kCTFontVariationAxisDefaultValueKey)] {
                    if let value = weightAxis[key as String] as? NSNumber { info[name] = .number(value.doubleValue) }
                }
            }
            return .object(info)
        }
        return ["fonts": .array(families.map(JSON.string)), "font_details": .array(details),
                "weight_min": .number(100), "weight_max": .number(900)]
    }
}
