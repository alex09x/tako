/*
 * tako — «Move to Tab» for a whole session, and for a sidebar row
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

extension MovePaneToTab {
    /// What a sidebar row moves: a session row its whole tab, a terminal
    /// row its one pane. Nil when the row's tab or pane is not open.
    @MainActor struct Subject {
        let tab: BaseTerminalController
        let pane: Tako.SurfaceView?

        /// Whose workspace and tab the destinations are found from.
        var probe: Tako.SurfaceView? { pane ?? tab.surfaceTree.first }
    }

    static func subject(tabID: String, surfaceID: UUID?, isChild: Bool) -> Subject? {
        guard let tab = TerminalController.all.first(where: { $0.window?.stableTabIdentifier == tabID }) else { return nil }
        guard isChild else { return Subject(tab: tab, pane: nil) }
        guard let id = surfaceID, let pane = tab.surfaceTree.first(where: { $0.id == id }) else { return nil }
        return Subject(tab: tab, pane: pane)
    }

    static func destinations(for subject: Subject) -> [BaseTerminalController] {
        subject.probe.map(destinations(for:)) ?? []
    }

    /// A terminal row's pane that shares its tab can leave for a new one.
    static func canLeave(_ subject: Subject) -> Bool {
        subject.pane.flatMap(splitTab(of:)) != nil
    }

    static func move(_ subject: Subject, into destination: BaseTerminalController) throws {
        if let pane = subject.pane {
            try move(pane, into: destination)
        } else {
            try mergeTab(subject.tab, into: destination)
        }
    }

    static func moveToNewTab(_ subject: Subject) throws {
        guard let pane = subject.pane, let tab = splitTab(of: pane) else {
            throw MovePaneError(description: "only a pane that shares its tab can move to a new one")
        }
        try tab.movePaneToNewTab(pane)
    }

    /// Every pane of `source`, in order, joins `destination`: the first
    /// beside its focused pane on the right, each next one right of the one
    /// before. The emptied tab closes. Only the last move selects. A refusal
    /// stops there; panes already moved stay where they went.
    static func mergeTab(_ source: BaseTerminalController, into destination: BaseTerminalController,
                         select: Bool = true) throws {
        guard source !== destination else { throw MovePaneError(description: "a tab cannot move into itself") }
        let panes = Array(source.surfaceTree)
        guard !panes.isEmpty else { throw MovePaneError(description: "the tab has no pane to move") }
        guard var anchor = anchor(in: destination) else {
            throw MovePaneError(description: "the tab has no pane to move beside")
        }
        for (index, pane) in panes.enumerated() {
            try move(pane, into: destination, beside: anchor, direction: .right,
                     select: select && index == panes.count - 1)
            anchor = pane
        }
    }
}
