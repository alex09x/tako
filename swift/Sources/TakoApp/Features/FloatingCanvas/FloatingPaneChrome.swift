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
    static let ringSize: CGFloat = 14
    /// The status ring sits as far from the header's left edge as from its top:
    /// the corner reads as a square inset.
    static let ringLeadingInset: CGFloat = (FloatingPaneGeometry.headerHeight - ringSize) / 2
    /// Keeps the last control clear of the right-edge and corner resize handles.
    static let controlsTrailingInset: CGFloat = 14

    @ObservedObject var surfaceView: Tako.SurfaceView
    @ObservedObject var crab: Tako.CrabTracker
    @ObservedObject private var animationState = LivingAnimationState.shared
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
    /// A pane's own name redraws its header.
    @ObservedObject private var paneTitles = PaneTitleStore.shared

    private typealias T = Tako.LivingTokens

    /// Title and controls in the terminal's own colours: the header is drawn in its background.
    private var palette: CardHeaderPalette { .of(surfaceView) }

    private var uuidKey: String {
        surfaceView.id.uuidString.lowercased()
    }

    private var displayTitle: String {
        let _ = paneTitles.titles
        if let own = surfaceView.paneTitleOverride { return own }
        let trimmed = surfaceView.titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let rawTitle = surfaceView.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawTitle.isEmpty { return rawTitle }
        if let pwd = surfaceView.pwd, !pwd.isEmpty {
            return Tako.formatCompactDirectory(pwd)
        }
        return "Terminal"
    }

    /// The header's right-click actions; a split goes to this pane's own controller.
    var paneMenu: FloatingPaneMenu {
        FloatingPaneMenu(
            mode: pane.mode, isTiled: isTiled,
            split: { [weak surface = surfaceView] direction in
                guard let surface, let controller = surface.window?.windowController as? BaseTerminalController else { return }
                _ = controller.newSplit(at: surface, direction: direction)
            },
            toggleMaximize: onToggleMaximize, toggleFloating: onToggleFloating, minimize: onMinimize, close: onClose,
            rename: { [weak surface = surfaceView] in surface.map(FloatingPaneMenu.askRename) })
    }

    /// The pane's own status, as its sidebar row's ring shows it.
    private var headerState: Tako.SurfaceState {
        crab.paneStatus.surfaceState(crabState: crab.state, live: crab.live)
    }

    /// The working directory, unless the title already is it.
    private var directory: String? {
        guard let pwd = surfaceView.pwd, !pwd.isEmpty else { return nil }
        let compact = Tako.formatCompactDirectory(pwd)
        return compact == displayTitle ? nil : compact
    }

    private var statusValue: String {
        FloatingPaneGeometry.accessibilityStatusValue(for: crab.paneStatus)
    }

    private var controlsProminent: Bool {
        isStripHovered || hoveredControlId != nil
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
                    onMoveToNewWindow: onMoveToNewWindow,
                    appearanceMenuItem: { [weak surface = surfaceView] in surface?.appearanceMenuItem() },
                    paneMenuItems: { paneMenu.items() },
                    moveToTabMenuItem: { [weak surface = surfaceView] in surface.map(MovePaneToTab.menuItem) }
                )

                // Reference `.fw-hd` (header.css): 7 gap, the pill's 14 pt status
                // ring, title 12/500, directory 11. The ring's left inset equals
                // its top inset (owner, 2026-11-23) rather than the reference's 10.
                HStack(spacing: 7) {
                    SidebarStatusLayerView(state: headerState, ringCenter: nil, cornerRadius: 0,
                                           reduceMotion: animationState.reduceMotion,
                                           paused: animationState.isTimelinePaused, pulses: crab.live?.pulses ?? 0,
                                           ringOnly: Self.ringSize, palette: Tako.tabStatusPalette(surface: surfaceView))
                        .frame(width: Self.ringSize, height: Self.ringSize)

                    Text(displayTitle)
                        .font(Font(T.monoFont(size: 12, weight: .medium)))
                        .foregroundColor(Color(nsColor: isFocused ? palette.title : palette.secondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)

                    if let directory {
                        Text(directory)
                            .font(Font(T.monoFont(size: 11, weight: .regular)))
                            .foregroundColor(Color(nsColor: isFocused ? palette.secondary : palette.faint))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let note = crab.statusText, !note.isEmpty {
                        Text(note)
                            .font(Font(T.monoFont(size: 10, weight: .regular)))
                            .foregroundColor(Color(nsColor: palette.secondary))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, Self.ringLeadingInset)
                .padding(.trailing, 4)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 1) {
                // «Move to Tab ▸»: join another tab, or leave a split for a new one.
                FloatingHeaderIconButton(
                    symbolName: "rectangle.portrait.and.arrow.right",
                    identifier: "FloatingPaneMoveToTab-\(uuidKey)",
                    label: "Move to Tab",
                    value: nil,
                    helpText: "Move to Tab — join another tab, or take this terminal into a new one",
                    isProminent: controlsProminent,
                    palette: palette,
                    isHovered: hoveredControlId == "move",
                    onHoverStateChange: { updateControlHover(id: "move", hovering: $0) },
                    action: {},
                    menu: { [weak surface = surfaceView] in surface.map(MovePaneToTab.buttonMenu) }
                )

                // One compact system icon (reference m15226): pressed while floating.
                FloatingHeaderIconButton(
                    symbolName: "rectangle.on.rectangle",
                    identifier: "FloatingPaneFloat-\(uuidKey)",
                    label: FloatingPaneCopy.float(isTiled: isTiled),
                    value: isTiled ? "tiled" : "floating",
                    helpText: isTiled ? "Float Terminal — move freely above the grid" : "Return to the Session Grid",
                    isProminent: controlsProminent,
                    palette: palette,
                    isHovered: hoveredControlId == "float",
                    isPressed: !isTiled,
                    onHoverStateChange: { updateControlHover(id: "float", hovering: $0) },
                    action: onToggleFloating
                )

                FloatingHeaderIconButton(
                    symbolName: "minus",
                    identifier: "FloatingPaneMinimize-\(uuidKey)",
                    label: FloatingPaneCopy.minimize,
                    value: pane.mode.rawValue,
                    helpText: FloatingPaneCopy.minimize,
                    isProminent: controlsProminent,
                    palette: palette,
                    isHovered: hoveredControlId == "min",
                    onHoverStateChange: { updateControlHover(id: "min", hovering: $0) },
                    action: onMinimize
                )

                FloatingHeaderIconButton(
                    symbolName: pane.mode == .maximized
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    identifier: "FloatingPaneMaximize-\(uuidKey)",
                    label: FloatingPaneCopy.maximize(pane.mode),
                    value: pane.mode.rawValue,
                    helpText: FloatingPaneCopy.maximize(pane.mode),
                    isProminent: controlsProminent,
                    palette: palette,
                    isHovered: hoveredControlId == "max",
                    onHoverStateChange: { updateControlHover(id: "max", hovering: $0) },
                    action: onToggleMaximize
                )

                FloatingHeaderIconButton(
                    symbolName: "xmark",
                    identifier: "FloatingPaneClose-\(uuidKey)",
                    label: FloatingPaneCopy.close,
                    value: nil,
                    helpText: FloatingPaneCopy.close + " (⌘W)",
                    isProminent: controlsProminent,
                    palette: palette,
                    isHovered: hoveredControlId == "close",
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
    let palette: CardHeaderPalette
    var isHovered: Bool = false
    /// The free-mode toggle uses a quiet tint, with the same hover lifetime as its peers.
    var isPressed: Bool = false
    var isClose: Bool = false
    let onHoverStateChange: (Bool) -> Void
    let action: () -> Void
    /// A menu button: opens this on the press instead of running `action`.
    var menu: (() -> NSMenu?)? = nil

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
                .opacity(isProminent ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            FloatingActionButtonOverlay(
                identifier: identifier,
                label: label,
                value: value ?? "",
                helpText: helpText,
                isSelected: isPressed,
                onHoverChange: onHoverStateChange,
                action: action,
                menu: menu
            )
        }
        .frame(width: size, height: size)
    }

    private var foregroundColor: Color {
        if isPressed { return Color(nsColor: T.claw).opacity(0.75) }
        if isHovered {
            return Color(nsColor: isClose ? T.error : palette.title)
        }
        if isProminent {
            return Color(nsColor: palette.secondary)
        }
        return Color(nsColor: palette.faint)
    }

    private var hoverBackground: Color {
        guard isHovered else { return .clear }
        return isClose
            ? Color(nsColor: T.error).opacity(0.16)
            : Color(nsColor: palette.hover)
    }
}
