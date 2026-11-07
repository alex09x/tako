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

/// Compact 26pt floating pane titlebar with drag-only movement, double-click internal maximize/restore,
/// live status indicator, and Minimize / Maximize-Restore / Close controls.
struct FloatingPaneHeaderView: View {
    @ObservedObject var surfaceView: Tako.SurfaceView
    @ObservedObject var crab: Tako.CrabTracker
    let pane: FloatingPaneState
    let presentedFrame: CGRect
    let isFocused: Bool
    let canvasSize: CGSize
    let canMoveToNewWindow: Bool
    let onActivate: () -> Void
    let onDragMove: (_ rect: CGRect) -> Void
    let onDetachMaximized: (_ pointerXInCanvas: CGFloat, _ pointerYInHeader: CGFloat) -> CGRect?
    let onDragCommit: () -> Void
    let onMinimize: () -> Void
    let onToggleMaximize: () -> Void
    let onMoveToNewWindow: () -> Void
    let onClose: () -> Void

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
                        .font(Font(T.monoFont(size: 11, weight: isFocused ? .medium : .regular)))
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
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 3) {
                FloatingHeaderIconButton(
                    symbolName: "minus",
                    identifier: "FloatingPaneMinimize-\(uuidKey)",
                    label: "Minimize Pane",
                    value: pane.mode.rawValue,
                    helpText: "Minimize Pane",
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
                    action: onToggleMaximize
                )

                FloatingHeaderIconButton(
                    symbolName: "xmark",
                    identifier: "FloatingPaneClose-\(uuidKey)",
                    label: "Close Pane",
                    value: nil,
                    helpText: "Close Pane (⌘W)",
                    isClose: true,
                    action: onClose
                )
            }
            .padding(.trailing, 6)
        }
        .frame(height: FloatingPaneGeometry.headerHeight)
        .background(Color(nsColor: isFocused ? T.surfaceActive : T.chrome))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: T.hairline))
                .frame(height: 1)
        }
    }
}

private struct FloatingHeaderIconButton: View {
    let symbolName: String
    let identifier: String
    let label: String
    let value: String?
    let helpText: String
    var isClose: Bool = false
    let action: () -> Void

    @State private var hovering = false
    private typealias T = Tako.LivingTokens

    var body: some View {
        ZStack {
            Image(systemName: symbolName)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(foregroundColor)
                .frame(width: 20, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(hoverBackground)
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            FloatingActionButtonOverlay(
                identifier: identifier,
                label: label,
                value: value ?? "",
                helpText: helpText,
                onHoverChange: { hovering = $0 },
                action: action
            )
        }
        .frame(width: 20, height: 18)
    }

    private var foregroundColor: Color {
        if hovering && isClose {
            return Color(nsColor: T.error)
        }
        return Color(nsColor: hovering ? T.textActive : T.textInactive)
    }

    private var hoverBackground: Color {
        guard hovering else { return .clear }
        return isClose
            ? Color(nsColor: T.error).opacity(0.16)
            : Color(nsColor: T.surfaceHover)
    }
}

/// AppKit drag/double-click view for the floating pane header.
/// Setting `mouseDownCanMoveWindow = false` prevents AppKit from dragging the outer `NSWindow`.
final class FloatingPaneHeaderDragNSView: NSView {
    var paneMode: FloatingPaneMode = .normal
    var paneRect: CGRect = .zero
    var canvasSize: CGSize = .zero
    var canMoveToNewWindow = false
    var onActivate: (() -> Void)?
    var onDragMove: ((CGRect) -> Void)?
    var onDetachMaximized: ((CGFloat, CGFloat) -> CGRect?)?
    var onDragCommit: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onMoveToNewWindow: (() -> Void)?

    private var dragStartWindowPoint: NSPoint?
    private var dragStartRect: CGRect = .zero
    private var didDrag = false
    private var pendingMaximizedDetach = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        if event.clickCount == 2 {
            dragStartWindowPoint = nil
            didDrag = false
            pendingMaximizedDetach = false
            onDoubleClick?()
            return
        }
        dragStartWindowPoint = event.locationInWindow
        dragStartRect = paneRect
        didDrag = false
        pendingMaximizedDetach = (paneMode == .maximized)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartWindowPoint else { return }
        let current = event.locationInWindow
        let dx = current.x - start.x
        let dy = -(current.y - start.y)

        if pendingMaximizedDetach {
            guard hypot(dx, dy) >= 4 else { return }
            pendingMaximizedDetach = false
            let localInSelf = convert(current, from: nil)
            let sidebarOffset = (window?.contentView?.bounds.width ?? canvasSize.width) - canvasSize.width
            let pointerXInCanvas = max(0, current.x - max(0, sidebarOffset))
            if let detached = onDetachMaximized?(pointerXInCanvas, FloatingPaneGeometry.headerHeight - localInSelf.y) {
                dragStartWindowPoint = current
                dragStartRect = detached
                didDrag = true
            }
            return
        }

        guard hypot(dx, dy) >= 1 || didDrag else { return }
        didDrag = true
        let next = CGRect(
            x: (dragStartRect.origin.x + dx).rounded(),
            y: (dragStartRect.origin.y + dy).rounded(),
            width: dragStartRect.width,
            height: dragStartRect.height
        )
        onDragMove?(next)
    }

    override func mouseUp(with event: NSEvent) {
        let shouldCommit = didDrag
        dragStartWindowPoint = nil
        didDrag = false
        pendingMaximizedDetach = false
        if shouldCommit {
            onDragCommit?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onActivate?()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let moveItem = NSMenuItem(
            title: "Move Pane to New Window",
            action: #selector(movePaneToNewWindowAction(_:)),
            keyEquivalent: ""
        )
        moveItem.target = self
        moveItem.isEnabled = canMoveToNewWindow
        menu.addItem(moveItem)
        return menu
    }

    @objc private func movePaneToNewWindowAction(_ sender: Any?) {
        guard canMoveToNewWindow else { return }
        onMoveToNewWindow?()
    }
}

private struct FloatingPaneHeaderDragStrip: NSViewRepresentable {
    let accessibilityIdentifier: String
    let accessibilityLabel: String
    let accessibilityValue: String
    let paneMode: FloatingPaneMode
    let paneRect: CGRect
    let canvasSize: CGSize
    let canMoveToNewWindow: Bool
    let onActivate: () -> Void
    let onDragMove: (CGRect) -> Void
    let onDetachMaximized: (CGFloat, CGFloat) -> CGRect?
    let onDragCommit: () -> Void
    let onDoubleClick: () -> Void
    let onMoveToNewWindow: () -> Void

    func makeNSView(context: Context) -> FloatingPaneHeaderDragNSView {
        let view = FloatingPaneHeaderDragNSView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ nsView: FloatingPaneHeaderDragNSView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: FloatingPaneHeaderDragNSView) {
        view.setAccessibilityIdentifier(accessibilityIdentifier)
        view.setAccessibilityLabel(accessibilityLabel)
        view.setAccessibilityValue(accessibilityValue)
        view.paneMode = paneMode
        view.paneRect = paneRect
        view.canvasSize = canvasSize
        view.canMoveToNewWindow = canMoveToNewWindow
        view.onActivate = onActivate
        view.onDragMove = onDragMove
        view.onDetachMaximized = onDetachMaximized
        view.onDragCommit = onDragCommit
        view.onDoubleClick = onDoubleClick
        view.onMoveToNewWindow = onMoveToNewWindow
    }
}
