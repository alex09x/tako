/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing
@testable import Tako

@Suite(.serialized)
@MainActor
struct LayoutRecoveryReadOnlyTests {
    @Test(arguments: [false, true])
    func archiveConflictStillSelectsTheValidJournal(keepsWindows: Bool) throws {
        let bundleID = "codes.prod.tako.tests.\(UUID().uuidString)"
        let directory = try LayoutJournal.directory(bundleID: bundleID)
        let args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            UserDefaults.standard.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
            try? FileManager.default.removeItem(at: directory)
        }
        let state = TerminalRestorableState.InternalState<LayoutJournal.PaneShape>(
            focusedSurface: nil, surfaceTree: SplitTree(view: LayoutJournal.PaneShape(id: UUID())),
            effectiveFullscreenMode: nil, tabColor: nil, titleOverride: nil)
        let tab = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        let journal = LayoutJournal.Journal(generation: 1, windows: [LayoutJournal.Window(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600), isKey: true, selectedTab: 0, tabs: [tab])])
        let data = try LayoutJournal.encode(journal)
        let journalURL = directory.appendingPathComponent(LayoutJournal.journalName(1))
        try data.write(to: journalURL)
        try Data("different archived layout".utf8).write(to: directory.appendingPathComponent("recovery-1.json"))
        try LayoutJournal.writeLaunch(.init(state: .dirty, journalGeneration: 1), in: directory)

        LayoutRecorder.begin(bundleID: bundleID, enabled: true, keepsWindows: keepsWindows)

        #expect(LayoutRecorder.source == .journal)
        #expect(!LayoutRecorder.persistenceAvailable)
        #expect(try Data(contentsOf: journalURL) == data)
        #expect(LayoutJournal.readLaunch(in: directory).state == .dirty)
    }
}
