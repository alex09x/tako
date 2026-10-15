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

/// Full-window Pane Overview 4b modal (Spec 1b §6 & §7).
struct PaneOverviewView: View {
    @Binding var isPresented: Bool
    var backgroundColor: Color = Color(nsColor: .windowBackgroundColor)
    var showsBackdrop: Bool = true
    var nowOverride: Date? = nil

    @ObservedObject private var store: PaneOverviewStore
    @ObservedObject private var animState = LivingAnimationState.shared
    @State private var isInitialFrameComplete = false

    private static let staticDate = Date(timeIntervalSinceReferenceDate: 1.1)
    private typealias T = Tako.LivingTokens

    // 3 equal columns matching CSS repeat(3, minmax(0, 1fr)), gap 16
    private let columns = [
        GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 16),
        GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 16),
        GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 16),
    ]

    init(
        isPresented: Binding<Bool>,
        backgroundColor: Color = Color(nsColor: .windowBackgroundColor),
        showsBackdrop: Bool = true,
        store: PaneOverviewStore = .shared,
        nowOverride: Date? = nil
    ) {
        self._isPresented = isPresented
        self.backgroundColor = backgroundColor
        self.showsBackdrop = showsBackdrop
        self.store = store
        self.nowOverride = nowOverride
    }

    private var waitingCount: Int {
        store.items.filter { $0.surfaceState == .waiting }.count
    }

    private var workingCount: Int {
        store.items.filter {
            switch $0.surfaceState {
            case .working, .progress: return true
            default: return false
            }
        }.count
    }

    var body: some View {
        ZStack {
            if showsBackdrop {
                // Backdrop (§6: 0.72 opacity)
                Color.black.opacity(0.72)
                    .ignoresSafeArea()
                    .onTapGesture {
                        close()
                    }
            }

            ZStack {
                Group {
                    Button { store.selectPrevious(cols: 1) } label: { Color.clear }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Button { store.selectNext(cols: 1) } label: { Color.clear }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    Button { store.selectPrevious(cols: 3) } label: { Color.clear }
                        .keyboardShortcut(.upArrow, modifiers: [])
                    Button { store.selectNext(cols: 3) } label: { Color.clear }
                        .keyboardShortcut(.downArrow, modifiers: [])
                    Button { handleReturn() } label: { Color.clear }
                        .keyboardShortcut(.return, modifiers: [])
                    Button { jumpToNextWaiting() } label: { Color.clear }
                        .keyboardShortcut(.return, modifiers: [.option])
                }
                .buttonStyle(PlainButtonStyle())
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)

                // Single TimelineView for the entire Overview modal (§7)
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: animState.isTimelinePaused || !isPresented || !isInitialFrameComplete)) { context in
                    let now = nowOverride ?? animState.effectiveDate(isInitialFrameComplete ? context.date : Self.staticDate)
                    VStack(spacing: 0) {
                        headerView
                        Divider().background(Color(nsColor: T.hairline))
                        contentGridView(now: now)
                        Divider().background(Color(nsColor: T.hairline))
                        footerLegendView
                    }
                }
                .frame(
                    maxWidth: 1100,
                    minHeight: showsBackdrop ? 680 : 580,
                    idealHeight: showsBackdrop ? 760 : 580,
                    maxHeight: showsBackdrop ? 760 : 580
                )
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(nsColor: T.chrome))
                        .shadow(color: Color(nsColor: T.chrome).opacity(showsBackdrop ? 0.4 : 0), radius: 30, x: 0, y: 24)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color(nsColor: T.hairline), lineWidth: 1)
                )
                .padding(showsBackdrop ? 20 : 0)
            }
        }
        .onAppear {
            if store.items.isEmpty {
                store.refresh()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isInitialFrameComplete = true
            }
        }
        .onDisappear {
            isInitialFrameComplete = false
            store.stopObserving()
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .onKeyPress(.return) {
            if NSEvent.modifierFlags.contains(.option) {
                jumpToNextWaiting()
                return .handled
            }
            handleReturn()
            return .handled
        }
    }

    // MARK: - Header (§6: padding 14/18, gap 12, search flex h=30 r=8 #14100E, summary chips on right)

    private var headerView: some View {
        HStack(spacing: 12) {
            Text("Pane Overview")
                .font(T.headerFont(size: 15))
                .foregroundColor(Color(nsColor: T.textActive))
                .accessibilityIdentifier("PaneOverviewHeader")

            PaneOverviewSearchField(filterText: $store.filterText)

            // Summary chips on right (gap 6): "N need you" (attn), "N working" (work), "N panes" (idle)
            HStack(spacing: 6) {
                if waitingCount > 0 {
                    Button(action: {
                        store.filterText = (store.filterText == "Approval" || store.filterText == "Needs input") ? "" : "Approval"
                    }) {
                        LivingStatusChipView(status: .needsApproval, customLabel: "\(waitingCount) need you")
                    }
                    .buttonStyle(.plain)
                }

                if workingCount > 0 {
                    Button(action: {
                        store.filterText = (store.filterText == "Working") ? "" : "Working"
                    }) {
                        LivingStatusChipView(status: .working, customLabel: "\(workingCount) working")
                    }
                    .buttonStyle(.plain)
                }

                Button(action: { store.filterText = "" }) {
                    LivingStatusChipView(status: .idle, customLabel: "\(store.items.count) panes")
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 30)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Grid (§6: 3 columns, gap 16, padding 20)

    private func contentGridView(now: Date) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                let currentItems = store.filteredItems
                if currentItems.isEmpty {
                    emptyStateView
                } else {
                    let isFull = isInitialFrameComplete || nowOverride != nil
                    let visibleLimit = min(currentItems.count, max(isFull ? 9 : 5, store.selectedIndex + (isFull ? 6 : 5)))
                    let visibleSlice = currentItems.prefix(visibleLimit)
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(Array(visibleSlice.enumerated()), id: \.element.id) { index, item in
                            let cardNow = (item.surfaceState == .idle || item.surfaceState == .offline) ? Self.staticDate : now
                            PaneOverviewCard(
                                item: item,
                                isSelected: index == store.selectedIndex,
                                now: cardNow,
                                reduceMotion: animState.reduceMotion,
                                showsAnimatedEffects: isFull
                            )
                            .equatable()
                            .id(index)
                            .onTapGesture {
                                store.selectedIndex = index
                                jump(to: item)
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .onChange(of: store.selectedIndex) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(store.selectedIndex, anchor: .center)
                }
            }
        }
    }

    // MARK: - Footer Legend (§6: border-top 1 #2A211B, padding 10/18, gap 16, keycaps mono 9.5 medium #EDE6DF on #352B23)

    private var footerLegendView: some View {
        HStack(spacing: 16) {
            legendItem(key: "↑↓←→", description: "navigate")
            legendItem(key: "⏎", description: "jump to pane")
            legendItem(key: "⌥⏎", description: "next waiting")
            legendItem(key: "esc", description: "close")

            Spacer()

            if let selected = store.selectedItem {
                Text("\(selected.title) · \(selected.provenanceLabel)")
                    .font(Font(T.monoFont(size: 10.5, weight: .regular)))
                    .foregroundColor(Color(nsColor: T.text))
                    .lineLimit(1)
            }
        }
        .frame(height: 14)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func legendItem(key: String, description: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(Font(T.monoFont(size: 9.5, weight: .medium)))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: T.badge)))
                .foregroundColor(Color(nsColor: T.text))

            Text(description)
                .font(Font(T.monoFont(size: 10.5, weight: .regular)))
                .foregroundColor(Color(nsColor: T.dim))
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundColor(Color(nsColor: T.dim))

            Text("No panes found matching '\(store.filterText)'")
                .font(Font(T.monoFont(size: 13, weight: .medium)))
                .foregroundColor(Color(nsColor: T.textActive))

            Button("Clear Filter") {
                store.filterText = ""
            }
            .buttonStyle(.bordered)
            .font(Font(T.monoFont(size: 11)))
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    // MARK: - Actions

    private func handleReturn() {
        if let selected = store.selectedItem {
            jump(to: selected)
        }
    }

    private func jumpToNextWaiting() {
        let currentItems = store.filteredItems
        guard !currentItems.isEmpty else { return }
        let start = max(0, store.selectedIndex)
        for offset in 1...currentItems.count {
            let idx = (start + offset) % currentItems.count
            let candidate = currentItems[idx]
            if candidate.surfaceState == .waiting || candidate.status == .error {
                store.selectedIndex = idx
                return
            }
        }
    }

    private func jump(to item: PaneOverviewItem) {
        store.jump(to: item)
        isPresented = false
    }

    private func close() {
        store.stopObserving()
        isPresented = false
    }
}

private struct PaneOverviewSearchField: View {
    @Binding var filterText: String
    @FocusState private var isSearchFieldFocused: Bool

    private typealias T = Tako.LivingTokens

    var body: some View {
        HStack(spacing: 8) {
            Text("⌕")
                .font(Font(T.monoFont(size: 12, weight: .medium)))
                .foregroundColor(Color(nsColor: T.faint))

            ZStack(alignment: .leading) {
                if filterText.isEmpty {
                    Text("Filter by title, directory or status…")
                        .font(Font(T.monoFont(size: 11.5)))
                        .foregroundColor(Color(nsColor: T.faint))
                        .allowsHitTesting(false)
                }
                TextField("", text: $filterText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(Font(T.monoFont(size: 11.5)))
                    .foregroundColor(Color(nsColor: T.textActive))
                    .focused($isSearchFieldFocused)
            }
            .frame(maxWidth: .infinity)

            if !filterText.isEmpty {
                Button(action: { filterText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: T.dim))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: T.body)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: T.hairline), lineWidth: 1)
        )
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFieldFocused = true
            }
        }
    }
}
