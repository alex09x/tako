/*
 * tako — Explicit teardown of a fixture's retained empty tab
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import AppKit
import ApplicationServices

extension Driver {
    /// The actual sidebar drag view. Its middle can be covered by the Keys,
    /// Settings and New buttons; use the blank area after the traffic lights.
    func fixtureWindowDragPoint() throws -> CGPoint {
        guard let window = activeWindow(),
              let region = descendants(of: window, role: kAXGroupRole as String).first(where: {
                  (attribute($0, "AXIdentifier") as String?) == "SidebarWindowDragRegion"
              }), let frame = axFrame(region), frame.width > 110, frame.height > 0 else {
            throw Failure("no mounted sidebar window-drag region")
        }
        return CGPoint(x: frame.minX + 90, y: frame.midY)
    }

    /// Exit and closing the last terminal leave an empty canvas. Close that
    /// tab explicitly before checking keyboard recovery in a surviving tab.
    /// Refuse to post Cmd+W if there is no uniquely identified empty selection.
    func closeRetainedFixtureTab(_ ctl: String, label: String) throws {
        var before: (panes: [String: String], focused: String?, selected: [String], split: [String])?
        guard wait(for: {
            guard let facts = try? self.treeFacts(ctl, saveAs: "\(label)-empty.json") else { return false }
            let empty = facts.selected.filter { !facts.panes.values.contains($0) }
            guard empty.count == 1, !facts.panes.isEmpty else { return false }
            before = facts
            return true
        }, timeout: 5), let before,
              let empty = before.selected.first(where: { !before.panes.values.contains($0) }) else {
            throw Failure("\(label): the closed terminal did not leave one selected empty tab with surviving terminals")
        }
        let visible = onScreenWindowNumbers()
        closeTab()
        guard wait(for: {
            guard let after = try? self.treeFacts(ctl, saveAs: "\(label)-closed.json") else { return false }
            return Set(after.panes.keys) == Set(before.panes.keys)
                && !after.selected.contains(empty)
                && after.selected.contains(where: { after.panes.values.contains($0) })
                && !self.onScreenWindowNumbers().isEmpty && self.onScreenWindowNumbers() != visible
        }, timeout: 5) else {
            throw Failure("\(label): the empty tab did not close while preserving all surviving terminals")
        }
    }
}
