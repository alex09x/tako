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

/// Bottom-right pill shelf showing minimized internal panes for the active session.
/// Visually renders only right-aligned 30pt stadium pills (no full-width bar or top divider),
/// while `FloatingPaneGeometry.shelfBandHeight` (`44pt`) keeps terminal rows non-occluded.
struct FloatingMinimizeShelfView: View {
    let minimizedPanes: [FloatingPaneState]
    let surfaceLookup: (UUID) -> Tako.SurfaceView?
    let onRestore: (Tako.SurfaceView) -> Void

    private var cardsRow: some View {
        HStack(spacing: 8) {
            ForEach(minimizedPanes, id: \.surfaceId) { entry in
                if let surface = surfaceLookup(entry.surfaceId) {
                    FloatingMinimizedCardView(
                        surfaceView: surface,
                        crab: surface.crab,
                        paneState: entry,
                        onRestore: { onRestore(surface) }
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .fixedSize(horizontal: true, vertical: true)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                Spacer(minLength: 12)
                cardsRow
            }
            ScrollView(.horizontal, showsIndicators: false) {
                cardsRow
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .frame(height: FloatingPaneGeometry.shelfBandHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("FloatingMinimizeShelf")
    }
}

/// Individual minimized terminal pill card (`30pt` height) on the bottom-right shelf.
/// Observes the exact same coalesced status/unread publishers (`CrabTracker`, `NotificationStore`,
/// `AttentionManager`) as `SessionSidebar`, avoiding per-PTY-byte view invalidation.
private struct FloatingMinimizedCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var surfaceView: Tako.SurfaceView
    @ObservedObject var crab: Tako.CrabTracker
    @ObservedObject private var notificationStore = NotificationStore.shared
    @ObservedObject private var attentionManager = AttentionManager.shared

    let paneState: FloatingPaneState
    let onRestore: () -> Void

    @State private var hovering = false
    private typealias T = Tako.LivingTokens

    private var uuidKey: String {
        surfaceView.id.uuidString.lowercased()
    }

    private var shortTitle: String {
        FloatingPaneGeometry.shortTitle(for: surfaceView)
    }

    private var statusValue: String {
        FloatingPaneGeometry.accessibilityStatusValue(for: crab.paneStatus)
    }

    private var isMuted: Bool {
        attentionManager.isMuted(surfaceId: surfaceView.id)
    }

    private var unreadCount: Int {
        isMuted ? 0 : notificationStore.unreadCount(for: surfaceView.id)
    }

    private var needsAttention: Bool {
        guard !isMuted else { return false }
        let statusAttention = crab.paneStatus == .error
            || crab.paneStatus == .needsApproval
            || crab.paneStatus == .waitingForInput
        return unreadCount > 0 || crab.unread || statusAttention
    }

    private var statusColor: Color {
        Color(nsColor: FloatingPaneGeometry.statusNSColor(for: crab.paneStatus, surface: surfaceView))
    }

    private var pillBorderColor: Color {
        if needsAttention {
            return Color(nsColor: T.claw).opacity(0.65)
        }
        return colorScheme == .light
            ? Color.black.opacity(hovering ? 0.18 : 0.12)
            : Color.white.opacity(hovering ? 0.16 : 0.11)
    }

    var body: some View {
        ZStack {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)

                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(nsColor: T.dim))

                Text(shortTitle)
                    .font(Font(T.monoFont(size: 11, weight: .medium)))
                    .foregroundColor(Color(nsColor: hovering ? T.textActive : T.textInactive))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 150, alignment: .leading)

                if needsAttention {
                    Circle()
                        .fill(Color(nsColor: crab.paneStatus == .error ? T.error : T.claw))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: FloatingPaneGeometry.shelfCardHeight)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(nsColor: hovering ? T.surfaceHover : T.surfaceActive).opacity(0.96))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(pillBorderColor, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(hovering ? 0.34 : 0.26), radius: 8, x: 0, y: 3)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            FloatingActionButtonOverlay(
                identifier: "FloatingMinimizedCard-\(uuidKey)",
                label: "\(shortTitle), \(statusValue)",
                value: statusValue,
                helpText: "Restore \(shortTitle)",
                onHoverChange: { hovering = $0 },
                action: onRestore
            )
        }
        .fixedSize(horizontal: true, vertical: true)
    }
}

/// AppKit button hit/accessibility bridge used by floating pane header buttons and minimized shelf cards.
/// Guarantees deterministic mouse clicks inside `TerminalWindow`'s top titlebar band and native fullscreen,
/// preserves `SurfaceView` firstResponder on click, and exposes real `NSAccessibility` `.button` nodes.
final class FloatingActionButtonNSView: NSView {
    var onAction: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    private var trackingAreaRef: NSTrackingArea?
    private var mouseDownPoint: NSPoint?
    private var isTrackingPress = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        isTrackingPress = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTrackingPress, let start = mouseDownPoint else { return }
        let local = convert(event.locationInWindow, from: nil)
        if hypot(local.x - start.x, local.y - start.y) > 8 && !bounds.insetBy(dx: -6, dy: -6).contains(local) {
            isTrackingPress = false
        }
    }

    override func mouseUp(with event: NSEvent) {
        let shouldFire: Bool
        if isTrackingPress {
            let local = convert(event.locationInWindow, from: nil)
            shouldFire = bounds.insetBy(dx: -4, dy: -4).contains(local)
        } else {
            shouldFire = false
        }
        isTrackingPress = false
        mouseDownPoint = nil
        if shouldFire {
            onAction?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onAction?()
        return true
    }
}

struct FloatingActionButtonOverlay: NSViewRepresentable {
    let identifier: String
    let label: String
    let value: String
    let helpText: String
    let onHoverChange: (Bool) -> Void
    let action: () -> Void

    func makeNSView(context: Context) -> FloatingActionButtonNSView {
        let view = FloatingActionButtonNSView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ nsView: FloatingActionButtonNSView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: FloatingActionButtonNSView) {
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
        view.setAccessibilityValue(value)
        view.toolTip = helpText
        view.onHoverChange = onHoverChange
        view.onAction = action
    }
}
