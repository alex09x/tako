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
import XCTest
@testable import TakoCoreUI

extension TerminalTouchScrollTests {
    // MARK: - Kinetic Deceleration Tests

    func testKineticDecelerationVelocityThreshold() {
        // Below minimum threshold (80.0 pt/s default)
        let subZero = TerminalKineticDeceleration(initialVelocity: 0)
        XCTAssertFalse(subZero.isDecelerating)
        XCTAssertEqual(subZero.velocity, 0)

        let subPositive = TerminalKineticDeceleration(initialVelocity: 79.9)
        XCTAssertFalse(subPositive.isDecelerating)
        XCTAssertEqual(subPositive.velocity, 0)

        let subNegative = TerminalKineticDeceleration(initialVelocity: -79.9)
        XCTAssertFalse(subNegative.isDecelerating)
        XCTAssertEqual(subNegative.velocity, 0)

        // At or above threshold
        let atThreshold = TerminalKineticDeceleration(initialVelocity: 80.0)
        XCTAssertTrue(atThreshold.isDecelerating)
        XCTAssertEqual(atThreshold.velocity, 80.0)

        let negThreshold = TerminalKineticDeceleration(initialVelocity: -80.0)
        XCTAssertTrue(negThreshold.isDecelerating)
        XCTAssertEqual(negThreshold.velocity, -80.0)

        let active = TerminalKineticDeceleration(initialVelocity: 1200.0)
        XCTAssertTrue(active.isDecelerating)
        XCTAssertEqual(active.velocity, 1200.0)
    }

    func testKineticDecelerationMonotonicDecay() {
        var dec = TerminalKineticDeceleration(initialVelocity: 2500.0)
        XCTAssertTrue(dec.isDecelerating)

        let dt: TimeInterval = 1.0 / 60.0
        let cellH: Double = 20.0

        var prevVelocity = dec.velocity
        var stepCount = 0
        var totalLines = 0

        while dec.isDecelerating {
            let result = dec.step(deltaTime: dt, cellHeight: cellH)
            if let (lines, direction) = result {
                XCTAssertEqual(direction, .up)
                XCTAssertGreaterThanOrEqual(lines, 1)
                totalLines += lines
            }

            if dec.isDecelerating {
                XCTAssertLessThan(dec.velocity, prevVelocity, "Velocity must decay monotonically each step")
                XCTAssertGreaterThan(dec.velocity, 0)
                prevVelocity = dec.velocity
            }
            stepCount += 1
            XCTAssertLessThan(stepCount, 500, "Deceleration must terminate within bounded steps")
        }

        XCTAssertFalse(dec.isDecelerating)
        XCTAssertEqual(dec.velocity, 0)
        XCTAssertGreaterThan(totalLines, 0, "Deceleration must have produced lines")
    }

    func testKineticDecelerationTerminalStopAndZeroResidual() {
        var dec = TerminalKineticDeceleration(initialVelocity: 600.0)
        let dt: TimeInterval = 1.0 / 60.0
        let cellH: Double = 18.0

        while dec.isDecelerating {
            _ = dec.step(deltaTime: dt, cellHeight: cellH)
        }

        XCTAssertFalse(dec.isDecelerating)
        XCTAssertEqual(dec.velocity, 0)
        XCTAssertEqual(dec.accumulatedPoints, 0, "Terminal stop must clear sub-line residual")

        // Further steps return nil
        XCTAssertNil(dec.step(deltaTime: dt, cellHeight: cellH))
    }

    func testKineticDecelerationReciprocalDirections() {
        let initialSpeed: Double = 1800.0
        let cellH: Double = 20.0
        let dt: TimeInterval = 1.0 / 60.0

        var forwardDec = TerminalKineticDeceleration(initialVelocity: initialSpeed)
        var reverseDec = TerminalKineticDeceleration(initialVelocity: -initialSpeed)

        var forwardSteps: [(lines: Int, direction: TerminalPanDirection)] = []
        var reverseSteps: [(lines: Int, direction: TerminalPanDirection)] = []

        var totalForwardLines = 0
        var totalReverseLines = 0

        while forwardDec.isDecelerating || reverseDec.isDecelerating {
            if let f = forwardDec.step(deltaTime: dt, cellHeight: cellH) {
                forwardSteps.append(f)
                totalForwardLines += f.lines
            }
            if let r = reverseDec.step(deltaTime: dt, cellHeight: cellH) {
                reverseSteps.append(r)
                totalReverseLines += r.lines
            }
        }

        XCTAssertEqual(totalForwardLines, totalReverseLines, "Total forward and reverse lines must be exactly identical")
        XCTAssertEqual(forwardSteps.count, reverseSteps.count, "Step count with emissions must match")

        for i in 0..<forwardSteps.count {
            XCTAssertEqual(forwardSteps[i].lines, reverseSteps[i].lines, "Per-step line counts must match at step \(i)")
            XCTAssertEqual(forwardSteps[i].direction, .up)
            XCTAssertEqual(reverseSteps[i].direction, .down)
        }
    }

    func testKineticDecelerationMaxVelocityClamping() {
        let extremePositive = TerminalKineticDeceleration(initialVelocity: 15000.0)
        XCTAssertEqual(extremePositive.velocity, TerminalKineticDeceleration.defaultMaxVelocity)

        let extremeNegative = TerminalKineticDeceleration(initialVelocity: -12000.0)
        XCTAssertEqual(extremeNegative.velocity, -TerminalKineticDeceleration.defaultMaxVelocity)
    }

    func testKineticDecelerationCancellation() {
        var dec = TerminalKineticDeceleration(initialVelocity: 2000.0)
        XCTAssertTrue(dec.isDecelerating)
        _ = dec.step(deltaTime: 1.0 / 60.0, cellHeight: 20.0)
        XCTAssertGreaterThan(dec.velocity, 0)

        dec.cancel()
        XCTAssertFalse(dec.isDecelerating)
        XCTAssertEqual(dec.velocity, 0)
        XCTAssertEqual(dec.accumulatedPoints, 0)
        XCTAssertNil(dec.step(deltaTime: 1.0 / 60.0, cellHeight: 20.0))
    }
}

}
