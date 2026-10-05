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

    public init(paneId: UUID) {
        self.paneId = paneId
    }

    private var inputState: PaneInputState {
        store.state(for: paneId)
    }

    public var body: some View {
        let state = inputState
        let showBar = state.isLocked || state.previousAgent != nil || state.lastActivityMark != nil || isHovered

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

                    // Automated activity attribution mark (G2)
                    if let mark = state.lastActivityMark {
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
                        .accessibilityLabel("Automated input from \(mark.client)")
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
