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
    @Test func checksOnlyTheUserSelectedFixtureFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "fixture".write(to: folder.appendingPathComponent("fixture.txt"), atomically: true, encoding: .utf8)
        var service = SetupFolderAccess()
        service.choose = { folder }
        let result = try #require(await service.chooseAndCheck())
        #expect(result.readable)
        #expect(result.folder == folder)
        #expect(result.message.contains("Terminal programs must be checked separately"))
    }

    @Test func cancelDoesNotReadAnything() async {
        var service = SetupFolderAccess()
        service.choose = { nil }
        service.check = { folder in
            Issue.record("A canceled selection must not perform a read")
            return SetupFolderAccessResult(folder: folder, readable: false, message: "Unexpected")
        }
        #expect(await service.chooseAndCheck() == nil)
    }

    @Test func missingFolderIsNotMisreportedAsGranted() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var service = SetupFolderAccess()
        service.choose = { folder }
        let result = try #require(await service.chooseAndCheck())
        #expect(!result.readable)
        #expect(result.message.contains("couldn't read"))
    }

    @Test func manualGrantInstructionsIdentifyTheAddAndEnableSteps() {
        let text = TerminalPermissionKind.fullDiskAccess.managementSteps.joined(separator: "\n")
        #expect(text.contains("Press +"))
        #expect(text.contains("Turn on its switch"))
        #expect(text.contains("separate request"))
        #expect(TerminalPermissionKind.fullDiskAccess.needsAppLocation)
    }
}
