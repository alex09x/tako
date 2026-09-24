import Foundation

/// Direction of a touch-pan or wheel scroll.
public enum TerminalPanDirection: Sendable, Equatable {
    /// Panning down (translation.y > 0) -> scrolling up toward top / history / earlier content.
    case up
    /// Panning up (translation.y < 0) -> scrolling down toward live bottom / later content.
    case down
}

/// Action to perform when handling a touch-pan gesture.
public enum TerminalTouchScrollAction: Equatable {
    case scrollViewportUp(lines: Int)
    case scrollViewportDown(lines: Int)
    case sendInput(Data)
    case none
}

/// Pure deterministic helper that computes the scroll action for a touch pan.
public enum TerminalTouchScrollDecision {
    /// Maximum number of synthetic mouse-wheel reports or arrow-key escape sequences emitted
    /// in a single gesture callback frame. Clamping prevents a fast flick or touch jitter burst
    /// from flooding the PTY connection with hundreds of repetitive sequences while preserving
    /// normal swipe scrolling (typically 1-5 lines per frame).
    public static let maxLinesPerGestureCallback: Int = 10

    public static func decide(
        lines: Int,
        direction: TerminalPanDirection,
        modes: FfiTerminalModes,
        touchCol: Int,
        touchRow: Int,
        core: TakoCore
    ) -> TerminalTouchScrollAction {
        guard lines >= 1 else { return .none }

        // Alternate screen or primary screen with mouse tracking
        let isUp = (direction == .up)
        let emissionLines = min(lines, maxLinesPerGestureCallback)
        guard emissionLines >= 1 else { return .none }

        // 1. Mouse tracking outranks local scrolling and alternate scroll mode whenever active
        // (representative of Claude and modern full-screen TUIs on both primary and alternate screens)
        if modes.mouseTracking != .off {
            let mouseEvent = FfiMouseEvent(
                button: isUp ? .wheelUp : .wheelDown,
                action: .press,
                shift: false,
                alt: false,
                ctrl: false,
                col: UInt32(max(0, touchCol)),
                row: UInt32(max(0, touchRow))
            )
            let singleEventData = core.encodeMouse(event: mouseEvent)
            guard !singleEventData.isEmpty else { return .none }

            var combinedData = Data()
            for _ in 0..<emissionLines {
                combinedData.append(singleEventData)
            }
            return .sendInput(combinedData)
        }

        // 2. Primary screen without mouse tracking -> moves local scrollback
        if !modes.alternateScreen {
            switch direction {
            case .up:
                return .scrollViewportUp(lines: lines)
            case .down:
                return .scrollViewportDown(lines: lines)
            }
        }

        // 3. Alternate screen without mouse tracking: DEC alternate scroll mode (1007)
        if modes.alternateScroll {
            let keyEvent = FfiKeyEvent(
                key: isUp ? .up : .down,
                text: "",
                physicalText: "",
                unshiftedText: "",
                shift: false,
                alt: false,
                ctrl: false,
                superKey: false,
                press: true,
                repeat: false,
                composing: false
            )
            let singleKeyData = core.encodeKey(event: keyEvent)
            guard !singleKeyData.isEmpty else { return .none }

            var combinedData = Data()
            for _ in 0..<emissionLines {
                combinedData.append(singleKeyData)
            }
            return .sendInput(combinedData)
        }

        return .none
    }
}

extension FfiTerminalModes {
    public init(
        autowrap: Bool,
        originMode: Bool,
        cursorKeyAppMode: Bool,
        mouseTracking: FfiMouseTracking,
        mouseUtf8: Bool,
        mouseSgr: Bool,
        focusEvents: Bool,
        bracketedPaste: Bool
    ) {
        self.init(
            autowrap: autowrap,
            originMode: originMode,
            cursorKeyAppMode: cursorKeyAppMode,
            mouseTracking: mouseTracking,
            mouseUtf8: mouseUtf8,
            mouseSgr: mouseSgr,
            focusEvents: focusEvents,
            bracketedPaste: bracketedPaste,
            alternateScreen: false,
            alternateScroll: true
        )
    }
}

/// Pure mathematical model for UIKit-style scroll momentum and kinetic deceleration.
public struct TerminalKineticDeceleration: Sendable, Equatable {
    /// Standard UIKit scroll deceleration factor (0.998 per millisecond).
    public static let defaultDecelerationRate: Double = 0.998
    /// Minimum initial velocity in points/second to engage momentum on release.
    public static let defaultMinimumVelocity: Double = 80.0
    /// Terminal velocity threshold in points/second where momentum stops.
    public static let defaultStopVelocity: Double = 15.0
    /// Maximum velocity cap in points/second to prevent unbounded runaway flicks.
    public static let defaultMaxVelocity: Double = 5000.0

    public private(set) var velocity: Double
    public private(set) var accumulatedPoints: Double = 0
    public private(set) var isDecelerating: Bool = false
    public let decelerationRate: Double
    public let minimumVelocity: Double
    public let stopVelocity: Double
    public let maxVelocity: Double

    public init(
        initialVelocity: Double = 0,
        decelerationRate: Double = defaultDecelerationRate,
        minimumVelocity: Double = defaultMinimumVelocity,
        stopVelocity: Double = defaultStopVelocity,
        maxVelocity: Double = defaultMaxVelocity
    ) {
        self.decelerationRate = decelerationRate
        self.minimumVelocity = minimumVelocity
        self.stopVelocity = stopVelocity
        self.maxVelocity = maxVelocity

        let absVel = abs(initialVelocity)
        if absVel >= minimumVelocity {
            let clampedAbs = min(absVel, maxVelocity)
            self.velocity = initialVelocity < 0 ? -clampedAbs : clampedAbs
            self.isDecelerating = true
        } else {
            self.velocity = 0
            self.isDecelerating = false
        }
    }

    /// Advances the kinetic deceleration by `deltaTime` seconds.
    ///
    /// Computes continuous displacement according to the exponential decay integral,
    /// accumulates points against `cellHeight`, and returns the integral lines and direction
    /// to advance if at least one full cell height was crossed.
    public mutating func step(
        deltaTime: TimeInterval,
        cellHeight: Double
    ) -> (lines: Int, direction: TerminalPanDirection)? {
        guard isDecelerating, cellHeight > 0, deltaTime > 0 else { return nil }

        let decay = pow(decelerationRate, deltaTime * 1000.0)
        let alphaCoeff = 1000.0 * log(decelerationRate)

        // Exact integral: deltaY = v * (decay - 1) / alpha
        let deltaY = (abs(alphaCoeff) > 1e-9)
            ? velocity * (decay - 1.0) / alphaCoeff
            : velocity * deltaTime

        velocity *= decay
        accumulatedPoints += deltaY

        if abs(velocity) < stopVelocity {
            isDecelerating = false
            velocity = 0
        }

        let lines = Int(abs(accumulatedPoints) / cellHeight)
        if lines >= 1 {
            let direction: TerminalPanDirection = accumulatedPoints > 0 ? .up : .down
            accumulatedPoints = accumulatedPoints.truncatingRemainder(dividingBy: cellHeight)
            return (lines: lines, direction: direction)
        } else {
            if !isDecelerating {
                accumulatedPoints = 0
            }
            return nil
        }
    }

    /// Cancels active deceleration and resets velocity and accumulators.
    public mutating func cancel() {
        velocity = 0
        accumulatedPoints = 0
        isDecelerating = false
    }
}
