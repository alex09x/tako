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
    let workspaceName: String
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
        workspaceName: String = "",
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
        self.workspaceName = workspaceName
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

    /// Formats path into a compact display string per spec ($HOME -> ~, max 2 segments).
    static func formatDirectory(_ path: String?) -> String {
        Tako.formatCompactDirectory(path)
    }

    /// Status badge color sourced from `Tako.tabStatusColor(for: status.dotKey)` matching Session Sidebar.
    @MainActor
    var statusColor: NSColor {
        status.sidebarDotColor
    }

    /// UI Kit status chip accent color (distinguishes waiting states with Tomorrow Yellow `#F0C674`).
    @MainActor
    var chipColor: NSColor {
        status.uiChipColor
    }

    /// Unified UI Kit status chip label (`Approval`, `Needs input`, `Working`, `Failed`, `Done`, `Offline`, `Idle`).
    var chipLabel: String {
        status.overviewChipLabel
    }

    /// Unified `Tako.SurfaceState` for this overview card per Spec 1b (§1).
    var surfaceState: Tako.SurfaceState {
        let frac: Double? = {
            guard progressState != .none else { return nil }
            if let progressValue { return min(1.0, max(0.0, Double(progressValue) / 100.0)) }
            return progressState == .indeterminate ? 0.35 : nil
        }()
        return status.surfaceState(progressState: progressState, progressFraction: frac, crabState: crabState)
    }

    /// Meta text shown on the right of Row 1: `"NN%"` when progress is active, otherwise `elapsed`.
    var metaDisplayText: String? {
        if case .progress(let p) = surfaceState {
            return "\(Int((p * 100).rounded()))%"
        }
        return elapsed
    }

    /// Provenance string `"Workspace › N"` for the card footer and modal footer (§6).
    var provenanceLabel: String {
        let ws = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = ws.isEmpty ? "Workspace" : ws
        return "\(prefix) › \(tabIndex + 1)"
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

    /// Checks whether this pane matches a search query by title, workspace, directory, or status (B6).
    func matches(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        // Match title
        if title.localizedCaseInsensitiveContains(trimmed) { return true }

        // Match workspace / window / tab title
        if !workspaceName.isEmpty && workspaceName.localizedCaseInsensitiveContains(trimmed) { return true }
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

        // Match status (raw value, human-readable label, chip label, or custom status text)
        if status.rawValue.localizedCaseInsensitiveContains(trimmed) { return true }
        if statusLabel.localizedCaseInsensitiveContains(trimmed) { return true }
        if chipLabel.localizedCaseInsensitiveContains(trimmed) { return true }
        if let statusText, statusText.localizedCaseInsensitiveContains(trimmed) { return true }

        // Match crab state fallback (succeeded -> done, failed -> error, etc.)
        if trimmed.localizedCaseInsensitiveContains("success") && status == .done { return true }
        if trimmed.localizedCaseInsensitiveContains("fail") && status == .error { return true }

        return false
    }
}
