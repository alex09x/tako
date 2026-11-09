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
import CoreGraphics
import Foundation

/// Presentation state of an internal terminal pane on a session's floating canvas.
enum FloatingPaneMode: String, Codable, Equatable, Sendable {
    case normal
    case maximized
    case minimized
}

/// Last visible presentation mode remembered across minimize/restore cycles.
enum FloatingPaneVisibleMode: String, Codable, Equatable, Sendable {
    case normal
    case maximized
}

/// Persistent geometry and stacking state for a single internal terminal pane.
/// Note: JSON property names deliberately avoid `"view"` so `LayoutJournal.shape`
/// and `LayoutJournal.IdentityAccumulator` continue counting leaves strictly from `surfaceTree`.
struct FloatingPaneState: Codable, Equatable, Sendable {
    let surfaceId: UUID
    var mode: FloatingPaneMode
    var restoreMode: FloatingPaneVisibleMode
    var rect: CGRect
    var zOrder: Int

    init(
        surfaceId: UUID,
        mode: FloatingPaneMode,
        restoreMode: FloatingPaneVisibleMode? = nil,
        rect: CGRect,
        zOrder: Int
    ) {
        self.surfaceId = surfaceId
        self.mode = mode
        self.restoreMode = restoreMode ?? (mode == .maximized ? .maximized : .normal)
        self.rect = rect
        self.zOrder = zOrder
    }

    private enum CodingKeys: String, CodingKey {
        case surfaceId
        case mode
        case restoreMode
        case rect
        case zOrder
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.surfaceId = try container.decode(UUID.self, forKey: .surfaceId)
        let decodedMode = try container.decode(FloatingPaneMode.self, forKey: .mode)
        self.mode = decodedMode
        self.restoreMode = try container.decodeIfPresent(FloatingPaneVisibleMode.self, forKey: .restoreMode)
            ?? (decodedMode == .maximized ? .maximized : .normal)
        self.rect = try container.decode(CGRect.self, forKey: .rect)
        self.zOrder = try container.decode(Int.self, forKey: .zOrder)
    }
}

/// Serializable per-session floating canvas state stored alongside `SplitTree` in `TerminalRestorableState`.
struct FloatingCanvasSnapshot: Codable, Equatable, Sendable {
    var version: Int = 1
    var panes: [FloatingPaneState]
    /// Panes presented in the split grid. `nil` in saved state written before the
    /// grid existed, where every `.normal` pane was free floating.
    var tiled: [UUID]?

    init(version: Int = 1, panes: [FloatingPaneState] = [], tiled: [UUID]? = nil) {
        self.version = version
        self.panes = panes
        self.tiled = tiled
    }
}

/// Interactive resize handles around a `.normal` floating pane.
enum FloatingPaneResizeEdge: String, CaseIterable, Sendable {
    case top
    case bottom
    case leading
    case trailing
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    func applying(delta: CGSize, to startRect: CGRect, within workArea: CGRect) -> CGRect {
        let minW = min(FloatingPaneGeometry.minSize.width, workArea.width)
        let minH = min(FloatingPaneGeometry.minSize.height, workArea.height)

        var minX = startRect.minX
        var maxX = startRect.maxX
        var minY = startRect.minY
        var maxY = startRect.maxY

        switch self {
        case .leading, .topLeading, .bottomLeading:
            minX = min(max(startRect.minX + delta.width, workArea.minX), maxX - minW)
        case .trailing, .topTrailing, .bottomTrailing:
            maxX = max(min(startRect.maxX + delta.width, workArea.maxX), minX + minW)
        case .top, .bottom:
            break
        }

        switch self {
        case .top, .topLeading, .topTrailing:
            minY = min(max(startRect.minY + delta.height, workArea.minY), maxY - minH)
        case .bottom, .bottomLeading, .bottomTrailing:
            maxY = max(min(startRect.maxY + delta.height, workArea.maxY), minY + minH)
        case .leading, .trailing:
            break
        }

        let candidate = CGRect(
            x: minX.rounded(),
            y: minY.rounded(),
            width: max(minW, (maxX - minX).rounded()),
            height: max(minH, (maxY - minY).rounded())
        )
        return FloatingPaneGeometry.clamp(candidate, to: workArea)
    }
}

