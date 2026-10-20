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

/// The cursor's blink, on the Mac and the phone alike (Terminal UI: "мигание
/// 1.2s"; Mobile UI: "мигание 1.2s (60% on / 40% off)").
public enum CursorBlink {
    public static let period: TimeInterval = 1.2
    public static let litShare = 0.6

    /// How long the cursor stays lit, or out, before it changes.
    public static func phaseDuration(lit: Bool) -> TimeInterval {
        lit ? period * litShare : period * (1 - litShare)
    }
}
