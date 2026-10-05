/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import SwiftUI

/// Top pane header bar indicating input ownership (locked vs taken over)
/// and displaying automated keystroke attribution marks (C7, G2).
public struct InputOwnershipHeaderView: View {
    let paneId: UUID
    @ObservedObject var store: InputOwnershipStore = .shared
    @State private var isHovered: Bool = false
    @State private var showActivityLog: Bool = false

    public init(paneId: UUID) {
        self.paneId = paneId
    }

    private var inputState: PaneInputState {
        store.state(for: paneId)
    }

    public var body: some View {
        let state = inputState
        let showBar = state.isLocked || state.previousAgent != nil || state.lastActivityMark != nil || state.automationMayType || isHovered

        ZStack(alignment: .top) {
            // Subtle hover zone at the top edge of the pane
            Color.clear
                .frame(height: 14)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }

            if showBar {
                HStack(spacing: 8) {
                    if state.isLocked {
                        Label {
                            Text(state.owner.isAgent ? "Locked (\(state.owner.agentName ?? "agent"))" : "Locked")
                                .font(.system(size: 11, weight: .medium))
                        } icon: {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.secondary)
                        .accessibilityLabel("Pane input locked")

                        Spacer()

                        Button("Take Over") {
                            store.takeOver(paneId: paneId)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .tint(Color(nsColor: Tako.Brand.ember))
                        .help("Unlock keyboard input for this pane")
                    } else if let prevAgent = state.previousAgent {
                        Label {
                            Text("Interactive (taken over)")
                                .font(.system(size: 11, weight: .medium))
                        } icon: {
                            Image(systemName: "keyboard")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.secondary)

                        Spacer()

                        Button("Hand Back") {
                            store.handBack(paneId: paneId, to: prevAgent)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Hand input control back to \(prevAgent) and lock keyboard typing")
                    } else {
                        Label {
                            Text("Interactive")
                                .font(.system(size: 11, weight: .medium))
                        } icon: {
                            Image(systemName: "keyboard")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.secondary)

                        Spacer()

                        Button("Lock") {
                            store.lock(paneId: paneId)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Lock keyboard typing for this pane")
                    }

                    // Pane-level "automation may type here" switch (G1)
                    if state.automationMayType {
                        Button {
                            store.setAutomationMayType(paneId: paneId, allowed: false)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 9))
                                Text("Auto-type on")
                                    .font(.system(size: 10, weight: .medium))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.mini)
                        .help("Automation may type into this pane. Click to revoke.")
                    } else if isHovered {
                        Button {
                            store.setAutomationMayType(paneId: paneId, allowed: true)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "bolt")
                                    .font(.system(size: 9))
                                Text("Allow auto-type")
                                    .font(.system(size: 10, weight: .medium))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Allow external automation to type into this pane")
                    }

                    // Automated activity attribution mark & popover (Track G2)
                    if let mark = state.lastActivityMark {
                        Button {
                            showActivityLog.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.orange)
                                Text("\(mark.client): \(mark.action)")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Automated input from \(mark.client). Click to view activity log.")
                        .help("View automated activity log for this pane")
                        .popover(isPresented: $showActivityLog) {
                            PaneActivityLogView(paneId: paneId)
                        }
                    } else if isHovered {
                        Button {
                            showActivityLog.toggle()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 9))
                                Text("Activity")
                                    .font(.system(size: 10, weight: .medium))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("View automated activity log for this pane")
                        .popover(isPresented: $showActivityLog) {
                            PaneActivityLogView(paneId: paneId)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(state.isLocked ? Color.secondary.opacity(0.3) : Color.clear, lineWidth: 1)
                )
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .onHover { isHovered = $0 }
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.15), value: state.isLocked)
            }
        }
    }
}

/// Popover view displaying the local bounded activity log for a pane (Track G2).
public struct PaneActivityLogView: View {
    let paneId: UUID
    @ObservedObject var store: InputOwnershipStore = .shared
    @State private var copied: Bool = false

    public init(paneId: UUID) {
        self.paneId = paneId
    }

    private var records: [InputActivityRecord] {
        store.activityLog(for: paneId).reversed()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activity Log")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Local & bounded (\(records.count)/\(InputOwnershipStore.maxLogEntriesPerPane)) • Snapshot privacy")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(copied ? "Copied!" : "Copy JSON") {
                    let json = store.exportLog(for: paneId)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(json, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                Button("Clear") {
                    store.clearLog(paneId: paneId)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            Divider()

            if records.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                    Text("No automated activity recorded for this pane.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(records) { record in
                            HStack(spacing: 8) {
                                Text(record.timestamp, style: .time)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 65, alignment: .leading)

                                Text(record.client)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))

                                Text(record.action)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.primary)

                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .frame(width: 380, height: 260)
    }
}
