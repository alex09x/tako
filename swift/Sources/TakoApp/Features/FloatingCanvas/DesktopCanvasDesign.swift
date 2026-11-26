/*
 * tako — Frozen desktop reference metrics and per-pane canvas presentation modes
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import CoreGraphics
import Foundation

/// Metrics taken from `docs/design/desktop-reference` (sidebar, canvas, shelf).
/// Application-content only: the terminal SDK renderer padding stays 0.
enum DesktopCanvasMetrics {
    static let sidebarDefaultWidth: CGFloat = 248
    static let sessionRowHeight: CGFloat = 46
    static let childRowHeight: CGFloat = 23
    static let paneHeaderHeight: CGFloat = 28
    static let controlSize: CGFloat = 22
    static let headerControlInset = (paneHeaderHeight - controlSize) / 2
    static let controlRadius: CGFloat = 5
    static let floatingSymbolSize: CGFloat = 16
    static let paneRadius: CGFloat = 10
    static let paneGap: CGFloat = 8
    static let shelfHeight: CGFloat = 30
    /// Minimum hit target for icon-only pane controls.
    static let minimumHitTarget: CGFloat = 22

    /// An explicitly saved width always wins over the reference default.
    static func sidebarWidth(saved: CGFloat?) -> CGFloat {
        guard let saved, saved.isFinite, saved > 0 else { return sidebarDefaultWidth }
        return saved
    }
}

/// Per-pane presentation on the session canvas. The PTY and Surface are never
/// touched by a mode change; only the presented frame changes.
enum CanvasPaneMode: String, Codable, Equatable, Sendable {
    case tiled
    case floating
    case maximized
    case minimized

    /// Whether the pane takes a slot in the tile allocation.
    var participatesInTiling: Bool { self == .tiled }
}

/// Grid-or-free mode returned to after maximize/minimize.
enum CanvasPaneRestoreMode: String, Codable, Equatable, Sendable {
    case tiled
    case floating
}

struct CanvasPanePresentation: Codable, Equatable, Sendable {
    let surfaceId: UUID
    var mode: CanvasPaneMode
    var restoreMode: CanvasPaneRestoreMode
    /// True when a minimized pane was maximized before minimizing.
    var restoresMaximized: Bool
    /// Preferred free-floating rectangle, retained while tiled/maximized/minimized.
    var preferredRect: CGRect?
    var zOrder: Int

    init(surfaceId: UUID, mode: CanvasPaneMode = .tiled,
         restoreMode: CanvasPaneRestoreMode = .tiled, restoresMaximized: Bool = false,
         preferredRect: CGRect? = nil, zOrder: Int = 0) {
        self.surfaceId = surfaceId
        self.mode = mode
        self.restoreMode = restoreMode
        self.restoresMaximized = restoresMaximized
        self.preferredRect = preferredRect
        self.zOrder = zOrder
    }

    /// Detach from the grid. Reuses the remembered rectangle when one exists.
    mutating func detach(defaultRect: CGRect) {
        if preferredRect == nil { preferredRect = defaultRect }
        mode = .floating
        restoreMode = .floating
    }

    /// Return to the grid; the floating rectangle is remembered for the next detach.
    mutating func returnToGrid() {
        mode = .tiled
        restoreMode = .tiled
    }

    mutating func maximize() {
        rememberVisibleMode()
        mode = .maximized
    }

    mutating func minimize() {
        guard mode != .minimized else { return }
        restoresMaximized = mode == .maximized
        rememberVisibleMode()
        mode = .minimized
    }

    /// Reverse of maximize/minimize (same control position, reverse action).
    mutating func restore() {
        if mode == .minimized && restoresMaximized {
            mode = .maximized
        } else {
            mode = restoreMode == .tiled ? .tiled : .floating
        }
        restoresMaximized = false
    }

    private mutating func rememberVisibleMode() {
        if mode == .tiled { restoreMode = .tiled } else if mode == .floating { restoreMode = .floating }
    }
}

/// Version 2 snapshot. Version 1 (`FloatingCanvasSnapshot`) panes were all free
/// floating, so normal → floating, maximized → maximized (restore floating),
/// minimized → minimized keeping whether it was maximized.
struct CanvasPresentationSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 2
    var version: Int = currentVersion
    var panes: [CanvasPanePresentation]

    init(panes: [CanvasPanePresentation] = []) {
        self.panes = panes
    }

    init(migrating legacy: FloatingCanvasSnapshot) {
        panes = legacy.panes.map { old in
            let mode: CanvasPaneMode
            switch old.mode {
            case .normal: mode = .floating
            case .maximized: mode = .maximized
            case .minimized: mode = .minimized
            }
            return CanvasPanePresentation(
                surfaceId: old.surfaceId, mode: mode, restoreMode: .floating,
                restoresMaximized: old.mode == .minimized && old.restoreMode == .maximized,
                preferredRect: old.rect, zOrder: old.zOrder)
        }
    }

    /// Decodes either version without failing on old saved state.
    static func decode(_ data: Data) throws -> CanvasPresentationSnapshot {
        struct Probe: Decodable { let version: Int? }
        let version = (try? JSONDecoder().decode(Probe.self, from: data))?.version ?? 1
        if version >= currentVersion { return try JSONDecoder().decode(Self.self, from: data) }
        return Self(migrating: try JSONDecoder().decode(FloatingCanvasSnapshot.self, from: data))
    }

    func pane(_ id: UUID) -> CanvasPanePresentation? { panes.first { $0.surfaceId == id } }
}
