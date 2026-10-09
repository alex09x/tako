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

/// SwiftUI view for the vertical Session Sidebar (B5).
struct SessionSidebarView: View {
    @Binding var isPresented: Bool
    let containingWindow: NSWindow?
    let backgroundColor: Color

    @ObservedObject private var store = SessionSidebarStore.shared
    @ObservedObject private var notificationStore = NotificationStore.shared

    private typealias Palette = SessionSidebarPalette

    @State private var selectedIndex: Int = 0
    @State private var editingItemId: String? = nil
    @State private var editingDescriptionText: String = ""
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isListFocused: Bool

    // Tracks window for tab group resolution
    @State private var hostingWindow: NSWindow?

    init(
        isPresented: Binding<Bool>,
        containingWindow: NSWindow? = nil,
        backgroundColor: Color = Color(nsColor: .windowBackgroundColor)
    ) {
        self._isPresented = isPresented
        self.containingWindow = containingWindow
        self.backgroundColor = backgroundColor
    }

    private var targetWindow: NSWindow? {
        containingWindow ?? hostingWindow ?? NSApp?.keyWindow
    }

    private var filterNeedsAttention: Bool {
        store.filterNeedsAttention(for: targetWindow)
    }

    private var filterText: String {
        store.filterText(for: targetWindow)
    }

    private var filterNeedsAttentionBinding: Binding<Bool> {
        Binding(
            get: { store.filterNeedsAttention(for: targetWindow) },
            set: { store.setFilterNeedsAttention($0, for: targetWindow) }
        )
    }

    private var filterTextBinding: Binding<String> {
        Binding(
            get: { store.filterText(for: targetWindow) },
            set: { store.setFilterText($0, for: targetWindow) }
        )
    }

    private var items: [SessionSidebarItem] {
        store.items(for: targetWindow)
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerView
            searchAndFilterBar
            Divider().background(Color(nsColor: Palette.hairline))
            tabListView
            Divider().background(Color(nsColor: Palette.hairline))
            footerView
        }
        .frame(width: 260)
        .background(Color(nsColor: Palette.bar))
        .overlay(
            Rectangle()
                .frame(width: 1)
                .foregroundColor(Color(nsColor: Palette.hairline)),
            alignment: .trailing
        )
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
        .onAppear {
            if hostingWindow == nil {
                hostingWindow = containingWindow ?? NSApp?.keyWindow
            }
            if let activeIndex = items.firstIndex(where: { $0.isSelected }) {
                selectedIndex = activeIndex
            }
            isListFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .takoNotificationStoreDidChange)) { _ in
            store.objectWillChange.send()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notif in
            guard let win = notif.object as? NSWindow else { return }
            // Only update hostingWindow if we were not explicitly bound to a window,
            // or if the window that became key belongs to our own window's tab group.
            if let bound = containingWindow {
                let group = Tako.CustomTabGroup.group(for: bound)
                let groupWindows = group.windows
                guard groupWindows.contains(where: { $0 === win }) else { return }
                hostingWindow = win
            } else if hostingWindow == nil {
                hostingWindow = win
            }
            store.objectWillChange.send()
        }
        .onReceive(NotificationCenter.default.publisher(for: Tako.Notification.takoNewTab)) { _ in
            store.objectWillChange.send()
        }
        .onReceive(NotificationCenter.default.publisher(for: .takoCloseTab)) { _ in
            store.objectWillChange.send()
        }
        .onReceive(NotificationCenter.default.publisher(for: .takoMoveTab)) { _ in
            store.objectWillChange.send()
        }
        .onReceive(NotificationCenter.default.publisher(for: Tako.Notification.takoPresentTerminal)) { _ in
            store.objectWillChange.send()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            Image(systemName: "sidebar.left")
                .foregroundColor(Color(nsColor: Tako.Brand.ember))
                .font(.system(size: 13, weight: .medium))

            Text("Sessions")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(nsColor: Palette.activeText))
                .accessibilityIdentifier("SessionSidebarHeader")

            Spacer()

            Text("\(items.count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(nsColor: Palette.badge))
                .foregroundColor(Color(nsColor: Palette.dim))
                .clipShape(Capsule())

            Button(action: { isPresented = false }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(nsColor: Palette.dim))
            }
            .buttonStyle(.plain)
            .help("Close Session Sidebar (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Search & Filters

    private var searchAndFilterBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: Palette.dim))

                TextField("Filter tabs...", text: filterTextBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(nsColor: Palette.activeText))
                    .focused($isSearchFocused)
                    .onKeyPress(.escape) {
                        isPresented = false
                        return .handled
                    }

                if !filterText.isEmpty {
                    Button(action: { store.setFilterText("", for: targetWindow) }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Color(nsColor: Palette.dim))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: Palette.activeTab))
            .cornerRadius(5)

            // Filter button & Opt-ins
            HStack(spacing: 6) {
                Button(action: { store.setFilterNeedsAttention(!filterNeedsAttention, for: targetWindow) }) {
                    HStack(spacing: 4) {
                        Image(systemName: filterNeedsAttention ? "exclamationmark.circle.fill" : "exclamationmark.circle")
                            .font(.system(size: 10))
                        Text("Needs Attention")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(filterNeedsAttention ? Color(nsColor: Tako.Brand.ember).opacity(0.25) : Color(nsColor: Palette.badge))
                    .foregroundColor(filterNeedsAttention ? Color(nsColor: Tako.Brand.ember) : Color(nsColor: Palette.dim))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Filter to tabs needing attention")

                Spacer()

                Menu {
                    Toggle("Git Branch & Status", isOn: $store.optInGit)
                    Toggle("Listening Ports", isOn: $store.optInPorts)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: Palette.dim))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 18)
                .help("Opt-in Inspections (Git, Ports)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Tab List

    private var tabListView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 2) {
                    if items.isEmpty {
                        VStack(spacing: 6) {
                            Text("No tabs match filter")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color(nsColor: Palette.dim))
                        }
                        .padding(.vertical, 24)
                    } else {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            SessionSidebarRowView(
                                item: item,
                                index: index,
                                selectedIndex: selectedIndex,
                                targetWindow: targetWindow,
                                editingItemId: $editingItemId,
                                editingDescriptionText: $editingDescriptionText,
                                isPresented: $isPresented
                            )
                            .id(index)
                            .onTapGesture {
                                selectedIndex = index
                                store.selectTab(item: item, in: targetWindow)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .focusable()
            .focused($isListFocused)
            .onKeyPress(.upArrow) {
                if selectedIndex > 0 {
                    selectedIndex -= 1
                    proxy.scrollTo(selectedIndex)
                }
                return .handled
            }
            .onKeyPress(.downArrow) {
                if selectedIndex < items.count - 1 {
                    selectedIndex += 1
                    proxy.scrollTo(selectedIndex)
                }
                return .handled
            }
            .onKeyPress(.return) {
                if selectedIndex >= 0 && selectedIndex < items.count {
                    store.selectTab(item: items[selectedIndex], in: targetWindow)
                }
                return .handled
            }
            .onKeyPress(.escape) {
                isPresented = false
                return .handled
            }
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack(spacing: 8) {
            Button(action: {
                if let win = targetWindow,
                   let surface = store.surfaces(in: win).first {
                    NotificationCenter.default.post(
                        name: Tako.Notification.takoNewTab,
                        object: surface
                    )
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                    Text("New Tab")
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundColor(Color(nsColor: Palette.inactiveText))
            }
            .buttonStyle(.plain)

            Spacer()

            Text("↑↓ / ⏎")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Color(nsColor: Palette.dim))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
