import AppKit
import Foundation

// The crab indicator that sits in each tab.
//
// The brand's design gives it seven states and a strict priority between
// them, so the state lives here rather than being inferred at draw time:
// a tab's crab has to survive going to the background, and a background
// tab that failed must stay red until the user looks at it.

extension Tako {
    enum CrabState: Equatable {
        /// No command running, or one that finished too fast to be worth
        /// showing.
        case idle
        /// A command has been running long enough to show.
        case running
        /// The last command exited zero. Reverts to `idle` after a beat in
        /// the focused tab; in a background tab it waits to be seen.
        case succeeded
        /// The last command failed. Holds until the tab is focused.
        case failed(code: Int32?)
        /// The terminal rang the bell, or sent a notification.
        case attention
        /// Reconnecting an ssh session.
        case reconnecting
        /// The connection dropped; the screen is kept as it was.
        case ghost

        /// When several could apply at once, the design fixes this order.
        var priority: Int {
            switch self {
            case .ghost: return 6
            case .failed: return 5
            case .running: return 4
            case .attention: return 3
            case .succeeded: return 2
            case .idle: return 1
            case .reconnecting: return 0
            }
        }

        /// Ember by default; success and failure recolour it.
        var color: NSColor {
            switch self {
            case .succeeded: return Tako.Brand.ok
            case .failed: return Tako.Brand.error
            case .ghost: return Tako.Brand.dim
            default: return Tako.Brand.ember
            }
        }
    }

    /// The brand palette.
    enum Brand {
        static let ember = NSColor(srgbRed: 0xF4 / 255, green: 0x58 / 255, blue: 0x1C / 255, alpha: 1)
        static let claw = NSColor(srgbRed: 0xFF / 255, green: 0x7A / 255, blue: 0x3D / 255, alpha: 1)
        static let rust = NSColor(srgbRed: 0xC2 / 255, green: 0x3E / 255, blue: 0x0E / 255, alpha: 1)
        static let ink = NSColor(srgbRed: 0x1A / 255, green: 0x15 / 255, blue: 0x12 / 255, alpha: 1)
        static let paper = NSColor(srgbRed: 0xFA / 255, green: 0xF7 / 255, blue: 0xF2 / 255, alpha: 1)
        /// Terminal body and chrome, warm rather than blue.
        static let surface = NSColor(srgbRed: 0x14 / 255, green: 0x10 / 255, blue: 0x0E / 255, alpha: 1)
        static let text = NSColor(srgbRed: 0xED / 255, green: 0xE6 / 255, blue: 0xDF / 255, alpha: 1)
        static let dim = NSColor(srgbRed: 0x8A / 255, green: 0x7F / 255, blue: 0x76 / 255, alpha: 1)
        static let ok = NSColor(srgbRed: 0x7B / 255, green: 0xD8 / 255, blue: 0x8F / 255, alpha: 1)
        static let error = NSColor(srgbRed: 0xD5 / 255, green: 0x4E / 255, blue: 0x53 / 255, alpha: 1)
    }

    /// Tracks one surface's command lifecycle and turns it into a crab state
    /// and an elapsed time.
    @MainActor
    final class CrabTracker: ObservableObject {
        /// A command shorter than this never shows: `ls` and `cd` should not
        /// make the indicator twitch.
        static let minimumVisibleDuration: TimeInterval = 3

        /// How long a success stays green in a focused tab.
        static let successLinger: TimeInterval = 2

        @Published private(set) var state: CrabState = .idle
        /// Seconds since the running command started, or nil when idle.
        @Published private(set) var elapsed: TimeInterval?
        /// 0...100 from OSC 9;4, when the program reports it.
        @Published private(set) var progress: Int?
        /// Set when something happened that the user has not looked at.
        @Published private(set) var unread = false

        private var startedAt: Date?
        private var ticker: Timer?
        private var successTimer: Timer?

        /// Injected so tests can run without a real clock.
        private let now: () -> Date

        init(now: @escaping () -> Date = Date.init) {
            self.now = now
        }

        deinit {
            ticker?.invalidate()
            successTimer?.invalidate()
        }

        func commandStarted() {
            startedAt = now()
            elapsed = nil
            progress = nil
            successTimer?.invalidate()
            // The state only becomes `.running` once the command has lasted
            // long enough to be worth showing.
            ticker?.invalidate()
            ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }

        func commandEnded(exitCode: Int32?) {
            ticker?.invalidate()
            ticker = nil
            let ran = startedAt.map { now().timeIntervalSince($0) }
            startedAt = nil
            elapsed = nil
            progress = nil

            if let exitCode, exitCode != 0 {
                state = .failed(code: exitCode)
                unread = true
                return
            }
            // A command too short to have shown as running should not flash
            // green either.
            guard let ran, ran >= Self.minimumVisibleDuration else {
                state = .idle
                return
            }
            state = .succeeded
            unread = true
            successTimer?.invalidate()
            successTimer = Timer.scheduledTimer(withTimeInterval: Self.successLinger, repeats: false) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, case .succeeded = self.state, !self.unread else { return }
                    self.state = .idle
                }
            }
        }

        func bellRang() {
            // Never override something more important.
            if CrabState.attention.priority > state.priority { state = .attention }
            unread = true
        }

        func progressReported(state progressState: UInt8, value: UInt8?) {
            // 0 removes the report; anything else sets or replaces it.
            progress = progressState == 0 ? nil : value.map(Int.init)
        }

        func connectionLost() { state = .ghost; unread = true }
        func reconnecting() { state = .reconnecting }

        /// The user looked at this tab: clear what was waiting for them.
        func focused() {
            unread = false
            switch state {
            case .succeeded, .failed, .attention: state = .idle
            default: break
            }
        }

        /// Advance the running clock. Public so a test can drive it without
        /// waiting on a real timer.
        func tick() {
            guard let startedAt else { return }
            let ran = now().timeIntervalSince(startedAt)
            guard ran >= Self.minimumVisibleDuration else { return }
            elapsed = ran
            if CrabState.running.priority > state.priority || state == .idle {
                state = .running
            }
        }

        /// The one duration format: a tenth under ten seconds, whole
        /// seconds up to a minute, minutes and seconds beyond. The prompt
        /// uses the same one.
        static func durationLabel(_ seconds: TimeInterval) -> String {
            if seconds < 10 { return String(format: "%.1fs", seconds) }
            if seconds < 60 { return "\(Int(seconds))s" }
            return String(format: "%dm %02ds", Int(seconds) / 60, Int(seconds) % 60)
        }

        var elapsedLabel: String? {
            elapsed.map(Self.durationLabel)
        }
    }
}
