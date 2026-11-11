/*
 * tako — A workspace header row in the session sidebar (reference A01 `.ws`)
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

/// Tree header row for a Workspace in `SessionSidebarView` (Spec 1b §5.4).
struct SessionSidebarWorkspaceHeaderView: View {
    let group: SessionSidebarWorkspaceGroup
    var onToggleCollapse: () -> Void
    var onSelectWorkspace: () -> Void
    /// «+», «⋯» on hover (in place of the counts) and the colour dot's menu.
    var actions: SidebarWorkspaceActions? = nil
    @State private var hovering = false
    @Environment(\.sidebarStyle) private var style

    private typealias T = Tako.LivingTokens

    private var idKey: String { group.id.uuidString.lowercased() }

    private func icon(_ text: String, id: String, label: String, run: @escaping () -> Void) -> some View {
        SidebarHeaderActionButton(identifier: id, label: label, value: "", helpText: label, isActive: false,
                                  action: run) { hover in
            Text(text)
                .font(Font(T.monoFont(size: 13, weight: .regular)))
                .foregroundColor(Color(nsColor: hover ? T.textActive : T.dim))
                .frame(width: 22, height: 22)
        }
    }

    private var workspaceDotColor: NSColor {
        T.workspaceColor(for: group.color)
    }

    private var chrome: SidebarChromeMetrics { .of(style) }

    var body: some View {
        let rowContentHeight: CGFloat = group.attentionCount > 0 ? 15 : 13
        HStack(spacing: 7) {
            Button(action: onToggleCollapse) {
                Text(group.isCollapsed ? "▸" : "▾")
                    .font(Font(T.monoFont(size: 9, weight: .regular)))
                    .foregroundColor(Color(nsColor: T.faint))
                    .frame(width: 10, height: 13, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(group.isCollapsed ? "Expand workspace" : "Collapse workspace")

            HStack(spacing: 7) {
                Circle()
                    .fill(Color(nsColor: workspaceDotColor))
                    .frame(width: 7, height: 7)
                    .overlay {
                        if let actions {
                            let id = "SidebarWorkspaceColorDot-\(idKey)"
                            FloatingActionButtonOverlay(identifier: id, label: "Color", value: actions.color, helpText: "Color",
                                                        onHoverChange: { _ in }, action: {
                                guard let anchor = SidebarWorkspaceActions.anchor(id, in: actions.window) else { return }
                                SidebarWorkspaceActions.popUp(actions.colorMenu(), under: anchor)
                            })
                            .frame(width: 14, height: 14)
                        }
                    }

                Text(chrome.headingUppercased ? group.name.uppercased() : group.name)
                    .font(Font(chrome.headingFont))
                    .tracking(chrome.headingTracking)
                    .foregroundColor(Color(nsColor: chrome.headingColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 4)

                ZStack(alignment: .trailing) {
                HStack(spacing: 6) {
                    if group.attentionCount > 0 {
                        let countStr = group.attentionCount > 9 ? "9+" : "\(group.attentionCount)"
                        Text(countStr)
                            .font(Font(T.monoFont(size: 9.5, weight: .bold)))
                            .foregroundColor(Color(nsColor: T.ink))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: T.claw)))
                    }

                    Text("\(group.sessionCount)")
                        .font(Font(T.monoFont(size: 10.5, weight: .medium)))
                        .foregroundColor(Color(nsColor: T.dim))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .opacity(hovering && actions != nil ? 0 : 1)

                if let actions {
                    // `.ws:hover .act`: «+» and «⋯» take the counts' place. They
                    // stay mounted (an AppKit view under the pointer would end
                    // the hover that showed it) and only show on hover.
                    HStack(spacing: 1) {
                        icon("+", id: "SidebarWorkspaceAdd-\(idKey)", label: "New Session Here", run: actions.newSession)
                        let more = "SidebarWorkspaceMore-\(idKey)"
                        icon("⋯", id: more, label: "More") {
                            guard let anchor = SidebarWorkspaceActions.anchor(more, in: actions.window) else { return }
                            SidebarWorkspaceActions.popUp(actions.menu(), under: anchor)
                        }
                    }
                    .frame(height: 13)
                    .opacity(hovering ? 1 : 0)
                }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelectWorkspace)
        }
        .onHover { hovering = $0 }
        .frame(height: rowContentHeight)
        .padding(.top, chrome.headingTop)
        // A01 `.ws`: 8 pt margin + 6/4 pt padding.
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.bottom, 5)
    }
}
