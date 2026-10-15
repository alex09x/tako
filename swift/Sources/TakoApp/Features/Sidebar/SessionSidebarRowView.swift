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
    var now: Date = Date()
    var reduceMotion: Bool = false
    var onSelect: () -> Void = {}

    @ObservedObject private var store = SessionSidebarStore.shared
    @ObservedObject private var subagentStore = SubagentHierarchyStore.shared

    private typealias T = Tako.LivingTokens

    private var isNavSelected: Bool {
        selectedIndex == index
    }

    private var isTabActive: Bool {
        item.isSelected
    }

    private var state: Tako.SurfaceState {
        item.surfaceState
    }

    var body: some View {
        let elapsedInState = LivingAnimationState.shared.elapsedInState(
            for: "sidebar-\(item.id)",
            state: state,
            now: now
        )
        let shouldShake = (state == .failed) && !reduceMotion
        let shakeX = shouldShake ? LivingAnimationState.failedShakeOffset(elapsed: elapsedInState) : 0

        Group {
            if item.isChild {
                paneChildRow(elapsedInState: elapsedInState)
            } else {
                sessionParentRow(elapsedInState: elapsedInState)
            }
        }
        .offset(x: shakeX)
    }

    // MARK: - Level 1: Session Row (§5.5)

    private func sessionParentRow(elapsedInState: TimeInterval) -> some View {
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
                    Button(action: {
                        if item.paneCount > 1 {
                            store.toggleTabSplitsCollapsed(item.tabId)
                        }
                        if let pid = item.surfaceId, SubagentHierarchyStore.shared.hasChildren(pid) {
                            SubagentHierarchyStore.shared.toggleCollapsed(pid)
                        }
                    }) {
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

                StatusRingView(
                    state: state,
                    size: .small,
                    now: now,
                    elapsedInState: elapsedInState,
                    reduceMotion: reduceMotion
                )
                .help("Status: \(item.status.rawValue)")

                Text(item.title)
                    .font(Font(T.monoFont(size: 12, weight: isTabActive ? .medium : .regular)))
                    .foregroundColor(sessionTitleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let meta = item.metaDisplayText {
                    Text(meta)
                        .font(Font(T.monoFont(size: 10, weight: .regular)))
                        .foregroundColor(Color(nsColor: T.dim))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                if item.unreadCount > 0 || (state == .failed && !isTabActive) {
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
        .background(
            LivingSurfaceOuterGlow(
                state: state,
                cornerRadius: radius,
                backingColor: glowBacking,
                now: now,
                reduceMotion: reduceMotion
            )
        )
        .background(
            RoundedRectangle(cornerRadius: radius)
                .fill(rowBackgroundColor)
        )
        .overlay(
            LivingSurfaceEffectsOverlay(
                state: state,
                cornerRadius: radius,
                cometLineWidth: 1.0,
                showsCometForProgress: true,
                showsBottomProgressLine: true,
                progressInsetLeft: hasBorderBox1px ? 9 : 8,
                now: now,
                elapsedInState: elapsedInState,
                reduceMotion: reduceMotion
            )
        )
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
        .onTapGesture(perform: onSelect)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    // MARK: - Level 2: Split Pane / Subagent Row (§5.6)

    private func paneChildRow(elapsedInState: TimeInterval) -> some View {
        let radius: CGFloat = 6
        let paneEffectState: Tako.SurfaceState = (state == .working || state == .failed) ? state : .idle
        let vPad: CGFloat = (paneEffectState == .working) ? 5 : 4
        let hPad: CGFloat = (paneEffectState == .working) ? 9 : 8

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                StatusRingView(
                    state: state,
                    size: .small,
                    now: now,
                    elapsedInState: elapsedInState,
                    reduceMotion: reduceMotion
                )

                Text(item.title)
                    .font(Font(T.monoFont(size: 11, weight: .regular)))
                    .foregroundColor(Color(nsColor: state == .offline ? T.faint : T.textInactive))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let meta = item.metaDisplayText {
                    Text(meta)
                        .font(Font(T.monoFont(size: 10, weight: .regular)))
                        .foregroundColor(Color(nsColor: T.dim))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                if item.unreadCount > 0 || (state == .failed && !isTabActive) {
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

            if let pwd = item.workingDirectory, !pwd.isEmpty {
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
        .overlay(
            LivingSurfaceEffectsOverlay(
                state: paneEffectState,
                cornerRadius: radius,
                cometLineWidth: 1.0,
                now: now,
                elapsedInState: elapsedInState,
                reduceMotion: reduceMotion
            )
        )
        .overlay(keyboardSelectionBorder(cornerRadius: radius))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .padding(.leading, 36)
        .padding(.trailing, 8)
        .padding(.vertical, 1)
    }

    // MARK: - Helpers

    private var sessionTitleColor: Color {
        if state == .offline {
            return Color(nsColor: T.faint)
        }
        return Color(nsColor: isTabActive ? T.textActive : T.textInactive)
    }

    private var rowBackgroundColor: Color {
        if isTabActive {
            return Color(nsColor: T.surfaceActive)
        }
        if isNavSelected {
            return Color(nsColor: T.surfaceHover)
        }
        return Color.clear
    }

    @ViewBuilder
    private func keyboardSelectionBorder(cornerRadius: CGFloat) -> some View {
        if isNavSelected && !isTabActive {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color(nsColor: T.ember).opacity(0.6), lineWidth: 1.0)
        }
    }

    private var sessionSecondLineContent: (text: String, color: Color, truncation: Text.TruncationMode)? {
        // §5.5: For waiting session, show the agent question in Claw #FF7A3D instead of path
        if state == .waiting {
            let prompt = item.latestNotification
                ?? item.userDescription
                ?? (item.status == .needsApproval ? "Approval required" : "Waiting for input…")
            return (prompt, Color(nsColor: T.claw), .tail)
        }

        // §5.5: For failed session, show error message / exit info in #D54E53 if available
        if state == .failed, let errNote = item.latestNotification ?? item.userDescription, !errNote.isEmpty {
            return (errNote, Color(nsColor: T.error), .tail)
        }

        var parts: [String] = []
        if let pwd = item.workingDirectory, !pwd.isEmpty {
            parts.append(Tako.formatCompactDirectory(pwd))
        }
        if let branch = item.gitBranch, !branch.isEmpty {
            let dirtySuffix = (item.gitDirty == true && !branch.contains("±")) ? " ±" : ""
            parts.append("⎇ \(branch)\(dirtySuffix)")
        }
        if let ports = item.listeningPorts, !ports.isEmpty {
            parts.append(ports.map { ":\($0)" }.joined(separator: ", "))
        }
        if parts.isEmpty, let notif = item.latestNotification, !notif.isEmpty {
            return (notif, Color(nsColor: T.dim), .tail)
        }
        guard !parts.isEmpty else { return nil }
        return (parts.joined(separator: " · "), Color(nsColor: T.dim), .middle)
    }

    @ViewBuilder
    private var descriptionSection: some View {
        if editingItemId == item.id {
            HStack(spacing: 4) {
                TextField("Add description...", text: $editingDescriptionText, onCommit: {
                    store.setDescription(editingDescriptionText, for: item.id)
                    editingItemId = nil
                })
                .textFieldStyle(.plain)
                .font(Font(T.monoFont(size: 10)))
                .foregroundColor(Color(nsColor: T.textActive))
                .onKeyPress(.escape) {
                    editingItemId = nil
                    isPresented = false
                    return .handled
                }

                Button(action: {
                    store.setDescription(editingDescriptionText, for: item.id)
                    editingItemId = nil
                }) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color(nsColor: T.ok))
                }
                .buttonStyle(.plain)
            }
        } else if let desc = item.userDescription, !desc.isEmpty {
            HStack(spacing: 4) {
                Text(desc)
                    .font(Font(T.monoFont(size: 10)))
                    .foregroundColor(Color(nsColor: T.dim))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }
}
