import XCTest
@testable import TakoCoreUI

/// The arithmetic behind sub-cell scrolling, driven directly.
///
/// A precise `NSEvent` cannot be synthesised faithfully, so the rule the
/// trackpad drives was extracted into `SubCellScrollAccumulator` and is
/// exercised here as the gesture exercises it.
final class SubCellScrollTests: XCTestCase {
    private let pointsPerLine: CGFloat = 3

    /// Everything else depends on this: the remainder is never positive, so
    /// the grid is always drawn one row further back and translated up, and
    /// the strip that opens is always the bottom one.
    func testRemainderIsNeverPositiveInEitherDirection() {
        var acc = SubCellScrollAccumulator()
        // Deliberately mixed: small, large, and sign-changing, including
        // deltas that land exactly on a row boundary.
        let deltas: [CGFloat] = [0.4, 1.7, -0.2, -5.5, 3.0, 0.1, -0.1, 12.4, -12.4, 9, -0.9, 0.9]
        for delta in deltas {
            _ = acc.accumulatePrecise(deltaY: delta, pointsPerLine: pointsPerLine)
            XCTAssertLessThanOrEqual(acc.presentedRows, 0, "delta \(delta) left a positive remainder")
            XCTAssertGreaterThan(acc.presentedRows, -1, "delta \(delta) left a whole row unpresented")
        }
    }

    /// Nothing is lost and nothing is invented: what was scrolled plus what is
    /// being translated equals what the trackpad reported, exactly.
    func testCarryIsExactAcrossRowBoundariesAndReversals() {
        var acc = SubCellScrollAccumulator()
        let deltas: [CGFloat] = [1.1, 0.9, 0.7, -2.4, -0.3, 4.8, -4.8, 0.05, 0.05, 0.05]
        var scrolledRows = 0
        for delta in deltas {
            scrolledRows += acc.accumulatePrecise(deltaY: delta, pointsPerLine: pointsPerLine)
        }
        let reported = deltas.reduce(0, +) / pointsPerLine
        let presented = CGFloat(scrolledRows) + acc.presentedRows
        XCTAssertEqual(presented, reported, accuracy: 1e-9)
    }

    /// An immediate reversal is a position change like any other -- it must
    /// not strand a row or double one back.
    func testImmediateReversalReturnsToWhereItStarted() {
        var acc = SubCellScrollAccumulator()
        var scrolled = 0
        scrolled += acc.accumulatePrecise(deltaY: 2.5, pointsPerLine: pointsPerLine)
        scrolled += acc.accumulatePrecise(deltaY: -2.5, pointsPerLine: pointsPerLine)
        XCTAssertEqual(CGFloat(scrolled) + acc.presentedRows, 0, accuracy: 1e-9)
    }

    /// Sub-row motion moves nothing in the engine but is still presented.
    func testSubRowMotionScrollsNoRowsAndIsCarriedAsTranslation() {
        var acc = SubCellScrollAccumulator()
        let rows = acc.accumulatePrecise(deltaY: 1.2, pointsPerLine: pointsPerLine)
        // 0.4 of a row: the grid goes back a whole row and is translated up
        // 0.6 of one, which nets to the 0.4 that was asked for.
        XCTAssertEqual(rows, 1)
        XCTAssertEqual(acc.presentedRows, -0.6, accuracy: 1e-9)
    }

    /// A notch is a whole row by definition; there is nothing under it.
    func testNotchedWheelLeavesNothingToTranslate() {
        var acc = SubCellScrollAccumulator()
        _ = acc.accumulatePrecise(deltaY: 1.2, pointsPerLine: pointsPerLine)
        XCTAssertNotEqual(acc.presentedRows, 0)
        let rows = acc.accumulateNotched(deltaY: 3)
        XCTAssertEqual(rows, 3)
        XCTAssertEqual(acc.presentedRows, 0, "a notch must not leave a fraction behind")
    }

    /// At the tail there is no line below the screen, so there is nothing for
    /// a translation to expose. Present the boundary exactly.
    func testTailBoundaryPresentsExactlyRatherThanAFractionPastIt() {
        var acc = SubCellScrollAccumulator()
        _ = acc.accumulatePrecise(deltaY: -0.9, pointsPerLine: pointsPerLine)
        XCTAssertLessThan(acc.presentedRows, 0)
        acc.settleAtBoundary(requestedRows: 0, offsetBefore: 0, offsetAfter: 0)
        XCTAssertEqual(acc.presentedRows, 0)
    }

    /// The far end of the scrollback clamps too: the engine did not move as
    /// far as asked, so the translation would be past the content.
    func testClampedScrollDropsTheTranslation() {
        var acc = SubCellScrollAccumulator()
        let rows = acc.accumulatePrecise(deltaY: 7, pointsPerLine: pointsPerLine)
        XCTAssertGreaterThan(rows, 0)
        XCTAssertLessThan(acc.presentedRows, 0)
        // Asked for `rows`, the viewport only moved one.
        acc.settleAtBoundary(requestedRows: rows, offsetBefore: 40, offsetAfter: 41)
        XCTAssertEqual(acc.presentedRows, 0)
    }

