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
import SwiftUI

/// Color palette for the Session Sidebar UI components, backed by `Tako.LivingTokens` (Spec 1b §0).
enum SessionSidebarPalette {
    static let bar = Tako.LivingTokens.body
    static let chrome = Tako.LivingTokens.chrome
    static let activeTab = Tako.LivingTokens.surfaceActive
    static let hoverTab = Tako.LivingTokens.surfaceHover
    static let hairline = Tako.LivingTokens.hairline
    static let badge = Tako.LivingTokens.badge
    static let ghostBorder = Tako.LivingTokens.ghostBorder
    static let activeText = Tako.LivingTokens.textActive
    static let inactiveText = Tako.LivingTokens.textInactive
    static let dim = Tako.LivingTokens.dim
    static let faint = Tako.LivingTokens.faint
    static let ember = Tako.LivingTokens.ember
    static let claw = Tako.LivingTokens.claw
    static let rust = Tako.LivingTokens.rust
    static let ok = Tako.LivingTokens.ok
    static let error = Tako.LivingTokens.error
    static let ink = Tako.LivingTokens.ink
    static let progressGradientStart = Tako.LivingTokens.rust
    static let progressGradientEnd = Tako.LivingTokens.ember
}

extension SessionSidebarItem {
    /// Unified `Tako.SurfaceState` for this sidebar row per Spec 1b (§1).
    var surfaceState: Tako.SurfaceState {
        let frac: Double? = {
            guard progressState != .none else { return nil }
            if let progress { return min(1.0, max(0.0, progress)) }
            return progressState == .indeterminate ? 0.35 : nil
        }()
        let state = status.surfaceState(progressState: progressState, progressFraction: frac)
        if state == .idle, needsAttention {
            return .waiting
        }
        return state
    }

    /// Compact pane tag text for Level 2 rows (§5.6: `"1"`, `"2"`, `"3"` without `"pane"` or `"#"` prefix).
    var compactPaneTag: String? {
        guard let raw = label?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return isChild ? "\(index + 1)" : nil
        }
        var cleaned = raw
        if cleaned.lowercased().hasPrefix("pane ") {
            cleaned = String(cleaned.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        if cleaned.hasPrefix("#") {
            cleaned = String(cleaned.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return cleaned.isEmpty ? raw : cleaned
    }

    /// Meta text shown on the right of Line 1: `"NN%"` when progress is active, otherwise `elapsed`.
    var metaDisplayText: String? {
        if case .progress(let p) = surfaceState {
            return "\(Int((p * 100).rounded()))%"
        }
        if let elapsed, !elapsed.isEmpty {
            return elapsed
        }
        if isChild, let port = listeningPorts?.first {
            return ":\(port)"
        }
        return nil
    }
}