/// Pure geometry calculations for floating panes and the bottom-right minimize shelf.
enum FloatingPaneGeometry {
    static let headerHeight: CGFloat = DesktopCanvasMetrics.paneHeaderHeight
    static let cornerRadius: CGFloat = 10
    static let shelfBandHeight: CGFloat = 44
    static let shelfCardHeight: CGFloat = 30
    static let defaultWidthRatio: CGFloat = 0.55
    static let defaultHeightRatio: CGFloat = 0.60
    static let cascadeStep: CGFloat = 24
    static let minSize = CGSize(width: 260, height: 150)
    static let minValidCanvasDimension: CGFloat = 64
    static let fallbackCanvasSize = CGSize(width: 960, height: 640)

    static func isValidCanvasSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite
            && size.width >= minValidCanvasDimension
            && size.height >= minValidCanvasDimension
    }

    static func sanitizedCanvasSize(_ size: CGSize) -> CGSize {
        isValidCanvasSize(size) ? size : fallbackCanvasSize
    }

    /// Available pane work area inside the right-hand canvas.
    /// Reserves a fixed bottom band only while the minimize shelf has cards,
    /// preventing the shelf from occluding the bottom rows of maximized or normal panes.
    static func workArea(in canvasSize: CGSize, hasMinimizedPanes: Bool) -> CGRect {
        let safe = sanitizedCanvasSize(canvasSize)
        guard hasMinimizedPanes else {
            return CGRect(origin: .zero, size: safe)
        }
        let minWorkHeight = min(minSize.height, safe.height)
        let reservedHeight = max(minWorkHeight, safe.height - shelfBandHeight)
        return CGRect(x: 0, y: 0, width: safe.width, height: reservedHeight)
    }

    static func defaultNormalRect(in workArea: CGRect, cascadeIndex: Int = 0) -> CGRect {
        let minW = min(minSize.width, workArea.width)
        let minH = min(minSize.height, workArea.height)
        let width = max(minW, (workArea.width * defaultWidthRatio).rounded())
        let height = max(minH, (workArea.height * defaultHeightRatio).rounded())
        let step = CGFloat(cascadeIndex % 6) * cascadeStep
        let baseX = workArea.minX + ((workArea.width - width) * 0.5).rounded() + step
        let baseY = workArea.minY + ((workArea.height - height) * 0.5).rounded() + step
        return clamp(CGRect(x: baseX, y: baseY, width: width, height: height), to: workArea)
    }

    static func cascadedRect(from anchorRect: CGRect, in workArea: CGRect, step: CGFloat = cascadeStep) -> CGRect {
        let candidate = CGRect(
            x: anchorRect.minX + step,
            y: anchorRect.minY + step,
            width: anchorRect.width,
            height: anchorRect.height
        )
        let clamped = clamp(candidate, to: workArea)
        if clamped.origin == anchorRect.origin,
           (workArea.width > clamped.width + step || workArea.height > clamped.height + step) {
            let wrapped = CGRect(
                x: workArea.minX + step,
                y: workArea.minY + step,
                width: clamped.width,
                height: clamped.height
            )
            return clamp(wrapped, to: workArea)
        }
        return clamped
    }

    static func clamp(_ rect: CGRect, to workArea: CGRect) -> CGRect {
        guard workArea.width > 0, workArea.height > 0 else { return rect }
        let minW = min(minSize.width, workArea.width)
        let minH = min(minSize.height, workArea.height)
        let rawW = rect.width.isFinite && rect.width > 0 ? rect.width : minW
        let rawH = rect.height.isFinite && rect.height > 0 ? rect.height : minH
        let width = min(max(rawW, minW), workArea.width)
        let height = min(max(rawH, minH), workArea.height)
        let rawX = rect.origin.x.isFinite ? rect.origin.x : workArea.minX
        let rawY = rect.origin.y.isFinite ? rect.origin.y : workArea.minY
        let x = min(max(rawX, workArea.minX), max(workArea.minX, workArea.maxX - width))
        let y = min(max(rawY, workArea.minY), max(workArea.minY, workArea.maxY - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func presentedFrame(
        for pane: FloatingPaneState,
        in canvasSize: CGSize,
        hasMinimizedPanes: Bool
    ) -> CGRect {
        let area = workArea(in: canvasSize, hasMinimizedPanes: hasMinimizedPanes)
        switch pane.mode {
        case .maximized:
            return area
        case .normal:
            return clamp(pane.rect, to: area)
        case .minimized:
            return .zero
        }
    }

    static func bodySize(for presentedFrame: CGRect) -> CGSize {
        CGSize(
            width: max(1, presentedFrame.width),
            height: max(1, presentedFrame.height - headerHeight)
        )
    }

    /// Human-readable `PaneStatus` label matching sidebar status semantics for VoiceOver and AX UI tests.
    static func accessibilityStatusValue(for status: Tako.PaneStatus) -> String {
        switch status {
        case .working, .running: return "Working"
        case .done: return "Done"
        case .needsApproval: return "Needs approval"
        case .waitingForInput: return "Needs input"
        case .error: return "Failed"
        case .disconnected: return "Offline"
        case .idle, .unknown: return "Idle"
        }
    }

    @MainActor
    static func statusNSColor(for status: Tako.PaneStatus, surface: Tako.SurfaceView? = nil) -> NSColor {
        // `status-show = false`: the dot stays calm; the status is still tracked.
        let shown = LivingAnimationState.shared.statusShown ? status : .idle
        return Tako.tabStatusColor(for: shown.dotKey, surface: surface)
    }

    /// Sanitizes decoded preferred `.normal` rects without clamping them to transient work areas
    /// (such as temporary shelf height reservation or temporary window shrinkage).
    static func sanitizePreferredRect(_ rect: CGRect, fallback: CGRect) -> CGRect {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite,
              rect.size.width > 0, rect.size.height > 0
        else {
            return fallback
        }
        return CGRect(
            x: rect.origin.x.rounded(),
            y: rect.origin.y.rounded(),
            width: max(minSize.width, rect.size.width.rounded()),
            height: max(minSize.height, rect.size.height.rounded())
        )
    }

    @MainActor
    static func shortTitle(for surfaceView: Tako.SurfaceView) -> String {
        if let own = surfaceView.paneTitleOverride { return own }
        let trimmed = surfaceView.titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let raw = surfaceView.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { return raw }
        if let pwd = surfaceView.pwd, !pwd.isEmpty {
            return Tako.formatCompactDirectory(pwd)
        }
        return "Terminal"
    }

    /// Converts a legacy multi-pane `SplitTree` into initial `.normal` floating rectangles.
    static func rectsFromSplitTree<V: Identifiable>(
        _ node: SplitTree<V>.Node,
        in workArea: CGRect,
        gap: CGFloat = 10
    ) -> [V.ID: CGRect] {
        let insetArea = workArea.insetBy(
            dx: min(gap, max(0, (workArea.width - minSize.width) * 0.25)),
            dy: min(gap, max(0, (workArea.height - minSize.height) * 0.25))
        )
        var out: [V.ID: CGRect] = [:]
        collectSplitRects(node: node, bounds: insetArea, gap: gap, into: &out)
        return out.mapValues { clamp($0, to: workArea) }
    }

    private static func collectSplitRects<V: Identifiable>(
        node: SplitTree<V>.Node,
        bounds: CGRect,
        gap: CGFloat,
        into out: inout [V.ID: CGRect]
    ) {
        switch node {
        case .leaf(let view):
            out[view.id] = bounds.integral
        case .split(let split):
            let ratio = CGFloat(min(max(split.ratio, 0.15), 0.85))
            switch split.direction {
            case .horizontal:
                let usable = max(2, bounds.width - gap)
                let leftW = (usable * ratio).rounded()
                let rightW = max(1, usable - leftW)
                let leftRect = CGRect(x: bounds.minX, y: bounds.minY, width: leftW, height: bounds.height)
                let rightRect = CGRect(x: bounds.minX + leftW + gap, y: bounds.minY, width: rightW, height: bounds.height)
                collectSplitRects(node: split.left, bounds: leftRect, gap: gap, into: &out)
                collectSplitRects(node: split.right, bounds: rightRect, gap: gap, into: &out)
            case .vertical:
                let usable = max(2, bounds.height - gap)
                let topH = (usable * ratio).rounded()
                let bottomH = max(1, usable - topH)
                let topRect = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: topH)
                let bottomRect = CGRect(x: bounds.minX, y: bounds.minY + topH + gap, width: bounds.width, height: bottomH)
                collectSplitRects(node: split.left, bounds: topRect, gap: gap, into: &out)
                collectSplitRects(node: split.right, bounds: bottomRect, gap: gap, into: &out)
            }
        }
    }
}