    /// An unclamped scroll keeps its translation.
    func testUnclampedScrollKeepsTheTranslation() {
        var acc = SubCellScrollAccumulator()
        let rows = acc.accumulatePrecise(deltaY: 7, pointsPerLine: pointsPerLine)
        let carried = acc.presentedRows
        acc.settleAtBoundary(requestedRows: rows, offsetBefore: 10, offsetAfter: 10 + rows)
        XCTAssertEqual(acc.presentedRows, carried)
    }

    /// A new gesture starts from nothing.
    func testGestureStartDropsThePreviousTail() {
        var acc = SubCellScrollAccumulator()
        _ = acc.accumulatePrecise(deltaY: 1.4, pointsPerLine: pointsPerLine)
        XCTAssertNotEqual(acc.presentedRows, 0)
        acc.begin()
        XCTAssertEqual(acc.presentedRows, 0)
    }

    /// A degenerate metric must not produce a translation or a NaN.
    func testNonFiniteOrZeroMetricIsIgnored() {
        var acc = SubCellScrollAccumulator()
        XCTAssertEqual(acc.accumulatePrecise(deltaY: 5, pointsPerLine: 0), 0)
        XCTAssertEqual(acc.presentedRows, 0)
        XCTAssertEqual(acc.accumulatePrecise(deltaY: .nan, pointsPerLine: pointsPerLine), 0)
        XCTAssertEqual(acc.presentedRows, 0)
    }

    func testWheelReportAccumulatorCarriesNormalMotionButBoundsAndDropsBurstBacklog() {
        var reports = WheelReportAccumulator()
        XCTAssertEqual(reports.accumulatePrecise(deltaY: 1, pointsPerStep: 3, maximumSteps: 10), 0)
        XCTAssertEqual(reports.residualSteps, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(reports.accumulatePrecise(deltaY: 8, pointsPerStep: 3, maximumSteps: 10), 3)
        XCTAssertEqual(reports.residualSteps, 0)
        XCTAssertEqual(reports.accumulateNotched(deltaY: 99, maximumSteps: 10), 10)
        XCTAssertEqual(reports.residualSteps, 0, "a capped burst must not be retained for later callbacks")
        XCTAssertEqual(reports.accumulatePrecise(deltaY: .infinity, pointsPerStep: 3, maximumSteps: 10), 0)
    }

    func testWheelReportAccumulatorCarriesMultiStepFractionThroughReversal() {
        var reports = WheelReportAccumulator()

        XCTAssertEqual(reports.accumulatePrecise(deltaY: 8, pointsPerStep: 3, maximumSteps: 10), 2)
        XCTAssertEqual(reports.residualSteps, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(reports.accumulatePrecise(deltaY: -6, pointsPerStep: 3, maximumSteps: 10), -1)
        XCTAssertEqual(reports.residualSteps, -1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(reports.accumulatePrecise(deltaY: 1, pointsPerStep: 3, maximumSteps: 10), 0)
        XCTAssertEqual(reports.residualSteps, 0, accuracy: 1e-9)
    }

    func testWheelReportAccumulatorCapsFiniteHugeDeltaWithoutRetainingBacklog() {
        var reports = WheelReportAccumulator()

        XCTAssertEqual(
            reports.accumulatePrecise(
                deltaY: CGFloat.greatestFiniteMagnitude,
                pointsPerStep: 3,
                maximumSteps: 10),
            10)
        XCTAssertEqual(reports.residualSteps, 0, accuracy: 1e-9)
        XCTAssertEqual(reports.accumulatePrecise(deltaY: 1, pointsPerStep: 3, maximumSteps: 10), 0)
        XCTAssertEqual(reports.residualSteps, 1.0 / 3.0, accuracy: 1e-9)
    }

    /// The uniform the shader reads is laid out as three `float2`. If this
    /// drifts, every pass silently samples the wrong field.
    func testViewportUniformMatchesTheShaderLayout() {
        XCTAssertEqual(MemoryLayout<TerminalMetalViewport>.size, 24)
        XCTAssertEqual(MemoryLayout<TerminalMetalViewport>.stride, 24)
        var vp = TerminalMetalViewport(drawableWidth: 100, drawableHeight: 200, backingScale: 2)
        vp.verticalPixelOffset = -7.5
        withUnsafeBytes(of: &vp) { raw in
            XCTAssertEqual(raw.load(fromByteOffset: 0, as: Float.self), 100)
            XCTAssertEqual(raw.load(fromByteOffset: 4, as: Float.self), 200)
            XCTAssertEqual(raw.load(fromByteOffset: 8, as: Float.self), 2)
            // _offsetPad.x in the shader.
            XCTAssertEqual(raw.load(fromByteOffset: 16, as: Float.self), -7.5)
        }
    }

    /// A frame with no translation must be laid out exactly as it always was.
    /// This is the path iOS uses and it must not have moved.
    func testZeroOffsetViewportIsUnchanged() {
        let vp = TerminalMetalViewport(drawableSize: CGSize(width: 640, height: 480), backingScale: 2)
        XCTAssertEqual(vp.verticalPixelOffset, 0)
        XCTAssertEqual(vp.drawablePixelSize, SIMD2<Float>(640, 480))
        XCTAssertEqual(vp.logicalPointSize, SIMD2<Float>(320, 240))
    }
}
