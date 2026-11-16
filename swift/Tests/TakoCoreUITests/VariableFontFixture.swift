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
import XCTest
@testable import TakoCoreUI

/// An installed variable font with a real `wght` axis spanning 400...600
/// and an "M" glyph, shared by the tests that need variation coordinates.
/// STIX Two Text ships with both macOS and the iOS simulator; any other
/// installed font with such an axis also qualifies. Without one the test is
/// skipped with that reason, never passed.
enum VariableFontFixture {
    static func weightVariableFont(size: CGFloat) throws -> CTFont {
        let names = ["STIXTwoText", "KefaIII-Regular"]
            + (CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? [])
        for name in names {
            let font = CTFontCreateWithName(name as CFString, size, nil)
            guard let axis = TerminalRenderer.Metrics.weightAxis(font), axis.min <= 400, axis.max >= 600 else { continue }
            guard CTFontGetGlyphWithName(font, "M" as CFString) != 0 else { continue }
            print("Variable font fixture: \(CTFontCopyPostScriptName(font)), wght \(axis.min)...\(axis.max)")
            return font
        }
        throw XCTSkip("No actual system variable font with a wght range spanning 400...600; variable rendering/cache coverage unavailable")
    }
}
