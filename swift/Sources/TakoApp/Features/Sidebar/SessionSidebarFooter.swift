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

extension SessionSidebarView {
    /// Puts the arrow-key cursor on the active tab's row.
    func followActiveTab() {
        showsArrowCursor = false
        if let activeIndex = SessionSidebarSelection.activeIndex(in: items) {
            selectedIndex = activeIndex
        }
    }

    func jumpToNextWaiting() {
        let allItems = items
        guard !allItems.isEmpty else { return }
        let start = max(0, selectedIndex)
        for offset in 1...allItems.count {
            let idx = (start + offset) % allItems.count
            let candidate = allItems[idx]
            if candidate.surfaceState == .waiting || candidate.needsAttention {
                selectedIndex = idx
                store.selectTab(item: candidate, in: targetWindow, workspaceStore: workspaceStore)
                return
            }
        }
    }

    func toggleSearchBar() {
        if isSearchExpanded && filterText.isEmpty {
            isSearchExpanded = false
            isSearchFocused = false
            isListFocused = true
        } else {
            isSearchExpanded = true
            searchFocusToken &+= 1
        }
    }

    func collapseSearchAndClearFilter() {
        if let win = targetWindow,
           let editor = win.firstResponder as? NSTextView,
           editor.delegate is SidebarSearchNSTextField {
            _ = win.makeFirstResponder(nil as NSResponder?)
        }
        if !filterText.isEmpty {
            store.setFilterText("", for: targetWindow)
        }
        if filterNeedsAttention {
            store.setFilterNeedsAttention(false, for: targetWindow)
        }
        isSearchExpanded = false
        isSearchFocused = false
        isListFocused = true
    }

    // MARK: - Unified Compact Chrome & Header

    func headerView(sessionCount: Int, attentionCount: Int) -> some View {
        let stripHeight = SessionSidebarChrome.topStripHeight(for: targetWindow)
        let barHeight = SessionSidebarChrome.headerBarHeight(for: targetWindow)
        let leadingInset = SessionSidebarChrome.leadingHeaderInset(for: targetWindow)
        let searchActive = isSearchExpanded || !filterText.isEmpty

        return HStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                if stripHeight > 0 {
                    SidebarTitlebarDragStrip()
                        .frame(maxWidth: .infinity)
                        .frame(height: stripHeight)
                }

                HStack(spacing: 5) {
                    Text("Sessions")
                        .font(T.headerFont(size: 12))
                        .foregroundColor(Color(nsColor: T.textInactive))
                        .lineLimit(1)
                        .accessibilityHidden(true)
                        .background(SidebarHeaderTitleAXOverlay(value: "\(sessionCount)"))

                    Text("\(sessionCount)")
                        .font(Font(T.monoFont(size: 10, weight: .medium)))
                        .foregroundColor(Color(nsColor: T.dim))
                        .lineLimit(1)
                        .accessibilityHidden(true)

                    Spacer(minLength: 0)
                }
                .padding(.leading, leadingInset)
                .frame(height: barHeight)
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 2) {
                SidebarHeaderActionButton(
                    identifier: "SessionSidebarSearchButton",
                    label: "Search sessions",
                    value: searchActive ? "expanded" : "collapsed",
                    helpText: "Search sessions",
                    isActive: searchActive,
                    action: toggleSearchBar
                ) { hovering in
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(nsColor: (searchActive || hovering) ? T.textActive : T.dim))
                        .frame(width: 22, height: 22)
                }

                SidebarHeaderActionButton(
                    identifier: "SessionSidebarAttentionToggle",
                    label: "Needs you",
                    value: filterNeedsAttention ? "active" : "\(attentionCount)",
                    helpText: "Filter sessions needing attention",
                    isActive: filterNeedsAttention,
                    action: { store.setFilterNeedsAttention(!filterNeedsAttention, for: targetWindow) }
                ) { hovering in
                    HStack(spacing: 3) {
                        let ringRests = Self.headerRingRests(reduceMotion: animState.reduceMotion, waiting: attentionCount)
                        SidebarStatusLayerView(
                            state: .waiting, ringCenter: nil, cornerRadius: 0,
                            reduceMotion: ringRests, paused: motionPaused, pulses: 0,
                            ringOnly: StatusRingSize.extraSmall.rawValue
                        )
                        .frame(width: StatusRingSize.extraSmall.rawValue, height: StatusRingSize.extraSmall.rawValue)

                        if attentionCount > 0 || filterNeedsAttention {
                            Text("\(attentionCount)")
                                .font(Font(T.monoFont(size: 9.5, weight: .medium)))
                                .foregroundColor(Color(nsColor: (filterNeedsAttention || hovering) ? T.textActive : T.dim))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, (attentionCount > 0 || filterNeedsAttention) ? 5 : 0)
                    .frame(minWidth: 22, minHeight: 22)
                }

                SidebarHeaderActionButton(
                    identifier: "SessionSidebarHeaderNewSession",
                    label: "New session",
                    value: "",
                    helpText: "New session",
                    isActive: false,
                    action: { store.createNewTab(in: targetWindow) }
                ) { hovering in
                    Image(systemName: "plus")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(Color(nsColor: hovering ? T.textActive : T.dim))
                        .frame(width: 22, height: 22)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .padding(.trailing, 6)
        }
        .frame(height: barHeight)
    }

