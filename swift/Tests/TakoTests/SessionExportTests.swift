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
import AppKit
@testable import Tako

@Suite @MainActor struct SessionExportTests {

    // MARK: - Control Sequence Sanitizer Tests

    @Test func testSanitizerStripsAnsiAndControlSequences() {
        // 1. Plain safe text passes through
        let plain = "Hello, world! This is safe text.\nSecond line\twith tab.\r\n"
        #expect(ControlSequenceSanitizer.dropControlSequences(from: plain) == plain)

        // 2. CSI sequences (colors, cursor movements, erase display)
        let withCsi = "\u{1b}[31;1mRed Bold Text\u{1b}[0m and \u{1b}[2Jcleared screen\u{1b}[?25h"
        #expect(ControlSequenceSanitizer.dropControlSequences(from: withCsi) == "Red Bold Text and cleared screen")

        // 3. OSC sequences with BEL and ST terminators
        let withOscBel = "Before\u{1b}]0;Window Title\u{07}After"
        #expect(ControlSequenceSanitizer.dropControlSequences(from: withOscBel) == "BeforeAfter")

        let withOscSt = "Start\u{1b}]52;c;dGVzdA==\u{1b}\\End"
        #expect(ControlSequenceSanitizer.dropControlSequences(from: withOscSt) == "StartEnd")

        // 4. DCS, APC, PM sequences
        let withDcs = "Text\u{1b}P1$q\"p\u{1b}\\Remainder"
        #expect(ControlSequenceSanitizer.dropControlSequences(from: withDcs) == "TextRemainder")

        let withApc = "A\u{1b}_Gf=100;payload\u{07}B"
        #expect(ControlSequenceSanitizer.dropControlSequences(from: withApc) == "AB")

        // 5. Charset designation sequences
        let withCharset = "Charset\u{1b}(BText\u{1b})0More"
        #expect(ControlSequenceSanitizer.dropControlSequences(from: withCharset) == "CharsetTextMore")

        // 6. Single character escape sequences
        let withSingleEsc = "Line1\u{1b}MLine2\u{1b}cLine3"
        #expect(ControlSequenceSanitizer.dropControlSequences(from: withSingleEsc) == "Line1Line2Line3")

        // 7. C0 control characters (except \n, \r, \t)
        let withC0 = "Hello\u{00}\u{01}\u{02}\u{07}\u{08}World\nNext"
        #expect(ControlSequenceSanitizer.dropControlSequences(from: withC0) == "HelloWorld\nNext")

        // 8. DEL (0x7F) and 8-bit C1 controls (0x80-0x9F)
        let withC1 = "Safe\u{7F}Text\u{009B}31mColored\u{009D}0;Title\u{0007}Done"
        #expect(ControlSequenceSanitizer.dropControlSequences(from: withC1) == "SafeText31mColored0;TitleDone")
    }

    // MARK: - Format Version & Rejection Tests

    @Test func testNewerFormatVersionIsRefusedWithClearError() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileUrl = tempDir.appendingPathComponent("future_session.json")

        // Create a JSON payload with formatVersion = 99
        let futurePayload = """
        {
          "formatVersion": 99,
          "exportedAt": "2026-10-05T03:00:00Z",
          "takoVersion": "9.9.0",
          "windows": []
        }
        """
        try futurePayload.write(to: fileUrl, atomically: true, encoding: .utf8)

