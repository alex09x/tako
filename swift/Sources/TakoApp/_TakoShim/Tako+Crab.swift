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

    /// One explicit status per pane from reported signals (B1).
    public enum PaneStatus: String, Codable, CaseIterable, Equatable, Sendable {
        case idle
        case running
        case working
        case waitingForInput = "waiting_for_input"
        case needsApproval = "needs_approval"
        case done
        case error
        case disconnected
        case unknown

        public static func parse(_ raw: String) -> PaneStatus? {
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "thinking" {
                return .working
            }
            return PaneStatus(rawValue: normalized)
        }

        /// Priority across panes in a tab:
        /// disconnected > error > needs_approval > waiting_for_input > working > running > done > idle > unknown
        public var priority: Int {
            switch self {
            case .disconnected: return 8
            case .error: return 7
            case .needsApproval: return 6
            case .waitingForInput: return 5
            case .working: return 4
            case .running: return 3
            case .done: return 2
            case .idle: return 1
            case .unknown: return 0
            }
        }

        public var crabState: CrabState {
            switch self {
            case .disconnected: return .ghost
            case .error: return .failed(code: nil)
            case .needsApproval, .waitingForInput: return .attention
            case .working, .running: return .running
            case .done: return .succeeded
            case .idle, .unknown: return .idle
            }
        }
    }

    /// Sanitizes status text: strips C0/C1 control characters, trims whitespace, limits length to 128 characters.
    public static func sanitizeStatusText(_ raw: String) -> String? {
        let filtered = raw.filter { char in
            guard let scalar = char.unicodeScalars.first, char.unicodeScalars.count == 1 else { return true }
            let val = scalar.value
            return !(val < 0x20 || val == 0x7f || (val >= 0x80 && val <= 0x9f))
        }
        let trimmed = filtered.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return String(trimmed.prefix(128))
    }

    /// Parses a duration string (e.g. "10m", "30s", "1h", "600") into seconds.
    public static func parseStatusDuration(_ raw: String) -> TimeInterval? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        let multiplier: Double
        let numStr: Substring
        if s.hasSuffix("ms") {
            multiplier = 0.001
            numStr = s.dropLast(2)
        } else if s.hasSuffix("s") {
            multiplier = 1.0
            numStr = s.dropLast(1)
        } else if s.hasSuffix("m") {
            multiplier = 60.0
            numStr = s.dropLast(1)
        } else if s.hasSuffix("h") {
            multiplier = 3600.0
            numStr = s.dropLast(1)
        } else if s.hasSuffix("d") {
            multiplier = 86400.0
            numStr = s.dropLast(1)
        } else {
            multiplier = 1.0
            numStr = s[...]
        }
        guard let val = Double(numStr), val > 0, val.isFinite else { return nil }
        return val * multiplier
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

    /// Tracks one surface's command lifecycle and turns it into a crab state,
    /// pane status, and elapsed time.
    @MainActor
    final class CrabTracker: ObservableObject {
        /// A command shorter than this never shows: `ls` and `cd` should not
        /// make the indicator twitch.
        static let minimumVisibleDuration: TimeInterval = 3

        /// How long a success stays green in a focused tab.
        static let successLinger: TimeInterval = 2

        @Published private(set) var state: CrabState = .idle
        public typealias ProgressState = TakoTerminalNSView.ProgressState

        /// Seconds since the running command started, or nil when idle.
        @Published private(set) var elapsed: TimeInterval?
        /// 0...100 from OSC 9;4, when the program reports it.
        @Published public private(set) var progress: Int?
        /// The progress state from OSC 9;4.
        @Published public private(set) var progressState: ProgressState = .none
        /// Set when something happened that the user has not looked at.
        @Published private(set) var unread = false

        /// Explicit pane status model (B1).
        @Published public private(set) var paneStatus: PaneStatus = .idle
        @Published public private(set) var statusText: String?
        @Published public private(set) var statusExpiresAt: Date?

        var signalStatus: PaneStatus = .idle {
            didSet {
                recomputeEffectiveStatus()
            }
        }
        private var explicitStatus: (status: PaneStatus, text: String?)?
        private var ttlTimer: Timer?

        /// Whether this pane is currently focused / looked at by user.
        public var isFocused: Bool = false

        private var startedAt: Date?
        private var ticker: Timer?
        private var successTimer: Timer?

        /// Injected so tests can run without a real clock.
        private let now: () -> Date

        init(now: @escaping () -> Date = Date.init) {
            self.now = now
        }

        convenience init(clock: @escaping () -> Date) {
            self.init(now: clock)
        }

        deinit {
            ticker?.invalidate()
            successTimer?.invalidate()
            ttlTimer?.invalidate()
        }

        func promptMark() {
            if !unread {
                signalStatus = .idle
            }
            recomputeEffectiveStatus()
        }

        func commandStarted() {
            startedAt = now()
            elapsed = nil
            progress = nil
            successTimer?.invalidate()
            signalStatus = .running
            unread = false
            recomputeEffectiveStatus()

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
            progressState = .none

            if let exitCode, exitCode != 0 {
                signalStatus = .error
                state = .failed(code: exitCode)
                unread = true
                recomputeEffectiveStatus()
                return
            }

            if isFocused {
                signalStatus = .idle
                unread = false
            } else {
                signalStatus = .done
                unread = true
            }

            // A command too short to have shown as running should not flash
            // green either.
            guard let ran, ran >= Self.minimumVisibleDuration else {
                state = .idle
                recomputeEffectiveStatus()
                return
            }
            state = .succeeded
            recomputeEffectiveStatus()
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

        func progressReported(state: UInt8, value: UInt8?) {
            switch state {
            case 0:
                progressState = .none
                progress = nil
            case 1:
                progressState = .normal
                progress = value.map(Int.init)
            case 2:
                progressState = .error
                progress = value.map(Int.init)
            case 3:
                progressState = .indeterminate
                progress = value.map(Int.init)
            case 4:
                progressState = .paused
                progress = value.map(Int.init)
            default:
                progressState = .none
                progress = nil
            }
        }

        func connectionLost() {
            progress = nil
            progressState = .none
            signalStatus = .disconnected
            state = .ghost
            unread = true
            recomputeEffectiveStatus()
        }

        func reconnecting() {
            state = .reconnecting
        }

        /// Set explicit pane status, with optional text and TTL.
        func setStatus(_ statusString: String, text: String?, ttl: TimeInterval? = nil) {
            guard let parsed = PaneStatus.parse(statusString) else { return }
            setStatus(parsed, text: text, ttl: ttl)
        }

        /// Set explicit pane status, with optional text and TTL.
        func setStatus(_ status: PaneStatus, text: String?, ttl: TimeInterval? = nil) {
            ttlTimer?.invalidate()
            ttlTimer = nil

            let sanitizedText = text.flatMap(Tako.sanitizeStatusText)
            explicitStatus = (status: status, text: sanitizedText)
            statusText = sanitizedText

            if let ttl, ttl > 0 {
                let expires = now().addingTimeInterval(ttl)
                statusExpiresAt = expires
                ttlTimer = Timer.scheduledTimer(withTimeInterval: ttl, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.ttlExpired()
                    }
                }
            } else {
                statusExpiresAt = nil
            }
            recomputeEffectiveStatus()
        }

        /// Clears explicit status, reverting to signal-derived state.
        func clearStatus() {
            ttlTimer?.invalidate()
            ttlTimer = nil
            explicitStatus = nil
            statusText = nil
            statusExpiresAt = nil
            recomputeEffectiveStatus()
        }

        /// Called when TTL timer fires: status expires to unknown.
        func ttlExpired() {
            ttlTimer?.invalidate()
            ttlTimer = nil
            explicitStatus = (status: .unknown, text: nil)
            statusText = nil
            statusExpiresAt = nil
            recomputeEffectiveStatus()
        }

        /// Remaining seconds on the TTL timer, or nil if none is armed.
        public var remainingTTL: TimeInterval? {
            guard let expiresAt = statusExpiresAt else { return nil }
            let remaining = expiresAt.timeIntervalSince(now())
            return max(0, remaining)
        }

        private func recomputeEffectiveStatus() {
            if let explicit = explicitStatus {
                paneStatus = explicit.status
                statusText = explicit.text
                state = paneStatus.crabState
            } else {
                paneStatus = signalStatus
                statusText = nil
                if case .failed = state, signalStatus == .error {
                    // keep failed state
                } else if case .succeeded = state {
                    // keep succeeded state
                } else if case .ghost = state, signalStatus == .disconnected {
                    // keep ghost state
                } else if case .running = state, signalStatus == .running {
                    // keep running state
                } else {
                    state = paneStatus.crabState
                }
            }
        }

        /// The user looked at this tab/pane: clear what was waiting for them.
        func focused() {
            isFocused = true
            unread = false
            if signalStatus == .done || signalStatus == .error {
                signalStatus = .idle
            }
            switch state {
            case .succeeded, .failed, .attention: state = .idle
            default: break
            }
            recomputeEffectiveStatus()
        }

        func unfocused() {
            isFocused = false
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