    // MARK: - Collapsible Search & Segments Drawer (§5.2, §5.3)

    func searchAndSegmentsBar(attentionCount: Int, counts: SidebarAttentionCounts) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text("⌕")
                    .font(Font(T.monoFont(size: 11)))
                    .foregroundColor(Color(nsColor: T.faint))

                ZStack(alignment: .leading) {
                    if filterText.isEmpty {
                        Text("Filter sessions…")
                            .font(Font(T.monoFont(size: 11)))
                            .foregroundColor(Color(nsColor: T.faint))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    SidebarSearchField(
                        text: filterTextBinding,
                        focusRequestToken: searchFocusToken,
                        font: T.monoFont(size: 11),
                        textColor: T.textActive,
                        onEscape: collapseSearchAndClearFilter
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if !filterText.isEmpty {
                    Button(action: { store.setFilterText("", for: targetWindow) }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Color(nsColor: T.dim))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: T.chrome)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: T.hairline), lineWidth: 1))
            .padding(.horizontal, 10)
            .padding(.top, 2)
            .padding(.bottom, 6)

            HStack(spacing: 4) {
                segmentButton(isActive: !filterNeedsAttention) {
                    store.setFilterNeedsAttention(false, for: targetWindow)
                } content: {
                    Text("All")
                        .font(Font(T.monoFont(size: 10, weight: .regular)))
                }

                segmentButton(isActive: filterNeedsAttention) {
                    store.setFilterNeedsAttention(!filterNeedsAttention, for: targetWindow)
                } content: {
                    HStack(spacing: 6) {
                        let ringRests = Self.headerRingRests(reduceMotion: animState.reduceMotion, waiting: attentionCount)
                        SidebarStatusLayerView(
                            state: .waiting, ringCenter: nil, cornerRadius: 0,
                            reduceMotion: ringRests, paused: motionPaused, pulses: 0,
                            ringOnly: StatusRingSize.extraSmall.rawValue
                        )
                        .frame(width: StatusRingSize.extraSmall.rawValue, height: StatusRingSize.extraSmall.rawValue)
                        SessionSidebarCountsLabel(counts: counts, preferences: DesktopPresentation.shared.preferences)
                    }
                }

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }

    private func segmentButton<Content: View>(
        isActive: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .foregroundColor(Color(nsColor: isActive ? T.textActive : T.dim))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(isActive ? Color(nsColor: T.surfaceActive) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isActive ? Color(nsColor: T.hairline) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer (§5.8)

    func triggerNewSession() {
        store.createNewTab(in: targetWindow)
    }

    var footerView: some View {
        ZStack(alignment: .leading) {
            Text(newSessionHint)
                .font(Font(T.monoFont(size: 10.5, weight: .regular)))
                .foregroundColor(Color(nsColor: T.dim))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 7)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            FloatingActionButtonOverlay(
                identifier: "SessionSidebarNewSession",
                label: "New session",
                value: "",
                helpText: "New session",
                onHoverChange: { _ in },
                action: triggerNewSession
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    var newSessionHint: String {
        guard let newSessionShortcut else { return "New session" }
        return "[\(KeybindRegistry.format(shortcut: newSessionShortcut))]  New session"
    }
}

private struct SidebarHeaderActionButton<LabelContent: View>: View {
    let identifier: String
    let label: String
    let value: String
    let helpText: String
    let isActive: Bool
    let action: () -> Void
    @ViewBuilder let content: (_ hovering: Bool) -> LabelContent

    @State private var hovering = false
    private typealias T = Tako.LivingTokens

    var body: some View {
        ZStack {
            content(hovering)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isActive ? Color(nsColor: T.hairline) : Color.clear, lineWidth: 1)
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            FloatingActionButtonOverlay(
                identifier: identifier,
                label: label,
                value: value,
                helpText: helpText,
                onHoverChange: { hovering = $0 },
                action: action
            )
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private var backgroundColor: Color {
        if hovering {
            return Color(nsColor: T.surfaceHover)
        }
        if isActive {
            return Color(nsColor: T.surfaceActive)
        }
        return .clear
    }
}
