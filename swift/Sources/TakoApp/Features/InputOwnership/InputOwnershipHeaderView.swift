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

/// Top pane header bar indicating input ownership: locked, or taken over.
public struct InputOwnershipHeaderView: View {
    let paneId: UUID
    var isSecureInput: Bool = false
    @ObservedObject var store: InputOwnershipStore = .shared

    public init(paneId: UUID, isSecureInput: Bool = false) {
        self.paneId = paneId
        self.isSecureInput = isSecureInput
    }

    private var inputState: PaneInputState {
        store.state(for: paneId)
    }

    private var showsBar: Bool { Self.showsBar(for: inputState) }

    /// Only a lock or a takeover puts the bar up. Every takoctl call used
    /// to leave an "anonymous: input" mark over the pane, reads included,
    /// and it stayed there; `takoctl activity` keeps that log.
    static func showsBar(for state: PaneInputState) -> Bool {
        state.isLocked || state.previousAgent != nil
    }

    /// 0 no bar, 1 a bar, 2 a locked bar.
    private var barKey: Int { showsBar ? (inputState.isLocked ? 2 : 1) : 0 }

    /// The bar comes in from the top and goes over 0.15 s, and locking
    /// restyles it over the same: animated where the bar is put in or taken
    /// out, so its transition plays; animated on the bar itself, it never did.
    public var body: some View {
        VStack(spacing: 0) { bar }
            .animation(.easeInOut(duration: 0.15), value: barKey)
    }

    @ViewBuilder private var bar: some View {
        let state = inputState

        if showsBar {
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
                        restorePaneFocus()
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
                        restorePaneFocus()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Hand input control back to \(prevAgent) and lock keyboard typing")
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
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func restorePaneFocus() {
        let targetId = paneId
        let focus = {
            for window in NSApp.windows {
                if let controller = window.windowController as? BaseTerminalController,
                   let surface = controller.surfaceTree.first(where: { $0.id == targetId }) {
                    ControlLayout.focus(surface)
                    return
                }
            }
        }
        focus()
        DispatchQueue.main.async(execute: focus)
    }
}

/// "Copied!" for a moment after a copy, then the button's own words again.
@MainActor
final class CopiedFlash: ObservableObject {
    @Published private(set) var shown = false
    var hold: TimeInterval = 1.5
    private var mark = 0

    func flash() {
        shown = true
        mark += 1
        let this = mark
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            // A copy made meanwhile keeps its own moment.
            guard let self, self.mark == this else { return }
            self.shown = false
        }
    }
}
