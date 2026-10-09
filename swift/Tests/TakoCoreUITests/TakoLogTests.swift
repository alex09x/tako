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
@testable import TakoCoreUI
import Testing

struct TakoLogTests {
    @Test func defaultFileLogLevelIsInfo() {
        #expect(TakoLog.fileLogLevel == .info)
        #expect(!TakoLog.isVerboseFileLoggingEnabled)
    }

    @Test func logLevelOrderAndComparison() {
        #expect(TakoLogLevel.debug < TakoLogLevel.info)
        #expect(TakoLogLevel.info < TakoLogLevel.error)
        #expect(TakoLogLevel.error < TakoLogLevel.fault)
    }

    @Test func debugMessagesSuppressedByDefault() throws {
        let originalLevel = TakoLog.fileLogLevel
        defer { TakoLog.fileLogLevel = originalLevel }
        TakoLog.fileLogLevel = .info

        guard let logURL = TakoSession.shared.url else {
            Issue.record("TakoSession shared url is nil")
            return
        }

        let uniqueId = UUID().uuidString
        let debugMsg = "suppressed_debug_marker_\(uniqueId)"
        TakoLog.feed.debug(debugMsg)
        TakoSession.shared.flushForTesting()

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        #expect(!contents.contains(debugMsg))
    }

    @Test func infoMessagesWrittenByDefault() throws {
        let originalLevel = TakoLog.fileLogLevel
        defer { TakoLog.fileLogLevel = originalLevel }
        TakoLog.fileLogLevel = .info

        guard let logURL = TakoSession.shared.url else {
            Issue.record("TakoSession shared url is nil")
            return
        }

        let uniqueId = UUID().uuidString
        let infoMsg = "allowed_info_marker_\(uniqueId)"
        TakoLog.feed.info(infoMsg)
        TakoSession.shared.flushForTesting()

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        #expect(contents.contains(infoMsg))
        #expect(contents.contains("[I] [feed] \(infoMsg)"))
    }

    @Test func verboseFileLoggingToggleEnablesDebug() throws {
        let originalLevel = TakoLog.fileLogLevel
        defer { TakoLog.fileLogLevel = originalLevel }

        TakoLog.isVerboseFileLoggingEnabled = true
        #expect(TakoLog.fileLogLevel == .debug)
        #expect(TakoLog.isVerboseFileLoggingEnabled)

        guard let logURL = TakoSession.shared.url else {
            Issue.record("TakoSession shared url is nil")
            return
        }

        let uniqueId = UUID().uuidString
        let debugMsg = "verbose_debug_marker_\(uniqueId)"
        TakoLog.render.debug(debugMsg)
        TakoSession.shared.flushForTesting()

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        #expect(contents.contains(debugMsg))
        #expect(contents.contains("[D] [render] \(debugMsg)"))

        TakoLog.isVerboseFileLoggingEnabled = false
        #expect(TakoLog.fileLogLevel == .info)
        #expect(!TakoLog.isVerboseFileLoggingEnabled)
    }

    @Test func isolatedSessionRotationAndRetentionBoundsDiskUsage() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("tako-log-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Bounded session: 250 bytes per file, 700 bytes max total, 3 files max
        let session = TakoSession(
            directory: tempDir,
            initialLogLevel: .debug,
            maxFileSizeBytes: 250,
            maxTotalSizeBytes: 700,
            maxFiles: 3,
            maxAgeSeconds: 3600
        )

        // Generate lines to trigger rotations
        for i in 1...20 {
            session.write(cat: "test", level: "I", "rotational payload line \(i) with padding bytes to exceed quota")
            session.flushForTesting()
            // Short pause to guarantee unique timestamp stamps when rotating
            usleep(10_000)
        }
        session.flushForTesting()

        let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "log" }

        // Assert file count is strictly bounded by maxFiles
        #expect(files.count <= 3)
        #expect(files.count >= 2)

        // Assert total size is bounded by maxTotalSizeBytes
        var totalSize: UInt64 = 0
        for file in files {
            let values = try file.resourceValues(forKeys: [.fileSizeKey])
            totalSize += UInt64(values.fileSize ?? 0)
        }
        #expect(totalSize <= 700)
    }
}
