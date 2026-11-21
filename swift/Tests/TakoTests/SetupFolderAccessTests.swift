/*
 * tako — Scoped folder access verification
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing
@testable import Tako

@Suite @MainActor
struct SetupFolderAccessTests {
    @Test func checksConfiguredFoldersWithoutEnumeratingTheirContents() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "fixture".write(to: folder.appendingPathComponent("fixture.txt"), atomically: true, encoding: .utf8)
        var service = SetupFolderAccess()
        service.folders = [folder]
        let result = try #require(await service.checkStandardFolders().first)
        #expect(result.readable)
        #expect(result.folder == folder)
        #expect(result.status == .allowed)
    }

    @Test func constructingTheCheckerDoesNotPerformAProbe() async {
        var service = SetupFolderAccess()
        service.folders = []
        service.check = { folder in
            Issue.record("No configured targets must not perform a probe")
            return SetupFolderAccessResult(folder: folder, status: .unknown)
        }
        #expect(await service.checkStandardFolders().isEmpty)
    }

    @Test func missingFolderIsNotMisreportedAsGranted() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var service = SetupFolderAccess()
        service.folders = [folder]
        let result = try #require(await service.checkStandardFolders().first)
        #expect(!result.readable)
        #expect(result.status == .unknown)
    }

    @Test func usesOnlyThreeStandardLocationsAndPreservesIndividualResults() async {
        var service = SetupFolderAccess()
        #expect(service.folders.map(\.lastPathComponent) == ["Desktop", "Documents", "Downloads"])
        let blocked = service.folders[1]
        service.check = { folder in
            SetupFolderAccessResult(folder: folder, status: folder == blocked ? .notAllowed : .allowed)
        }
        let results = await service.checkStandardFolders()
        #expect(results.map(\.status) == [.allowed, .notAllowed, .allowed])
    }
}
