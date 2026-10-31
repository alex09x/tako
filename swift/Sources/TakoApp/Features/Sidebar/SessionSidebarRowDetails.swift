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

extension SessionSidebarRowView {
    // MARK: - Helpers

    var sessionTitleColor: Color {
        if state == .offline {
            return Color(nsColor: T.faint)
        }
        return Color(nsColor: isTabActive ? T.textActive : T.textInactive)
    }

    var rowBackgroundColor: Color {
        if isTabActive {
            return Color(nsColor: T.surfaceActive)
        }
        if isNavSelected {
            return Color(nsColor: T.surfaceHover)
        }
        return Color.clear
    }

    @ViewBuilder
    func keyboardSelectionBorder(cornerRadius: CGFloat) -> some View {
        if isNavSelected && !isTabActive {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color(nsColor: T.ember).opacity(0.6), lineWidth: 1.0)
        }
    }

    var sessionSecondLineContent: (text: String, color: Color, truncation: Text.TruncationMode)? {
        // §5.5: For waiting session, show the agent question in Claw #FF7A3D instead of path
        if state == .waiting {
            let prompt = item.latestNotification
                ?? item.userDescription
                ?? (item.status == .needsApproval ? "Approval required" : "Waiting for input…")
            return (prompt, Color(nsColor: T.claw), .tail)
        }

        // Sessions UI 5a: a live program says where it runs while its
        // output arrives, and how long it has been quiet otherwise.
        if let text = item.liveSecondLine {
            return (text, Color(nsColor: T.dim), state == .live(flowing: true) ? .middle : .tail)
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
            let dirtySuffix = branch.contains("±") ? "" : item.gitDirtySuffix
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
    var descriptionSection: some View {
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
