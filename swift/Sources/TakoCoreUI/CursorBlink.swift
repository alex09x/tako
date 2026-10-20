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

/// The cursor's blink as one-shot timers, a phase each: lit for 0.72 s, out
/// for 0.48 s. A timer replaced or stopped meanwhile changes nothing; while
/// output is held (synchronized output) the cursor keeps its phase and the
/// chain goes on. The phone's view blinks with it; the Mac's view runs the
/// same chain of its own.
@MainActor
public final class CursorBlinker {
    public private(set) var isLit = true
    public private(set) var timer: Timer?
    private let shouldBlink: @MainActor () -> Bool
    private let holdsStill: @MainActor () -> Bool
    private let changed: @MainActor () -> Void

    public init(shouldBlink: @escaping @MainActor () -> Bool, holdsStill: @escaping @MainActor () -> Bool = { false },
                changed: @escaping @MainActor () -> Void) {
        self.shouldBlink = shouldBlink
        self.holdsStill = holdsStill
        self.changed = changed
    }

    /// Lit now, and blinking from here if it should.
    public func restart() {
        timer?.invalidate()
        timer = nil
        isLit = true
        guard shouldBlink() else { return }
        scheduleNextPhase()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scheduleNextPhase() {
        timer = Timer.scheduledTimer(withTimeInterval: CursorBlink.phaseDuration(lit: isLit), repeats: false) { [weak self] fired in
            MainActor.assumeIsolated {
                guard let self, self.timer === fired, self.shouldBlink() else { return }
                if !self.holdsStill() {
                    self.isLit.toggle()
                    self.changed()
                }
                self.scheduleNextPhase()
            }
        }
    }
}
