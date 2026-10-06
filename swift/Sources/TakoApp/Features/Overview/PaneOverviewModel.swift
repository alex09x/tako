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
import Foundation
import SwiftUI
import TakoKit

/// Sourced information for a single terminal pane card in the full-window Pane Overview (B6).
///
/// Every field is sourced directly from live Tako runtime state:
/// - `id`: The unique surface UUID (`Tako.SurfaceView.id`).
/// - `windowTitle`: The title of the host window.
/// - `tabTitle`: The title of the tab containing this surface.
/// - `tabIndex`: 0-indexed position within the tab group.
/// - `title`: The pane title (from OSC 2 / shell / directory).
/// - `pwd`: The working directory reported by shell integration OSC 7.
/// - `directoryDisplay`: Formatted compact directory string (e.g. `~/Projects/tako`).
/// - `status`: Live pane status (`Tako.PaneStatus` from Track B1).
/// - `crabState`: Live crab indicator state (`Tako.CrabState`).
/// - `statusText`: Custom status text reported via OSC 1337 / OSC 9;5.
/// - `progressState`: Live progress bar state (`TakoTerminalNSView.ProgressState` from Track B2).
/// - `progressValue`: Progress percentage 0...100.
/// - `elapsed`: Formatted duration of running command (`CrabTracker.elapsedLabel`).
/// - `isFocused`: Whether this pane is the focused split in its window.
/// - `isKeyWindow`: Whether this pane's window is currently the key window.
/// - `thumbnailLines`: Recent visible lines extracted from the active grid buffer.
struct PaneOverviewItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let windowTitle: String
    let tabTitle: String
    let tabIndex: Int
    let title: String
    let pwd: String?
    let directoryDisplay: String
    let status: Tako.PaneStatus
    let crabState: Tako.CrabState
    let statusText: String?
    let progressState: TakoTerminalNSView.ProgressState
    let progressValue: Int?
    let elapsed: String?
    let isFocused: Bool
    let isKeyWindow: Bool
    let thumbnailLines: [String]

    init(
        id: UUID,
        windowTitle: String = "",
        tabTitle: String = "",
        tabIndex: Int = 0,
        title: String,
        pwd: String? = nil,
        directoryDisplay: String? = nil,
        status: Tako.PaneStatus = .idle,
        crabState: Tako.CrabState = .idle,
        statusText: String? = nil,
        progressState: TakoTerminalNSView.ProgressState = .none,
        progressValue: Int? = nil,
        elapsed: String? = nil,
        isFocused: Bool = false,
        isKeyWindow: Bool = false,
        thumbnailLines: [String] = []
    ) {
        self.id = id
        self.windowTitle = windowTitle
        self.tabTitle = tabTitle
        self.tabIndex = tabIndex
        self.title = title
        self.pwd = pwd
        self.directoryDisplay = directoryDisplay ?? Self.formatDirectory(pwd)
        self.status = status
        self.crabState = crabState
        self.statusText = statusText
        self.progressState = progressState
        self.progressValue = progressValue
        self.elapsed = elapsed
        self.isFocused = isFocused
        self.isKeyWindow = isKeyWindow
        self.thumbnailLines = thumbnailLines
    }

    /// Formats path into a compact display string (~/Projects/tako).
    static func formatDirectory(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "~" }
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Status badge and border accent color based on Tako Brand palette (B1/B6).
    var statusColor: NSColor {
        switch status {
        case .error:
            return Tako.Brand.error
        case .working, .running:
            return NSColor(srgbRed: 0x38 / 255, green: 0x90 / 255, blue: 0xE6 / 255, alpha: 1) // Active blue
        case .needsApproval, .waitingForInput:
            return Tako.Brand.ember
        case .done:
            return Tako.Brand.ok
        case .disconnected:
            return Tako.Brand.dim
        case .idle, .unknown:
            return NSColor(srgbRed: 0x6E / 255, green: 0x68 / 255, blue: 0x62 / 255, alpha: 1)
        }
    }

    /// Human-readable status label.
    var statusLabel: String {
        switch status {
        case .error: return "Error"
        case .running: return "Running"
        case .working: return "Working"
        case .needsApproval: return "Needs Approval"
        case .waitingForInput: return "Waiting for Input"
        case .done: return "Done"
        case .disconnected: return "Disconnected"
        case .idle: return "Idle"
        case .unknown: return "Unknown"
        }
    }

    /// Checks whether this pane matches a search query by title, directory, or status (B6).
    func matches(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        // Match title
        if title.localizedCaseInsensitiveContains(trimmed) { return true }

        // Match window / tab title
        if windowTitle.localizedCaseInsensitiveContains(trimmed) { return true }
        if tabTitle.localizedCaseInsensitiveContains(trimmed) { return true }

        // Match working directory
        if let pwd, pwd.localizedCaseInsensitiveContains(trimmed) { return true }
        if directoryDisplay.localizedCaseInsensitiveContains(trimmed) { return true }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded != trimmed, let pwd, pwd.localizedCaseInsensitiveContains(expanded) { return true }
        if trimmed.hasPrefix("~/") {
            let relative = String(trimmed.dropFirst(2))
            if let pwd, pwd.localizedCaseInsensitiveContains(relative) { return true }
        }

        // Match status (raw value, human-readable label, or custom status text)
        if status.rawValue.localizedCaseInsensitiveContains(trimmed) { return true }
        if statusLabel.localizedCaseInsensitiveContains(trimmed) { return true }
        if let statusText, statusText.localizedCaseInsensitiveContains(trimmed) { return true }

        // Match crab state fallback (succeeded -> done, failed -> error, etc.)
        if trimmed.localizedCaseInsensitiveContains("success") && status == .done { return true }
        if trimmed.localizedCaseInsensitiveContains("fail") && status == .error { return true }

        return false
    }
}