        // inspectSession must throw unsupportedFormatVersion
        #expect(throws: SessionExportError.unsupportedFormatVersion(got: 99, supported: 1)) {
            try SessionExportManager.shared.inspectSession(from: fileUrl)
        }

        // importSession must also throw unsupportedFormatVersion
        #expect(throws: SessionExportError.unsupportedFormatVersion(got: 99, supported: 1)) {
            try SessionExportManager.shared.importSession(from: fileUrl)
        }

        do {
            _ = try SessionExportManager.shared.inspectSession(from: fileUrl)
            Issue.record("Expected unsupportedFormatVersion to be thrown")
        } catch let error as SessionExportError {
            #expect(error.errorDescription?.contains("Unsupported session format version 99") == true)
            #expect(error.errorDescription?.contains("supports up to version 1") == true)
        }
    }

    // MARK: - Codable Round-Trip Tests

    @Test func testSessionFileCodableRoundTrip() throws {
        let paneId1 = UUID()
        let paneId2 = UUID()
        let paneId3 = UUID()

        let pane1 = ExportedPane(
            id: paneId1,
            pwd: "/Users/alex/project",
            title: "Editor",
            scrollback: "Line 1\nLine 2\n",
            resume: ExportedResume(argv: ["nvim", "main.rs"], cwd: "/Users/alex/project")
        )
        let pane2 = ExportedPane(
            id: paneId2,
            pwd: "/Users/alex/project",
            title: "Build",
            scrollback: "Compiling tako...\nFinished.\n",
            resume: nil
        )
        let pane3 = ExportedPane(
            id: paneId3,
            pwd: "/var/log",
            title: "Logs",
            scrollback: "log stream\n",
            resume: nil
        )

        let splitNode = ExportedLayoutNode.split(
            direction: "vertical",
            ratio: 0.5,
            left: .leaf(paneId: paneId1),
            right: .leaf(paneId: paneId2)
        )
        let rootNode = ExportedLayoutNode.split(
            direction: "horizontal",
            ratio: 0.7,
            left: splitNode,
            right: .leaf(paneId: paneId3)
        )

        let window = ExportedWindow(
            id: UUID(),
            titleOverride: "My Workspace",
            tabColor: "blue",
            layout: rootNode,
            panes: [pane1, pane2, pane3]
        )

        let sessionFile = SessionExportFile(
            formatVersion: 1,
            exportedAt: Date(),
            takoVersion: "0.1.7",
            windows: [window]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sessionFile)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionExportFile.self, from: data)

        #expect(decoded.formatVersion == 1)
        #expect(decoded.takoVersion == "0.1.7")
        #expect(decoded.windows.count == 1)

        let decWin = decoded.windows[0]
        #expect(decWin.titleOverride == "My Workspace")
        #expect(decWin.tabColor == "blue")
        #expect(decWin.panes.count == 3)
        #expect(decWin.panes[0].resume?.argv == ["nvim", "main.rs"])
        #expect(decWin.panes[1].resume == nil)

        guard case .split(let dir, let ratio, _, _) = decWin.layout else {
            Issue.record("Expected horizontal split at root")
            return
        }
        #expect(dir == "horizontal")
        #expect(abs(ratio - 0.7) < 0.001)
    }

    // MARK: - Untrusted Import Security Invariants

    @Test func testImportedSessionNeverRunsAutomatically() {
        let defaultsSuite = "test.tako.session_export.trust.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let trustStore = ResumeTrustStore(defaults: defaults)
        let cwd = "/Users/alex/safe-dir"

        // Pre-approve prefix "claude" in this cwd
        trustStore.approve(prefix: "claude", cwd: cwd)
        #expect(trustStore.isApproved(argv: ["claude", "--resume", "123"], cwd: cwd))

        // Create an imported record
        let imported = ResumeSessionRecord(
            argv: ["claude", "--resume", "123"],
            cwd: cwd,
            isImported: true
        )
        #expect(imported.isImported == true)

        // Invariant: An imported session must NEVER satisfy the auto-run condition
        let autoRunAllowed = !imported.isImported && trustStore.isApproved(argv: imported.argv, cwd: cwd)
        #expect(!autoRunAllowed)
    }

    // MARK: - Control Commands Inspection

    @Test func testControlCommandSessionInfo() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileUrl = tempDir.appendingPathComponent("test_info.json")

        let paneId = UUID()
        let pane = ExportedPane(
            id: paneId,
            pwd: "/tmp",
            title: "Terminal",
            scrollback: "safe scrollback\n",
            resume: ExportedResume(argv: ["python", "app.py"], cwd: "/tmp")
        )
        let window = ExportedWindow(
            id: UUID(),
            titleOverride: "Info Test",
            tabColor: nil,
            layout: .leaf(paneId: paneId),
            panes: [pane]
        )
        let sessionFile = SessionExportFile(
            formatVersion: 1,
            exportedAt: Date(),
            takoVersion: "0.1.7",
            windows: [window]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sessionFile)
        try data.write(to: fileUrl)

        // Invoke info via ControlCommands.sessionCommand
        let req = ControlRequest(
            cmd: "session",
            args: [
                "action": .string("info"),
                "path": .string(fileUrl.path)
            ],
            from: nil
        )
        let resp = try ControlCommands.sessionCommand(req, all: [])
        #expect(resp["format_version"]?.number == 1)
        #expect(resp["tako_version"]?.string == "0.1.7")
        #expect(resp["windows"]?.number == 1)
        #expect(resp["panes"]?.number == 1)
        #expect(resp["resumes"]?.number == 1)
    }
}
