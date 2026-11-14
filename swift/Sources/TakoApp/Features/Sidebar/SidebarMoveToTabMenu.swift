/*
 * tako — «Move to Tab ▸» on a sidebar row
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

/// A session row merges its whole tab into another tab of its workspace; a
/// terminal row moves its one pane there, or out into a new tab. Hidden
/// when there is nowhere to go.
/// Accessibility identifiers: `SidebarRowMoveToTab-<n>`, `SidebarRowMoveToNewTab`.
struct SidebarMoveToTabMenu: View {
    let item: SessionSidebarItem

    var body: some View {
        if let subject = MovePaneToTab.subject(tabID: item.tabId, surfaceID: item.surfaceId, isChild: item.isChild) {
            let destinations = MovePaneToTab.destinations(for: subject)
            let canLeave = MovePaneToTab.canLeave(subject)
            if !destinations.isEmpty || canLeave {
                Menu(item.isChild ? "Move Terminal to Tab" : "Move to Tab") {
                    ForEach(Array(destinations.enumerated()), id: \.offset) { index, destination in
                        Button(MovePaneToTab.title(of: destination)) { run(subject) { try MovePaneToTab.move(subject, into: destination) } }
                            .accessibilityIdentifier("SidebarRowMoveToTab-\(index)")
                    }
                    if canLeave {
                        if !destinations.isEmpty { Divider() }
                        Button("New Tab") { run(subject) { try MovePaneToTab.moveToNewTab(subject) } }
                            .accessibilityIdentifier("SidebarRowMoveToNewTab")
                    }
                }
            }
        }
    }

    /// A refusal is said in the window whose sidebar was clicked: the row's
    /// own tab may be hidden, or emptied by the move.
    private func run(_ subject: MovePaneToTab.Subject, _ body: () throws -> Void) {
        guard let pane = subject.probe else { return }
        MovePaneToTab.attempt(for: pane, from: NSApp.keyWindow, body)
    }
}
