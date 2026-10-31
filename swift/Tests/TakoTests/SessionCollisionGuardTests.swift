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

struct SessionCollisionGuardTests {
    @Test func detectsTheSamePaneInADifferentRuntimeAndFailsClosedOnUnsafeNamespace() throws {
        let home = URL(fileURLWithPath: "/tmp/tkg-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let pane = UUID()
        #expect(!SessionCollisionGuard.mayContainSession(id: pane, home: home))
        let namespace = try SessionNamespace.open(runtimeID: "0.8.1-0000000000000000", home: home)
        #expect(!SessionCollisionGuard.mayContainSession(id: pane, home: home))
        let root = home.appendingPathComponent(".tako-sessions")
        try Data().write(to: root.appendingPathComponent(".DS_Store"))
        #expect(!SessionCollisionGuard.mayContainSession(id: pane, home: home))
        let unknown = root.appendingPathComponent("unknown-runtime")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
        #expect(SessionCollisionGuard.mayContainSession(id: pane, home: home))
        try FileManager.default.removeItem(at: unknown)
        let oldSocket = namespace.directory.appendingPathComponent(SessionNamespace.sessionName(for: pane))
        try Data().write(to: oldSocket)
        #expect(SessionCollisionGuard.mayContainSession(id: pane, home: home))
        #expect(!SessionCollisionGuard.mayContainSession(id: UUID(), home: home))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: namespace.directory.path)
        #expect(SessionCollisionGuard.mayContainSession(id: UUID(), home: home))
    }
}
