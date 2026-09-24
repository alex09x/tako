import CoreGraphics

/// The rule that turns scroll deltas into whole rows plus a sub-row
/// translation.
///
/// Extracted from `TakoTerminalNSView.scrollWheel` rather than duplicated:
/// a precise `NSEvent` cannot be synthesised faithfully in a test, so the
/// arithmetic that decides what is scrolled and what is translated lives
/// here, where a test drives exactly the code the trackpad drives.
///
/// The invariant the whole design rests on is that `presentedRows` is always
/// in `(-1, 0]`. Whole rows are rounded *away from the tail*, so the grid is
/// always positioned one row further back than the eye should see and then
/// translated up into place. Only the bottom edge is ever exposed -- in both
/// directions and across a reversal -- and the core's overscan row is what
/// fills it.
public struct SubCellScrollAccumulator: Equatable, Sendable {
    /// Sub-row motion still to be presented as a translation. Never positive.
    public private(set) var presentedRows: CGFloat = 0

    public init() {}

    /// A new gesture does not inherit the tail of the last one.
    public mutating func begin() {
        presentedRows = 0
    }

    /// Precise (trackpad) motion: points in, whole rows out, remainder kept.
    ///
    /// - Returns: whole rows to scroll, positive toward the scrollback.
    public mutating func accumulatePrecise(deltaY: CGFloat, pointsPerLine: CGFloat) -> Int {
        guard pointsPerLine > 0, deltaY.isFinite else { return 0 }
        presentedRows += deltaY / pointsPerLine
        let whole = presentedRows.rounded(.up)
        presentedRows -= whole
        return Int(whole)
    }

    /// A notched wheel reports whole lines already, so nothing is left over.
    public mutating func accumulateNotched(deltaY: CGFloat) -> Int {
        presentedRows = 0
        guard deltaY.isFinite else { return 0 }
        return Int(deltaY.rounded())
    }

    /// Present an exact boundary instead of a fraction past one.
    ///
    /// Called with what the viewport offset actually became. Past a clamp --
    /// either end of the scrollback -- the row a translation would expose is
    /// not there, so there is nothing to translate into.
    public mutating func settleAtBoundary(requestedRows: Int, offsetBefore: Int, offsetAfter: Int) {
        if offsetAfter != offsetBefore + requestedRows { presentedRows = 0 }
        if offsetAfter == 0, presentedRows < 0 { presentedRows = 0 }
    }

    /// A reporting mode owns the wheel; there is nothing to present under it.
    public mutating func clear() {
        presentedRows = 0
    }
}

/// Whole wheel steps for a program that asked for mouse reports.
///
/// The protocol has no fractions: a wheel report is a discrete step, and
/// there is nothing to translate under a program that owns the wheel. But a
/// trackpad still reports points, so the remainder has to go somewhere.
///
/// The 16f3d0a baseline promoted every nonzero sub-threshold precise event to
/// a full report, which at trackpad event rates reports many more steps than
/// the finger travelled. Carrying the remainder instead drops nothing and
/// bounds the report rate by actual motion rather than by event count.
///
/// Rounds toward zero, unlike `SubCellScrollAccumulator`: that one biases away
/// from the tail so a translation always has a row to expose, and here there
/// is no translation to serve.
public struct WheelReportAccumulator: Equatable, Sendable {
    /// Motion that has not yet added up to a whole step.
    public private(set) var residualSteps: CGFloat = 0

    public init() {}

    /// A new gesture does not inherit the tail of the last one.
    public mutating func begin() {
        residualSteps = 0
    }

    /// Forget motion accumulated for a program which no longer owns the
    /// wheel. Keeping it would make a later mode change manufacture input
    /// from an earlier gesture.
    public mutating func clear() {
        residualSteps = 0
    }

    /// Precise (trackpad) motion, in points.
    ///
    /// - Returns: whole steps, positive toward the scrollback. Zero only when
    ///   the motion so far genuinely has not reached one step.
    public mutating func accumulatePrecise(
        deltaY: CGFloat,
        pointsPerStep: CGFloat,
        maximumSteps: Int = .max
    ) -> Int {
        guard pointsPerStep > 0, deltaY.isFinite else { return 0 }
        residualSteps += deltaY / pointsPerStep
        guard residualSteps.isFinite else {
            residualSteps = 0
            return 0
        }
        let whole = residualSteps.rounded(.towardZero)
        residualSteps -= whole
        return boundedSteps(whole, maximumSteps: maximumSteps)
    }

    /// A notched wheel already reports whole steps.
    public mutating func accumulateNotched(deltaY: CGFloat, maximumSteps: Int = .max) -> Int {
        residualSteps = 0
        guard deltaY.isFinite else { return 0 }
        return boundedSteps(deltaY.rounded(), maximumSteps: maximumSteps)
    }

    /// Bounds one callback without retaining an oversized backlog that would
    /// subsequently flood the PTY. Normal deltas retain their full magnitude.
    private func boundedSteps(_ value: CGFloat, maximumSteps: Int) -> Int {
        let cap = max(0, maximumSteps)
        guard cap > 0, value != 0 else { return 0 }
        // CGFloat cannot represent Int.max exactly on 64-bit platforms; this
        // still far exceeds any real event while making conversion safe.
        let finiteCap = min(cap, Int.max / 2)
        let magnitude = min(abs(value), CGFloat(finiteCap))
        return value.sign == .minus ? -Int(magnitude) : Int(magnitude)
    }
}
