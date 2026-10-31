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
import TakoKit

/// Row component for an individual session (Level 1) or split pane / subagent (Level 2) in Session Sidebar (Spec 1b §5).
struct SessionSidebarRowView: View {
    let item: SessionSidebarItem
    let index: Int
    let selectedIndex: Int
    let targetWindow: NSWindow?
    @Binding var editingItemId: String?
    @Binding var editingDescriptionText: String
    @Binding var isPresented: Bool
    /// The moment to draw the row at; nil draws it live, with animation
    /// frames only while its state moves.
    var now: Date? = nil
    var reduceMotion: Bool = false
    /// No frames at all: the window is hidden or the app has been away.
    var motionPaused: Bool = false
    var onSelect: () -> Void = {}

    @ObservedObject var store = SessionSidebarStore.shared
    @ObservedObject private var subagentStore = SubagentHierarchyStore.shared
    /// Bumped when a state that moves once comes to rest, so the row is
    /// drawn again and its frames stop.
    @State private var restCount = 0

    typealias T = Tako.LivingTokens

    var isNavSelected: Bool {
        selectedIndex == index
    }

    var isTabActive: Bool {
        item.isSelected
    }

    var state: Tako.SurfaceState {
        item.surfaceState
    }

    private var animationKey: String { "sidebar-\(item.id)" }

    @ViewBuilder
    var body: some View {
        if now != nil {
            shakingRow(moving: true)
        } else {
            let elapsed = LivingAnimationState.shared.elapsedInState(for: animationKey, state: state, now: Date())
            let moving = LivingMotion.isMoving(state, elapsed: elapsed, reduceMotion: reduceMotion)
            let _ = restCount
            shakingRow(moving: moving)
                .task(id: LivingMotion.RestKey(state: state, reduceMotion: reduceMotion)) {
                    guard let wait = LivingMotion.remaining(state, elapsed: elapsed, reduceMotion: reduceMotion) else { return }
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    if !Task.isCancelled { restCount += 1 }
                }
        }
    }

    /// The parts of the row that move take frames of their own
    /// (`SidebarRowClock`); the rest is drawn once per change.
    private func clock<Content: View>(moving: Bool, @ViewBuilder _ content: @escaping (Date, TimeInterval) -> Content) -> SidebarRowClock<Content> {
        SidebarRowClock(fixed: now, key: animationKey, state: state, moving: moving, paused: motionPaused, content: content)
    }

    /// Who draws a row's ring: SwiftUI, at a snapshot's moment; the row's
    /// status layer, as a pill's draws its own; or a layer of its own, for a
    /// pane row, whose border shows another state than its ring.
    private enum RingPainter { case swiftUI, rowLayer, ownLayer }

    /// The status ring: a fixed 14 pt place in the row's layout, the ring
    /// drawn over it. In the layout itself, every frame of the ring had the
    /// whole list laid out again.
    private func ring(moving: Bool, painter: RingPainter) -> some View {
        Color.clear
            .frame(width: StatusRingSize.small.rawValue, height: StatusRingSize.small.rawValue)
            .anchorPreference(key: SidebarRingAnchorKey.self, value: .bounds) { $0 }
            .overlay {
                switch painter {
                case .swiftUI:
                    clock(moving: moving) { now, elapsedInState in
                        StatusRingView(
                            state: state,
                            size: .small,
                            now: now,
                            elapsedInState: elapsedInState,
                            reduceMotion: reduceMotion,
                            pulses: item.live?.pulses ?? 0
                        )
                    }
                case .ownLayer:
                    SidebarStatusLayerView(state: state, ringCenter: nil, cornerRadius: 0, reduceMotion: reduceMotion,
                                           paused: motionPaused, pulses: item.live?.pulses ?? 0,
                                           ringOnly: StatusRingSize.small.rawValue)
                case .rowLayer:
                    EmptyView()
                }
            }
    }

    /// A live row's status is drawn by Core Animation, as a pill tab's is
    /// (`SidebarStatusLayerView`): the render server runs it, and SwiftUI
    /// draws the row again only when what it shows changes. A snapshot's, at
    /// its fixed moment, is drawn by SwiftUI.
    private var layered: Bool { now == nil }

