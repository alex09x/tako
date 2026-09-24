import Foundation

/// Monotonic admission control for demand-driven terminal presentations.
/// Callers retain dirty work when a permit is unavailable and arrange one
/// later demand wakeup.
final class PresentationRateLimiter {
    /// A delayed main-queue work item must stay within DispatchTime's useful
    /// range. Values outside this range are treated like no cap rather than
    /// turning a typo such as `1e-100` into a decades-long retained wakeup.
    static let maximumInterval: TimeInterval = 24 * 60 * 60
    static let maximumFramesPerSecond: Double = 10_000
    var clock: () -> TimeInterval
    private var lastPermit: TimeInterval?

    private var configuredMaximumFramesPerSecond: Double?
    var maximumFramesPerSecond: Double? {
        get { configuredMaximumFramesPerSecond }
        set { configuredMaximumFramesPerSecond = Self.normalized(newValue) }
    }

    init(maximumFramesPerSecond: Double? = nil, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.configuredMaximumFramesPerSecond = Self.normalized(maximumFramesPerSecond)
        self.clock = clock
    }

    var delayUntilPermit: TimeInterval? {
        guard let interval, let lastPermit else { return nil }
        let now = clock()
        guard now.isFinite else { return nil }
        return max(0, interval - max(0, now - lastPermit))
    }

    func claimPermit() -> Bool {
        guard let delay = delayUntilPermit else {
            let now = clock()
            if now.isFinite { lastPermit = now }
            return true
        }
        guard delay <= 0.000_000_001 else { return false }
        let now = clock()
        if now.isFinite { lastPermit = now }
        return true
    }

    private var interval: TimeInterval? {
        guard let maximumFramesPerSecond else { return nil }
        let value = 1 / maximumFramesPerSecond
        return value.isFinite && value > 0 ? value : nil
    }

    private static func normalized(_ value: Double?) -> Double? {
        // Above this, the reciprocal is too small to be a useful scheduling
        // interval and can be rounded into an accidental busy loop.
        guard let value, value.isFinite,
              value >= 1 / maximumInterval,
              value <= maximumFramesPerSecond else { return nil }
        let interval = 1 / value
        return interval.isFinite && interval > 0 && interval <= maximumInterval ? value : nil
    }
}
