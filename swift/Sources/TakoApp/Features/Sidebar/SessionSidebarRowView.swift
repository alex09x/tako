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

/// Row component for an individual tab session within the Session Sidebar (B5).
struct SessionSidebarRowView: View {
    let item: SessionSidebarItem
    let index: Int
    let selectedIndex: Int
    let targetWindow: NSWindow?
    @Binding var editingItemId: String?
    @Binding var editingDescriptionText: String
    @Binding var isPresented: Bool

    @ObservedObject private var store = SessionSidebarStore.shared

    private var isNavSelected: Bool {
        selectedIndex == index
    }

    private var isTabActive: Bool {
        item.isSelected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            headerRow
            metadataRows
            descriptionSection
            progressSection
        }
        .padding(.leading, CGFloat(8 + item.indentationLevel * 16))
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(rowBackground)
        .overlay(rowOverlay)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(isTabActive ? Color(nsColor: SessionSidebarPalette.activeTab) : (isNavSelected ? Color(nsColor: SessionSidebarPalette.hoverTab) : Color.clear))
    }

    private var rowOverlay: some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(isNavSelected ? Color(nsColor: Tako.Brand.ember).opacity(0.6) : Color.clear, lineWidth: 1)
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 6) {
            if item.hasChildren, let pid = item.surfaceId {
                Button(action: {
                    SubagentHierarchyStore.shared.toggleCollapsed(pid)
                }) {
                    Image(systemName: item.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(nsColor: SessionSidebarPalette.dim))
                        .frame(width: 10, height: 10)
                }
                .buttonStyle(.plain)
                .help(item.isCollapsed ? "Expand subagent group" : "Collapse subagent group")
            }

            Circle()
                .fill(Color(nsColor: item.status.crabState.color))
                .frame(width: 8, height: 8)
                .help("Status: \(item.status.rawValue)")

            Text(item.title)
                .font(.system(size: 12, weight: isTabActive ? .semibold : .regular, design: .monospaced))
                .foregroundColor(isTabActive ? Color(nsColor: SessionSidebarPalette.activeText) : Color(nsColor: SessionSidebarPalette.inactiveText))
                .lineLimit(1)

            if let label = item.label {
                Text("[\(label)]")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color(nsColor: Tako.Brand.ember).opacity(0.18))
                    .foregroundColor(Color(nsColor: Tako.Brand.ember))
                    .cornerRadius(3)
            }

            if let summary = item.childrenSummary {
                Text("(\(summary))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color(nsColor: SessionSidebarPalette.dim))
                    .lineLimit(1)
            }

            if let elapsed = item.elapsed {
                Text(elapsed)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(nsColor: SessionSidebarPalette.dim))
            }

            Spacer(minLength: 4)

            if item.needsAttention {
                Circle()
                    .stroke(Color(nsColor: Tako.Brand.ember), lineWidth: 2)
                    .frame(width: 8, height: 8)
                    .help("Needs Attention")
            }

            if item.unreadCount > 0 {
                Text("\(item.unreadCount)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color(nsColor: Tako.Brand.ember))
                    .foregroundColor(.black)
                    .clipShape(Capsule())
            }

            reorderButtons
        }
    }

    private var reorderButtons: some View {
        HStack(spacing: 2) {
            Button(action: { store.moveTab(item: item, delta: -1, in: targetWindow) }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 8))
                    .foregroundColor(Color(nsColor: SessionSidebarPalette.dim))
            }
            .buttonStyle(.plain)
            .disabled(!item.canMoveUp)

            Button(action: { store.moveTab(item: item, delta: 1, in: targetWindow) }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundColor(Color(nsColor: SessionSidebarPalette.dim))
            }
            .buttonStyle(.plain)
            .disabled(!item.canMoveDown)
        }
    }

    @ViewBuilder
    private var metadataRows: some View {
        if let pwd = item.workingDirectory, !pwd.isEmpty {
            Text(formatDirectory(pwd))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(nsColor: SessionSidebarPalette.dim))
                .lineLimit(1)
        }

        if let branch = item.gitBranch {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                Text(branch + (item.gitDirty == true ? "*" : (item.gitDirty == nil ? " (?)" : "")))
                    .font(.system(size: 9, design: .monospaced))
            }
            .foregroundColor(gitStatusColor)
            .help(gitStatusHelp)
        }

        if let ports = item.listeningPorts, !ports.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: "network")
                    .font(.system(size: 9))
                Text(ports.map { ":\($0)" }.joined(separator: ", "))
                    .font(.system(size: 9, design: .monospaced))
            }
            .foregroundColor(Color(nsColor: SessionSidebarPalette.dim))
        }

        if let notif = item.latestNotification {
            HStack(spacing: 3) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 8))
                    .foregroundColor(Color(nsColor: Tako.Brand.ember))
                Text(notif)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color(nsColor: SessionSidebarPalette.dim))
                    .lineLimit(1)
            }
        }
    }

    private var gitStatusColor: Color {
        if item.gitDirty == true {
            return Color(nsColor: Tako.Brand.ember)
        } else if item.gitDirty == nil {
            return Color(nsColor: SessionSidebarPalette.inactiveText)
        } else {
            return Color(nsColor: SessionSidebarPalette.dim)
        }
    }

    private var gitStatusHelp: String {
        if item.gitDirty == true {
            return "Modified repository"
        } else if item.gitDirty == nil {
            return "Git status unavailable"
        } else {
            return "Clean repository"
        }
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
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(nsColor: SessionSidebarPalette.activeText))
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
                        .foregroundColor(Color(nsColor: SessionSidebarPalette.dim))
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
                    .foregroundColor(Color(nsColor: SessionSidebarPalette.dim).opacity(0.6))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        if item.progressState != .none, let progress = item.progress ?? (item.progressState == .indeterminate ? 0.0 : nil) {
            progressBarView(fraction: progress, state: item.progressState)
        }
    }

    // MARK: - Progress Bar

    private func progressBarView(fraction: Double, state: TakoTerminalNSView.ProgressState) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(nsColor: SessionSidebarPalette.badge))
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

    private func formatDirectory(_ raw: String) -> String {
        let home = NSHomeDirectory()
        if raw == home { return "~" }
        if raw.hasPrefix(home) {
            return "~" + raw.dropFirst(home.count)
        }
        return raw
    }
}
