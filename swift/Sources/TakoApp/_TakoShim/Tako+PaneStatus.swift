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

extension Tako {
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

        /// Canonical status palette key ("ember", "claw", "ok", "error", "dim") matching TabBarView.
        public var dotKey: String {
            switch self {
            case .working, .running: return "ember"
            case .needsApproval, .waitingForInput: return "claw"
            case .done: return "ok"
            case .error: return "error"
            case .idle, .disconnected, .unknown: return "dim"
            }
        }

        /// Live status dot color for Session Sidebar rows and Workspace headers, respecting theme overrides.
        @MainActor
        public var sidebarDotColor: NSColor {
            Tako.tabStatusColor(for: dotKey)
        }

        /// UI Kit indicator and chip accent color per Spec 1b (§0 & §6).
        @MainActor
        public var uiChipColor: NSColor {
            switch self {
            case .needsApproval, .waitingForInput:
                if let color = Tako.activeTabStatusTheme?.tabStatusColors["waiting"],
                   let nsColor = NSColor(cgColor: color) {
                    return nsColor
                }
                return Tako.Brand.claw
            default:
                return sidebarDotColor
            }
        }

        /// Whether this status represents an agent waiting on human input or approval.
        public var isWaitingForHuman: Bool {
            switch self {
            case .needsApproval, .waitingForInput: return true
            default: return false
            }
        }

        /// Compact status badge label shown in Session Sidebar and Pane Overview chips when non-idle (§1).
        public var sidebarBadgeLabel: String? {
            switch self {
            case .needsApproval: return "Approval"
            case .waitingForInput: return "Needs input"
            case .error: return "Failed"
            case .done: return "Done"
            case .working, .running: return "Working"
            case .disconnected: return "Offline"
            case .idle, .unknown: return nil
            }
        }

        /// Unified UI Kit chip label used in Pane Overview cards and Sidebar chips (§1).
        public var overviewChipLabel: String {
            sidebarBadgeLabel ?? "Idle"
        }

        /// Whether the status indicator should display an active animation in the sidebar.
        public var isSidebarPulsing: Bool {
            switch self {
            case .working, .running: return true
            default: return false
            }
        }

        /// Maps `PaneStatus` and optional OSC 9;4 progress to the unified `SurfaceState` (§1).
        public func surfaceState(
            progressState: TakoTerminalNSView.ProgressState = .none,
            progressFraction: Double? = nil,
            elapsedSeconds: TimeInterval? = nil,
            crabState: Tako.CrabState? = nil,
            live: Tako.LiveActivity? = nil
        ) -> Tako.SurfaceState {
            switch self {
            case .disconnected:
                return .offline
            case .error:
                return .failed
            case .needsApproval, .waitingForInput:
                return .waiting
            case .working, .running:
                if progressState != .none, let p = progressFraction {
                    return .progress(min(1.0, max(0.0, p)))
                }
                if self == .running, let elapsedSeconds, elapsedSeconds < 3.0 {
                    return .idle
                }
                // Spec 1b: "working" only once a command has run > 3 s. The
                // crab turns `.running` at that point; before it, a shell
                // command is still quiet.
                if self == .running, let crabState, crabState != .running {
                    return .idle
                }
                return .working
            case .done:
                return .done
            case .idle, .unknown:
                if progressState != .none, let p = progressFraction {
                    return .progress(min(1.0, max(0.0, p)))
                }
                if let live { return .live(flowing: live.isFlowing) }
                return .idle
            }
        }
    }

    /// Unified Living Surface state across Pill Tabs, Session Sidebar, and Pane Overview (Spec 1b §1).
    public enum SurfaceState: Equatable, Sendable {
        case idle
        case working
        case progress(Double /* 0...1 */)
        /// A quiet program runs -- ssh, vim, a stream, a server -- and
        /// `flowing` while its output arrives (Sessions UI 5a).
        case live(flowing: Bool)
        case waiting
        case done
        case failed
        case offline

        /// A quiet program runs, whether or not its output is arriving.
        public var isLive: Bool {
            if case .live = self { return true }
            return false
        }

        /// Priority when aggregating across split panes, tabs, or workspaces:
        /// offline > failed > waiting > working > progress > done > live > idle
        public var priority: Int {
            switch self {
            case .offline: return 7
            case .failed: return 6
            case .waiting: return 5
            case .working: return 4
            case .progress: return 3
            case .done: return 2
            case .live: return 1
            case .idle: return 0
            }
        }
    }

    /// Formats a directory path per the Tako design spec: `$HOME` -> `~`, keeping at most 2 path segments.
    public static func formatCompactDirectory(_ rawPath: String?) -> String {
        guard let rawPath, !rawPath.isEmpty else { return "~" }
        let home = NSHomeDirectory()
        var path = rawPath
        var hasHomePrefix = false

        if path == home {
            return "~"
        } else if path.hasPrefix(home + "/") {
            path = String(path.dropFirst(home.count + 1))
            hasHomePrefix = true
        } else if path.hasPrefix("~/") {
            path = String(path.dropFirst(2))
            hasHomePrefix = true
        } else if path.hasPrefix("/Users/") {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 2 && parts[0] == "Users" {
                if parts.count == 2 { return "~" }
                path = parts.dropFirst(2).joined(separator: "/")
                hasHomePrefix = true
            }
        }

        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !segments.isEmpty else { return hasHomePrefix ? "~" : "/" }

        if segments.count <= 2 {
            let joined = segments.joined(separator: "/")
            return hasHomePrefix ? "~/\(joined)" : "/\(joined)"
        }
        let tail = segments.suffix(2).joined(separator: "/")
        return hasHomePrefix ? "~/…/\(tail)" : "…/\(tail)"
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
}
