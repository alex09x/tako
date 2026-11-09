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
/// Visually renders only right-aligned 30pt pills (no full-width bar or top divider),
/// without reserving terminal space underneath the overlay.
struct FloatingMinimizeShelfView: View {
    let minimizedPanes: [FloatingPaneState]
    let surfaceLookup: (UUID) -> Tako.SurfaceView?
    let onRestore: (Tako.SurfaceView) -> Void

    private var cardsRow: some View {
        // `.dock`: 6 pt between pills, 14 pt from the canvas's right edge.
        HStack(spacing: 6) {
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
        .padding(.horizontal, FloatingPaneGeometry.shelfInset)
        .padding(.bottom, FloatingPaneGeometry.shelfInset)
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
    @ObservedObject private var animationState = LivingAnimationState.shared
    @ObservedObject private var paneTitles = PaneTitleStore.shared

    let paneState: FloatingPaneState
    let onRestore: () -> Void

    @State private var hovering = false
    private typealias T = Tako.LivingTokens

    private var uuidKey: String {
        surfaceView.id.uuidString.lowercased()
    }

    private var shortTitle: String {
        let _ = paneTitles.titles
        return FloatingPaneGeometry.shortTitle(for: surfaceView)
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

    /// The pane's own status, as its sidebar row's ring shows it.
    private var cardState: Tako.SurfaceState {
        crab.paneStatus.surfaceState(crabState: crab.state, live: crab.live)
    }

    /// `.pill` takes the window's line; `.pill.errc` a red one; attention keeps Claw.
    private var pillBorderColor: Color {
        if crab.paneStatus == .error, !isMuted { return Color(nsColor: T.error).opacity(0.6) }
        if needsAttention { return Color(nsColor: T.claw).opacity(0.65) }
        return Color(nsColor: T.badge)
    }

    // Reference `.pill` (style.css, header.css): 30 pt, radius 8, padding
    // 0 6 0 10, gap 8, the 16 pt small ring, title 12/500, the restore arrow
    // (20 pt, radius 5) shown on hover, line + 0 8 24 shadow.
    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                SidebarStatusLayerView(state: cardState, ringCenter: nil, cornerRadius: 0,
                                       reduceMotion: animationState.reduceMotion,
                                       paused: animationState.isTimelinePaused, pulses: crab.live?.pulses ?? 0,
                                       ringOnly: 16, palette: Tako.tabStatusPalette(surface: surfaceView))
                    .frame(width: 16, height: 16)

                Text(shortTitle)
                    .font(Font(T.monoFont(size: 12, weight: .medium)))
                    .foregroundColor(Color(nsColor: T.textActive))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 200, alignment: .leading)

                if unreadCount > 0 || crab.unread {
                    Circle()
                        .fill(Color(nsColor: T.claw))
                        .frame(width: 5, height: 5)
                }

                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(Color(nsColor: hovering ? T.textActive : T.dim))
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.04 : 0)))
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: FloatingPaneGeometry.shelfCardHeight)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: T.surfaceActive).opacity(0.94))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(pillBorderColor, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(colorScheme == .light ? 0.16 : 0.5), radius: 12, x: 0, y: 8)
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
    private var isHovering = false
    private var hoverRefreshQueued = false
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
        refreshHoverAfterLayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshHoverAfterLayout()
    }

    /// Replacing an entered tracking area does not guarantee a matching exit event.
    /// Reconcile after SwiftUI finishes moving the button, without publishing during layout.
    private func refreshHoverAfterLayout() {
        guard !hoverRefreshQueued else { return }
        hoverRefreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hoverRefreshQueued = false
            let inside: Bool
            if let window = self.window, window.isVisible, !self.isHiddenOrHasHiddenAncestor {
                inside = self.bounds.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil))
            } else { inside = false }
            self.setHovering(inside)
        }
    }

    private func setHovering(_ inside: Bool) {
        guard inside != isHovering else { return }
        isHovering = inside
        onHoverChange?(inside)
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
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
    var isSelected = false
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
        view.setAccessibilitySelected(isSelected)
        view.toolTip = helpText
        view.onHoverChange = onHoverChange
        view.onAction = action
    }
}
