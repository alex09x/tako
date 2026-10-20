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
import Testing
@testable import Tako

/// Every state on every surface Core Animation draws, with motion and with
/// Reduce Motion: what it shows and what runs is what the spec says --
/// nothing missing, nothing left over.
@Suite(.serialized) @MainActor
struct MotionStateMatrixTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let surface: MotionSpec.Surface
        let state: Tako.SurfaceState
        let reduceMotion: Bool
        var testDescription: String { "\(surface) \(state.specName)\(reduceMotion ? " reduce-motion" : "")" }
    }

    static let cases: [Case] = MotionSpec.Surface.allCases.flatMap { surface in
        MotionSpec.states.flatMap { state in [false, true].map { Case(surface: surface, state: state, reduceMotion: $0) } }
    }

    @Test(arguments: cases)
    func aSurfaceShowsItsStateAsTheSpecDoes(_ c: Case) {
        let surface = MotionSurfaceHarness(c.surface, reduceMotion: c.reduceMotion)
        defer { surface.close() }
        surface.show(c.state)
        let got = surface.effects()
        let want = MotionSpec.effects(on: c.surface, c.state, reduceMotion: c.reduceMotion, entered: false)
        #expect(got == want, "missing \(want.subtracting(got).sorted { $0.description < $1.description }), extra \(got.subtracting(want).sorted { $0.description < $1.description })")
    }
}
