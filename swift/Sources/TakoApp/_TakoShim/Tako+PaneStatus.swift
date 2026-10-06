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
