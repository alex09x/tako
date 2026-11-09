/*
 * tako — Five visible setup stages over the persisted seven-step progress
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

/// The visible stages of the reference design. Saved progress keeps the
/// seven-step `SetupStep` document so older resumes map onto a stage safely.
enum SetupStage: Int, CaseIterable, Identifiable {
    case welcome, appearance, agents, access, ready
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .appearance: "Appearance"
        case .agents: "Agents"
        case .access: "Access"
        case .ready: "Ready"
        }
    }

    /// Saved steps that belong to this stage, in display order.
    var steps: [SetupStep] {
        switch self {
        case .welcome: [.welcome]
        case .appearance: [.appearance]
        case .agents: [.agents, .commandLine]
        case .access: [.notifications, .permissions]
        case .ready: [.ready]
        }
    }

    /// The step persisted when this stage is selected.
    var canonicalStep: SetupStep { steps[0] }

    init(_ step: SetupStep) {
        switch step {
        case .welcome: self = .welcome
        case .appearance: self = .appearance
        case .commandLine, .agents: self = .agents
        case .permissions, .notifications: self = .access
        case .ready: self = .ready
        }
    }

    var next: SetupStage? { SetupStage(rawValue: rawValue + 1) }
    var previous: SetupStage? { SetupStage(rawValue: rawValue - 1) }
}

/// Sheet size derived from the host window so setup stays usable in small windows.
enum SetupSheetGeometry {
    static let preferred = NSSize(width: 680, height: 600)
    static let minimum = NSSize(width: 460, height: 380)
    static let margin: CGFloat = 24

    static func size(forHost host: NSSize) -> NSSize {
        NSSize(width: max(minimum.width, min(preferred.width, host.width - margin * 2)),
               height: max(minimum.height, min(preferred.height, host.height - margin * 2)))
    }

    /// Horizontally centered over the host, top-aligned below its title bar like a sheet.
    static func frame(forHost host: NSRect, titlebarHeight: CGFloat = 28) -> NSRect {
        let size = size(forHost: host.size)
        return NSRect(x: (host.midX - size.width / 2).rounded(),
                      y: host.maxY - titlebarHeight - size.height,
                      width: size.width, height: size.height)
    }

    /// Compact layout drops the side preview and tightens padding.
    static func isCompact(_ size: NSSize) -> Bool { size.width < preferred.width - 1 }
}

@MainActor
extension SetupModel {
    var stage: SetupStage { SetupStage(step) }

    func selectStage(_ stage: SetupStage) { select(stage.canonicalStep) }

    /// Moves forward one visible stage. On Ready this completes and closes.
    func nextStage(skipping: Bool = false) {
        guard !isBusy else { return }
        if skipping { markSkipped(stage.steps) }
        if let next = stage.next { selectStage(next) } else { finishSetup() }
    }

    func backStage() {
        if let previous = stage.previous { selectStage(previous) }
    }

    func finishSetup() {
        guard !isBusy else { return }
        if step != .ready { select(.ready) }
        next()
    }
}