    /// A failure shakes the whole row: the one motion with a clock around all
    /// of it, running for its half second and still otherwise. The row is
    /// always inside it: a row that left a wrapper of its own was a new row,
    /// with a new status layer -- a failure fixed while it shook lost the
    /// done pop and glint, and every row was rebuilt as its shake ended.
    private func shakingRow(moving: Bool) -> some View {
        let shakes = state == .failed && !reduceMotion && moving
        return clock(moving: shakes) { _, elapsed in
            rowContent(moving: moving).offset(x: shakes ? LivingAnimationState.failedShakeOffset(elapsed: elapsed) : 0)
        }
    }

    @ViewBuilder
    private func rowContent(moving: Bool) -> some View {
        if item.isChild {
            paneChildRow(moving: moving)
        } else {
            sessionParentRow(moving: moving)
        }
    }

    // MARK: - Level 1: Session Row (§5.5)

    private func sessionParentRow(moving: Bool) -> some View {
        let radius: CGFloat = 7
        let hasBorderBox1px: Bool = {
            if state == .working || state == .offline { return true }
            if case .progress = state { return true }
            return false
        }()
        let vPad: CGFloat = hasBorderBox1px ? 7 : 6
        let glowBacking: NSColor = isTabActive ? T.surfaceActive : (isNavSelected ? T.surfaceHover : T.body)

        return VStack(alignment: .leading, spacing: 3) {
            // Line 1: chevron (10pt) -> gap 7 -> ring S=14 -> gap 7 -> title -> timer/"NN%" -> Ø5 unread dot
            HStack(spacing: 7) {
                if item.hasChildren {
                    Button(action: { store.toggleRowCollapsed(item) }) {
                        Text(item.isCollapsed ? "▸" : "▾")
                            .font(Font(T.monoFont(size: 9, weight: .regular)))
                            .foregroundColor(Color(nsColor: T.faint))
                            .frame(width: 10, height: 14, alignment: .center)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item.isCollapsed ? "Expand session panes" : "Collapse session panes")
                } else {
                    Color.clear.frame(width: 10, height: 14)
                }

                ring(moving: moving, painter: layered ? .rowLayer : .swiftUI)
                    .help("Status: \(item.status.rawValue)")

                Text(item.title)
                    .font(Font(T.monoFont(size: 12, weight: isTabActive ? .medium : .regular)))
                    .foregroundColor(sessionTitleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let meta = item.metaDisplayText {
                    SessionSidebarMetaLabel(text: meta, style: item.metaStyle)
                }

                if item.unreadCount > 0 || (state == .failed && !isTabActive && item.exitCode == nil) {
                    Circle()
                        .fill(Color(nsColor: T.claw))
                        .frame(width: 5, height: 5)
                }
            }
            .frame(height: 16)

            // Line 2: 31pt left indent (= 10 + 7 + 14, directly under title)
            if let secondLine = sessionSecondLineContent {
                HStack(spacing: 6) {
                    Text(secondLine.text)
                        .font(Font(T.monoFont(size: 10.5, weight: .regular)))
                        .foregroundColor(secondLine.color)
                        .lineLimit(1)
                        .truncationMode(secondLine.truncation)
                    Spacer(minLength: 0)
                }
                .frame(height: 14)
                .padding(.leading, 31)
            }

            if editingItemId == item.id || !(item.userDescription?.isEmpty ?? true) {
                descriptionSection
                    .padding(.leading, 31)
            }
        }
        .padding(.horizontal, hasBorderBox1px ? 9 : 8)
        .padding(.vertical, vPad)
        // Behind the text, over the row's fill, as the glint is in the design;
        // the ring, the border, the line and the glow do not reach the text.
        .backgroundPreferenceValue(SidebarRingAnchorKey.self) { anchor in
            if layered {
                GeometryReader { geo in
                    SidebarStatusLayerView(
                        state: state,
                        ringCenter: anchor.map { CGPoint(x: geo[$0].midX, y: geo[$0].midY) },
                        cornerRadius: radius,
                        reduceMotion: reduceMotion,
                        paused: motionPaused,
                        pulses: item.live?.pulses ?? 0,
                        progressInset: hasBorderBox1px ? 9 : 8,
                        cometForProgress: true
                    )
                }
            }
        }
        .background {
            if !layered {
                clock(moving: moving) { _, elapsedInState in
                    DoneGlintBackground(state: state, cornerRadius: radius, elapsedInState: elapsedInState, reduceMotion: reduceMotion)
                }
            }
        }
        .background {
            if !layered {
                clock(moving: moving) { now, _ in
                    LivingSurfaceOuterGlow(
                        state: state,
                        cornerRadius: radius,
                        backingColor: glowBacking,
                        now: now,
                        reduceMotion: reduceMotion
                    )
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: radius)
                .fill(rowBackgroundColor)
        )
        .overlay {
            if !layered {
                clock(moving: moving) { now, elapsedInState in
                    LivingSurfaceEffectsOverlay(
                        state: state,
                        cornerRadius: radius,
                        cometLineWidth: 1.0,
                        showsCometForProgress: true,
                        showsBottomProgressLine: true,
                        progressInsetLeft: hasBorderBox1px ? 9 : 8,
                        drawsDoneGlint: false,
                        now: now,
                        elapsedInState: elapsedInState,
                        reduceMotion: reduceMotion
                    )
                }
            }
        }
        .overlay(keyboardSelectionBorder(cornerRadius: radius))
        .overlay(alignment: .leading) {
            // Active row left 2pt Ember bar at sidebar left edge (x = 0, i.e. -8pt from row minX)
            if isTabActive {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(nsColor: T.ember))
                    .frame(width: 2)
                    .padding(.vertical, 8)
                    .offset(x: -8)
            }
        }
        .contentShape(Rectangle())
        .onPress(perform: onSelect)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    // MARK: - Level 2: Split Pane / Subagent Row (§5.6)

    private func paneChildRow(moving: Bool) -> some View {
        let radius: CGFloat = 6
        let paneEffectState: Tako.SurfaceState = (state == .working || state == .failed) ? state : .idle
        let vPad: CGFloat = (paneEffectState == .working) ? 5 : 4
        let hPad: CGFloat = (paneEffectState == .working) ? 9 : 8

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                ring(moving: moving, painter: layered ? .ownLayer : .swiftUI)

                Text(item.title)
                    .font(Font(T.monoFont(size: 11, weight: .regular)))
                    .foregroundColor(Color(nsColor: state == .offline ? T.faint : T.textInactive))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let meta = item.metaDisplayText {
                    SessionSidebarMetaLabel(text: meta, style: item.metaStyle)
                }

                if item.unreadCount > 0 || (state == .failed && !isTabActive && item.exitCode == nil) {
                    Circle()
                        .fill(Color(nsColor: T.claw))
                        .frame(width: 5, height: 5)
                }

                if let tag = item.compactPaneTag {
                    Text(tag)
                        .font(Font(T.monoFont(size: 9.5, weight: .medium)))
                        .foregroundColor(Color(nsColor: T.textInactive))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: T.badge)))
                }
            }
            .frame(height: 15)

            if let pwd = item.paneDirectoryToShow {
                Text(Tako.formatCompactDirectory(pwd))
                    .font(Font(T.monoFont(size: 10.5, weight: .regular)))
                    .foregroundColor(Color(nsColor: T.dim))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 21)
            }
        }
        .padding(.horizontal, hPad)
        .padding(.vertical, vPad)
        .background(
            RoundedRectangle(cornerRadius: radius)
                .fill(isNavSelected ? Color(nsColor: T.surfaceHover) : Color.clear)
        )
        .overlay(
            SidebarPaneTreeConnectorShape()
                .stroke(Color(nsColor: T.badge), lineWidth: 1.0)
        )
        .overlay {
            if !layered {
                clock(moving: moving) { now, elapsedInState in
                    LivingSurfaceEffectsOverlay(
                        state: paneEffectState,
                        cornerRadius: radius,
                        cometLineWidth: 1.0,
                        now: now,
                        elapsedInState: elapsedInState,
                        reduceMotion: reduceMotion
                    )
                }
            } else if paneEffectState != .idle {
                SidebarStatusLayerView(state: paneEffectState, ringCenter: nil, cornerRadius: radius,
                                       reduceMotion: reduceMotion, paused: motionPaused, pulses: 0, drawsRing: false)
            }
        }
        .overlay(keyboardSelectionBorder(cornerRadius: radius))
        .contentShape(Rectangle())
        .onPress(perform: onSelect)
        .padding(.leading, 36)
        .padding(.trailing, 8)
        .padding(.vertical, 1)
    }

}
