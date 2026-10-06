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

/// Full-window overview of every pane across tabs and windows as live thumbnails, coloured by status (B6).
///
/// Features:
/// - Real-time live status updates reflecting immediately on pane cards.
/// - Type-to-filter by title, working directory, or status.
/// - Keyboard navigation: Arrow keys to navigate, Return to jump, Escape to close.
/// - Fast opening meeting the < 150 ms budget for 30 panes.
struct PaneOverviewView: View {
    @Binding var isPresented: Bool
    var backgroundColor: Color = Color(nsColor: .windowBackgroundColor)

    @ObservedObject private var store = PaneOverviewStore.shared
    @FocusState private var isSearchFieldFocused: Bool

    // Grid layout: responsive adaptive columns
    private let columns = [
        GridItem(.adaptive(minimum: 280, maximum: 380), spacing: 16)
    ]

    init(
        isPresented: Binding<Bool>,
        backgroundColor: Color = Color(nsColor: .windowBackgroundColor)
    ) {
        self._isPresented = isPresented
        self.backgroundColor = backgroundColor
    }

    var body: some View {
        ZStack {
            // Semi-transparent backdrop dismissing overview on click
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .onTapGesture {
                    close()
                }

            // Hidden buttons for reliable AppKit keyboard shortcuts
            ZStack {
                Group {
                    Button { store.selectPrevious(cols: 1) } label: { Color.clear }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Button { store.selectNext(cols: 1) } label: { Color.clear }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    Button { store.selectPrevious(cols: 2) } label: { Color.clear }
                        .keyboardShortcut(.upArrow, modifiers: [])
                    Button { store.selectNext(cols: 2) } label: { Color.clear }
                        .keyboardShortcut(.downArrow, modifiers: [])
                    Button { handleReturn() } label: { Color.clear }
                        .keyboardShortcut(.return, modifiers: [])
                }
                .buttonStyle(PlainButtonStyle())
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)

                // Main Content Modal
                VStack(spacing: 0) {
                    headerView
                    Divider().background(Color(nsColor: Palette.hairline))
                    contentGridView
                    Divider().background(Color(nsColor: Palette.hairline))
                    footerLegendView
                }
                .frame(maxWidth: 1100, maxHeight: 760)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: Palette.modalBackground))
                        .shadow(color: Color.black.opacity(0.4), radius: 24, x: 0, y: 12)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(nsColor: Palette.modalBorder), lineWidth: 1)
                )
                .padding(32)
            }
        }
        .onAppear {
            store.refresh()
            DispatchQueue.main.async {
                isSearchFieldFocused = true
            }
        }
        .onDisappear {
            store.stopObserving()
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .onKeyPress(.return) {
            handleReturn()
            return .handled
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Color(nsColor: Tako.Brand.ember))

            Text("Pane Overview")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(Color(nsColor: Palette.activeText))

            Spacer()

            // Search filter field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(nsColor: Palette.dim))

                TextField("Filter by title, directory, or status…", text: $store.filterText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 13, design: .monospaced))
                    .focused($isSearchFieldFocused)
                    .frame(minWidth: 260)

                if !store.filterText.isEmpty {
                    Button(action: { store.filterText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color(nsColor: Palette.dim))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: Palette.searchBackground))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: Palette.hairline), lineWidth: 1)
            )

            // Pane Count Badge
            let total = store.items.count
            let showing = store.filteredItems.count
            Text(showing == total ? "\(total) panes" : "\(showing) of \(total)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: Palette.badge))
                .foregroundColor(Color(nsColor: Palette.dim))
                .clipShape(Capsule())

            // Close button
            Button(action: { close() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color(nsColor: Palette.dim))
                    .padding(6)
                    .background(Color(nsColor: Palette.buttonBackground))
                    .clipShape(Circle())
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Grid

    private var contentGridView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let currentItems = store.filteredItems
                if currentItems.isEmpty {
                    emptyStateView
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(Array(currentItems.enumerated()), id: \.element.id) { index, item in
                            PaneOverviewCard(item: item, isSelected: index == store.selectedIndex)
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

    // MARK: - Footer Legend

    private var footerLegendView: some View {
        HStack(spacing: 16) {
            legendItem(key: "↑/↓/←/→", description: "Navigate")
            legendItem(key: "↵", description: "Jump to Pane")
            legendItem(key: "esc", description: "Close")

            Spacer()

            if let selected = store.selectedItem {
                Text("Selected: \(selected.title)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(nsColor: Palette.activeText))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func legendItem(key: String, description: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color(nsColor: Palette.badge))
                .foregroundColor(Color(nsColor: Palette.activeText))
                .cornerRadius(4)

            Text(description)
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: Palette.dim))
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundColor(Color(nsColor: Palette.dim))

            Text("No panes found matching '\(store.filterText)'")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(nsColor: Palette.activeText))

            Button("Clear Filter") {
                store.filterText = ""
            }
            .buttonStyle(.bordered)
            .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    // MARK: - Actions

    private func handleReturn() {
        if let selected = store.selectedItem {
            jump(to: selected)
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

    // MARK: - Theme Palette

    private typealias Palette = PaneOverviewPalette
}

