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

/// Seamless 28pt pane header with drag-only movement, double-click maximize/restore,
/// live status indicator, and 22pt Grid-Float / Minimize / Maximize-Restore / Close controls.
/// The mode icon only switches grid ⇄ free floating; maximize stays a separate action.
struct FloatingPaneHeaderView: View {
    static let controlSize: CGFloat = DesktopCanvasMetrics.controlSize
    static let controlsTrailingInset: CGFloat = 14

    @ObservedObject var surfaceView: Tako.SurfaceView
    @ObservedObject var crab: Tako.CrabTracker
    let pane: FloatingPaneState
    var isTiled: Bool = false
    let presentedFrame: CGRect
    let isFocused: Bool
    let canvasSize: CGSize
    let canMoveToNewWindow: Bool
    var onDragStateChange: (Bool) -> Void = { _ in }
    let onActivate: () -> Void
    let onDragMove: (_ rect: CGRect) -> Void
    let onDetachMaximized: (_ pointerXInCanvas: CGFloat, _ pointerYInHeader: CGFloat) -> CGRect?
    let onDragCommit: () -> Void
    let onMinimize: () -> Void
    let onToggleMaximize: () -> Void
    var onToggleFloating: () -> Void = {}
    let onMoveToNewWindow: () -> Void
    let onClose: () -> Void

    @State private var isStripHovered = false
    @State private var hoveredControlId: String?

    private typealias T = Tako.LivingTokens

    private var uuidKey: String {
        surfaceView.id.uuidString.lowercased()
    }

    private var displayTitle: String {
        let trimmed = surfaceView.titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let rawTitle = surfaceView.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawTitle.isEmpty { return rawTitle }
        if let pwd = surfaceView.pwd, !pwd.isEmpty {
            return Tako.formatCompactDirectory(pwd)
        }
        return "Terminal"
    }

    private var statusColor: Color {
        Color(nsColor: FloatingPaneGeometry.statusNSColor(for: crab.paneStatus, surface: surfaceView))
    }

    private var statusValue: String {
        FloatingPaneGeometry.accessibilityStatusValue(for: crab.paneStatus)
    }

    private var controlsProminent: Bool {
        isFocused || isStripHovered || hoveredControlId != nil
    }

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                FloatingPaneHeaderDragStrip(
                    accessibilityIdentifier: "FloatingPaneHeader-\(uuidKey)",
                    accessibilityLabel: "\(displayTitle), \(statusValue)",
                    accessibilityValue: statusValue,
                    paneMode: pane.mode,
                    paneRect: presentedFrame,
                    canvasSize: canvasSize,
                    canMoveToNewWindow: canMoveToNewWindow,
                    onHoverChange: { isStripHovered = $0 },
                    onDragStateChange: onDragStateChange,
                    onActivate: onActivate,
                    onDragMove: onDragMove,
                    onDetachMaximized: onDetachMaximized,
                    onDragCommit: onDragCommit,
                    onDoubleClick: onToggleMaximize,
                    onMoveToNewWindow: onMoveToNewWindow
                )

                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)

                    Text(displayTitle)
                        .font(Font(T.monoFont(size: 11.5, weight: isFocused ? .medium : .regular)))
                        .foregroundColor(Color(nsColor: isFocused ? T.textActive : T.textInactive))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let note = crab.statusText, !note.isEmpty {
                        Text(note)
                            .font(Font(T.monoFont(size: 10, weight: .regular)))
                            .foregroundColor(Color(nsColor: T.dim))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 14)
                .padding(.trailing, 4)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 2) {
                FloatingHeaderIconButton(
                    symbolName: isTiled ? "macwindow.on.rectangle" : "square.grid.2x2",
                    identifier: "FloatingPaneFloat-\(uuidKey)",
                    label: isTiled ? "Float Pane" : "Return Pane to Grid",
                    value: isTiled ? "tiled" : "floating",
                    helpText: isTiled ? "Float Pane" : "Return Pane to Grid",
                    isProminent: controlsProminent,
                    onHoverStateChange: { updateControlHover(id: "float", hovering: $0) },
                    action: onToggleFloating
                )

                FloatingHeaderIconButton(
                    symbolName: "minus",
                    identifier: "FloatingPaneMinimize-\(uuidKey)",
                    label: "Minimize Pane",
                    value: pane.mode.rawValue,
                    helpText: "Minimize Pane",
                    isProminent: controlsProminent,
                    onHoverStateChange: { updateControlHover(id: "min", hovering: $0) },
                    action: onMinimize
                )

                FloatingHeaderIconButton(
                    symbolName: pane.mode == .maximized
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    identifier: "FloatingPaneMaximize-\(uuidKey)",
                    label: pane.mode == .maximized ? "Restore Pane" : "Maximize Pane",
                    value: pane.mode.rawValue,
                    helpText: pane.mode == .maximized ? "Restore Pane" : "Maximize Pane",
                    isProminent: controlsProminent,
                    onHoverStateChange: { updateControlHover(id: "max", hovering: $0) },
                    action: onToggleMaximize
                )

                FloatingHeaderIconButton(
                    symbolName: "xmark",
                    identifier: "FloatingPaneClose-\(uuidKey)",
                    label: "Close Pane",
                    value: nil,
                    helpText: "Close Pane (⌘W)",
                    isProminent: controlsProminent,
                    isClose: true,
                    onHoverStateChange: { updateControlHover(id: "close", hovering: $0) },
                    action: onClose
                )
            }
            .padding(.trailing, Self.controlsTrailingInset)
        }
        .frame(height: FloatingPaneGeometry.headerHeight)
    }

    private func updateControlHover(id: String, hovering: Bool) {
        if hovering {
            hoveredControlId = id
        } else if hoveredControlId == id {
            hoveredControlId = nil
        }
    }
}

private struct FloatingHeaderIconButton: View {
    let symbolName: String
    let identifier: String
    let label: String
    let value: String?
    let helpText: String
    let isProminent: Bool
    var isClose: Bool = false
    let onHoverStateChange: (Bool) -> Void
    let action: () -> Void

    @State private var hovering = false
    private typealias T = Tako.LivingTokens

    var body: some View {
        let size = FloatingPaneHeaderView.controlSize
        ZStack {
            Image(systemName: symbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(foregroundColor)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hoverBackground)
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            FloatingActionButtonOverlay(
                identifier: identifier,
                label: label,
                value: value ?? "",
                helpText: helpText,
                onHoverChange: { isHovering in
                    hovering = isHovering
                    onHoverStateChange(isHovering)
                },
                action: action
            )
        }
        .frame(width: size, height: size)
    }

    private var foregroundColor: Color {
        if hovering {
            return Color(nsColor: isClose ? T.error : T.textActive)
        }
        if isProminent {
            return Color(nsColor: T.textInactive)
        }
        return Color(nsColor: T.dim).opacity(0.55)
    }

    private var hoverBackground: Color {
        guard hovering else { return .clear }
        return isClose
            ? Color(nsColor: T.error).opacity(0.16)
            : Color(nsColor: T.surfaceHover)
    }
}
