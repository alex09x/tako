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
                            rowView(for: item, index: index)
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

    // MARK: - Tab Row

    private func rowView(for item: SessionSidebarItem, index: Int) -> some View {
        let isNavSelected = selectedIndex == index
        let isTabActive = item.isSelected

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                // Collapse toggle for parent panes
                if item.hasChildren, let pid = item.surfaceId {
                    Button(action: {
                        SubagentHierarchyStore.shared.toggleCollapsed(pid)
                    }) {
                        Image(systemName: item.isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Color(nsColor: Palette.dim))
                            .frame(width: 10, height: 10)
                    }
                    .buttonStyle(.plain)
                    .help(item.isCollapsed ? "Expand subagent group" : "Collapse subagent group")
                }

                // Crab / Status indicator
                Circle()
                    .fill(Color(nsColor: item.status.crabState.color))
                    .frame(width: 8, height: 8)
                    .help("Status: \(item.status.rawValue)")

                // Title + Elapsed
                Text(item.title)
                    .font(.system(size: 12, weight: isTabActive ? .semibold : .regular, design: .monospaced))
                    .foregroundColor(isTabActive ? Color(nsColor: Palette.activeText) : Color(nsColor: Palette.inactiveText))
                    .lineLimit(1)

                // Subagent [label]
                if let label = item.label {
                    Text("[\(label)]")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color(nsColor: Tako.Brand.ember).opacity(0.18))
                        .foregroundColor(Color(nsColor: Tako.Brand.ember))
                        .cornerRadius(3)
                }

                // Parent status summarizing children
                if let summary = item.childrenSummary {
                    Text("(\(summary))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color(nsColor: Palette.dim))
                        .lineLimit(1)
                }

                if let elapsed = item.elapsed {
                    Text(elapsed)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(nsColor: Palette.dim))
                }

                Spacer(minLength: 4)

                // Attention ring / marker
                if item.needsAttention {
                    Circle()
                        .stroke(Color(nsColor: Tako.Brand.ember), lineWidth: 2)
                        .frame(width: 8, height: 8)
                        .help("Needs Attention")
                }

                // Unread notification badge
                if item.unreadCount > 0 {
                    Text("\(item.unreadCount)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color(nsColor: Tako.Brand.ember))
                        .foregroundColor(.black)
                        .clipShape(Capsule())
                }

                // Reorder controls
                HStack(spacing: 2) {
                    Button(action: { store.moveTab(item: item, delta: -1, in: targetWindow) }) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 8))
                            .foregroundColor(Color(nsColor: Palette.dim))
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.canMoveUp)

                    Button(action: { store.moveTab(item: item, delta: 1, in: targetWindow) }) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                            .foregroundColor(Color(nsColor: Palette.dim))
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.canMoveDown)
                }
            }

            // Working directory
            if let pwd = item.workingDirectory, !pwd.isEmpty {
                Text(formatDirectory(pwd))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(nsColor: Palette.dim))
                    .lineLimit(1)
            }

            // Opt-in Git branch and dirty state
            if let branch = item.gitBranch {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                    Text(branch + (item.gitDirty == true ? "*" : (item.gitDirty == nil ? " (?)" : "")))
                        .font(.system(size: 9, design: .monospaced))
                }
                .foregroundColor(
                    item.gitDirty == true ? Color(nsColor: Tako.Brand.ember) :
                    (item.gitDirty == nil ? Color(nsColor: Palette.inactiveText) : Color(nsColor: Palette.dim))
                )
                .help(
                    item.gitDirty == true ? "Modified repository" :
                    (item.gitDirty == nil ? "Git status unavailable" : "Clean repository")
                )
            }

            // Opt-in listening ports
            if let ports = item.listeningPorts, !ports.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "network")
                        .font(.system(size: 9))
                    Text(ports.map { ":\($0)" }.joined(separator: ", "))
                        .font(.system(size: 9, design: .monospaced))
                }
                .foregroundColor(Color(nsColor: Palette.dim))
            }

            // Latest notification snippet
            if let notif = item.latestNotification {
                HStack(spacing: 3) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 8))
                        .foregroundColor(Color(nsColor: Tako.Brand.ember))
                    Text(notif)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color(nsColor: Palette.dim))
                        .lineLimit(1)
                }
            }

            // User-editable description
            if editingItemId == item.id {
                HStack(spacing: 4) {
                    TextField("Add description...", text: $editingDescriptionText, onCommit: {
                        store.setDescription(editingDescriptionText, for: item.id)
                        editingItemId = nil
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(nsColor: Palette.activeText))
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
                            .foregroundColor(Color(nsColor: Tako.Brand.ok))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            } else if let desc = item.userDescription, !desc.isEmpty {
                HStack(spacing: 4) {
                    Text(desc)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(nsColor: Tako.Brand.ember).opacity(0.85))
                        .lineLimit(1)

                    Spacer()

                    Button(action: {
                        editingItemId = item.id
                        editingDescriptionText = desc
                    }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 8))
                            .foregroundColor(Color(nsColor: Palette.dim))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button(action: {
                    editingItemId = item.id
                    editingDescriptionText = ""
                }) {
                    Text("+ note")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color(nsColor: Palette.dim).opacity(0.6))
                }
                .buttonStyle(.plain)
            }

            // Progress bar (Track B2)
            if item.progressState != .none, let progress = item.progress ?? (item.progressState == .indeterminate ? 0.0 : nil) {
                progressBarView(fraction: progress, state: item.progressState)
            }
        }
        .padding(.leading, CGFloat(8 + item.indentationLevel * 16))
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isTabActive ? Color(nsColor: Palette.activeTab) : (isNavSelected ? Color(nsColor: Palette.hoverTab) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isNavSelected ? Color(nsColor: Tako.Brand.ember).opacity(0.6) : Color.clear, lineWidth: 1)
        )
    }

    // MARK: - Progress Bar

    private func progressBarView(fraction: Double, state: TakoTerminalNSView.ProgressState) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(nsColor: Palette.badge))
                    .frame(height: 2)

                if state == .indeterminate {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(nsColor: Tako.Brand.ember))
                        .frame(width: max(8, geo.size.width * 0.3), height: 2)
                } else {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(nsColor: color(for: state)))
                        .frame(width: max(2, geo.size.width * CGFloat(min(1.0, max(0.0, fraction)))), height: 2)
                }
            }
        }
        .frame(height: 2)
        .padding(.top, 2)
    }

    private func color(for state: TakoTerminalNSView.ProgressState) -> NSColor {
        switch state {
        case .normal: return Tako.Brand.ok
        case .error: return Tako.Brand.error
        case .paused: return NSColor.systemOrange
        case .indeterminate, .none: return Tako.Brand.ember
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

    private func formatDirectory(_ raw: String) -> String {
        let home = NSHomeDirectory()
        if raw == home { return "~" }
        if raw.hasPrefix(home) {
            return "~" + raw.dropFirst(home.count)
        }
        return raw
    }

    // MARK: - Palette

    private enum Palette {
        static let bar = NSColor(srgbRed: 0x14 / 255, green: 0x10 / 255, blue: 0x0E / 255, alpha: 1)
        static let activeTab = NSColor(srgbRed: 0x24 / 255, green: 0x1C / 255, blue: 0x16 / 255, alpha: 1)
        static let hoverTab = NSColor(srgbRed: 0x1F / 255, green: 0x19 / 255, blue: 0x15 / 255, alpha: 1)
        static let hairline = NSColor(srgbRed: 0x2A / 255, green: 0x21 / 255, blue: 0x1B / 255, alpha: 1)
        static let badge = NSColor(srgbRed: 0x35 / 255, green: 0x2B / 255, blue: 0x23 / 255, alpha: 1)
        static let activeText = NSColor(srgbRed: 0xFA / 255, green: 0xF7 / 255, blue: 0xF2 / 255, alpha: 1)
        static let inactiveText = NSColor(srgbRed: 0xB7 / 255, green: 0xAC / 255, blue: 0xA1 / 255, alpha: 1)
        static let dim = NSColor(srgbRed: 0x8A / 255, green: 0x7F / 255, blue: 0x76 / 255, alpha: 1)
    }
}
