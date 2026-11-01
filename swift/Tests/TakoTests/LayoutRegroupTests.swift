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
import Foundation
import Testing
@testable import Tako

/// After a normal quit AppKit restores each tab as a window of its own,
/// where it last stood; the layout journal puts them back into one group.
@Suite(.serialized)
@MainActor
struct LayoutRegroupTests {
    private func restoredWindow(_ app: Tako.App, at origin: CGPoint) -> TerminalController {
        let controller = TerminalController(app)
        let window = NSWindow(contentRect: NSRect(origin: origin, size: CGSize(width: 500, height: 300)),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        window.orderFrontRegardless()
        return controller
    }

    @Test func tabsAppKitBroughtBackAsSeparateWindowsAreOneGroupAgain() throws {
        let app = Tako.App()
        let controllers = [CGPoint(x: 100, y: 100), CGPoint(x: 290, y: 180), CGPoint(x: 400, y: 60)]
            .map { restoredWindow(app, at: $0) }
        defer {
            for c in controllers {
                if let w = c.window { Tako.CustomTabGroup.leave(w) }
                c.surfaceTree.forEach { $0.pty?.terminate() }
                c.window?.close()
            }
        }
        let windows = controllers.compactMap(\.window)
        #expect(windows.allSatisfy { $0.isVisible })

        // The journal the last run wrote: one window, these three tabs, the
        // second selected -- at a frame none of the restored windows has.
        let recorded = NSRect(x: 220, y: 140, width: 640, height: 420)
        #expect(windows.allSatisfy { $0.frame != recorded })
        let encoder = JSONEncoder()
        let tabs: [Any] = try controllers.map {
            try JSONSerialization.jsonObject(with: encoder.encode(TerminalRestorableState(from: $0)))
        }
        let journal = LayoutJournal.Journal(generation: 1, windows: [
            LayoutJournal.Window(frame: recorded, isKey: true, selectedTab: 1, tabs: tabs),
        ])

        LayoutRecorder.regroup(journal)

        let group = Tako.CustomTabGroup.group(for: windows[0])
        let grouped = group.windows.map { ObjectIdentifier($0) }
        let expected = windows.map { ObjectIdentifier($0) }
        #expect(grouped == expected)
        #expect(group.selectedWindow === windows[1])
        // The group stands where it stood, not where AppKit put a tab.
        #expect(windows[1].frame == LayoutRecorder.onScreen(recorded))
        // Only the selected tab is on screen; the others stand where it does.
        #expect(windows[1].isVisible)
        #expect(!windows[0].isVisible && !windows[2].isVisible)
        #expect(windows[0].frame == windows[1].frame && windows[2].frame == windows[1].frame)
    }

    @Test func regroupCanCorrectPreviouslyGroupedWindowsWithoutLeavingDuplicates() throws {
        let app = Tako.App()
        let controllers = (0..<4).map { restoredWindow(app, at: CGPoint(x: CGFloat(100 + $0 * 20), y: 100)) }
        defer {
            for c in controllers {
                if let w = c.window { Tako.CustomTabGroup.leave(w) }
                c.surfaceTree.forEach { $0.pty?.terminate() }
                c.window?.close()
            }
        }
        let windows = controllers.compactMap(\.window)
        Tako.CustomTabGroup.join(windows[1], to: windows[0], select: false)
        Tako.CustomTabGroup.join(windows[3], to: windows[2], select: false)
        let placements = windows.map { WorkspaceStore.shared.workspace(forTab: $0.stableTabIdentifier)?.id }
        let tabs: [Any] = try controllers.map {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(TerminalRestorableState(from: $0)))
        }
        let frame = CGRect(x: 100, y: 100, width: 500, height: 300)
        let journal = LayoutJournal.Journal(generation: 1, windows: [
            .init(frame: frame, isKey: true, selectedTab: 0, tabs: [tabs[0], tabs[2]]),
            .init(frame: frame, isKey: false, selectedTab: 0, tabs: [tabs[1], tabs[3]])
        ])
        LayoutRecorder.regroup(journal)
        let first = Tako.CustomTabGroup.group(for: windows[0])
        let second = Tako.CustomTabGroup.group(for: windows[1])
        #expect(first !== second)
        #expect(Set(first.windows.map(ObjectIdentifier.init)) == Set([windows[0], windows[2]].map(ObjectIdentifier.init)))
        #expect(Set(second.windows.map(ObjectIdentifier.init)) == Set([windows[1], windows[3]].map(ObjectIdentifier.init)))
        #expect(windows.map { WorkspaceStore.shared.workspace(forTab: $0.stableTabIdentifier)?.id } == placements)
    }

    @Test func partialJournalDoesNotSplitAnUnrecordedCompanion() throws {
        let app = Tako.App()
        let controllers = (0..<3).map { restoredWindow(app, at: CGPoint(x: CGFloat(100 + $0 * 20), y: 100)) }
        defer {
            for c in controllers {
                if let w = c.window { Tako.CustomTabGroup.leave(w) }
                c.surfaceTree.forEach { $0.pty?.terminate() }
                c.window?.close()
            }
        }
        let windows = controllers.compactMap(\.window)
        Tako.CustomTabGroup.join(windows[1], to: windows[0], select: false)
        let first = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TerminalRestorableState(from: controllers[0])))
        let last = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TerminalRestorableState(from: controllers[2])))
        let journal = LayoutJournal.Journal(generation: 1, windows: [
            .init(frame: windows[0].frame, isKey: true, selectedTab: 0, tabs: [first, last])
        ])
        LayoutRecorder.regroup(journal)
        #expect(Tako.CustomTabGroup.group(for: windows[0]) === Tako.CustomTabGroup.group(for: windows[1]))
        #expect(Tako.CustomTabGroup.group(for: windows[0]) !== Tako.CustomTabGroup.group(for: windows[2]))
    }

    @Test func insertTransfersAWindowWithoutClosingItOrChangingItsWorkspace() {
        let app = Tako.App()
        let controllers = (0..<3).map { restoredWindow(app, at: CGPoint(x: CGFloat(100 + $0 * 20), y: 100)) }
        defer {
            for c in controllers {
                if let w = c.window { Tako.CustomTabGroup.leave(w) }
                c.surfaceTree.forEach { $0.pty?.terminate() }
                c.window?.close()
            }
        }
        let windows = controllers.compactMap(\.window)
        Tako.CustomTabGroup.join(windows[1], to: windows[0], select: false)
        _ = Tako.CustomTabGroup.group(for: windows[2])
        let oldWorkspace = WorkspaceStore.shared.workspace(forTab: windows[1].stableTabIdentifier)?.id
        Tako.CustomTabGroup.insert(windows[1], into: windows[2], at: 1, select: false)
        #expect(!Tako.CustomTabGroup.group(for: windows[0]).windows.contains(windows[1]))
        #expect(Tako.CustomTabGroup.group(for: windows[2]).windows.contains(windows[1]))
        #expect(!Tako.CustomTabGroup.isClosed(windows[1]))
        #expect(WorkspaceStore.shared.workspace(forTab: windows[1].stableTabIdentifier)?.id == oldWorkspace)
    }
}
