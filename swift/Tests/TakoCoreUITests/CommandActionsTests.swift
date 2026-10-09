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
import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

final class TestTerminalDelegate: TakoTerminalNSViewDelegate {
    var sentInputData: [Data] = []
    var sentDeviceReplyData: [Data] = []
    var requestedClipboardCopy: [String] = []
    var paneForwardedTexts: [String] = []

    func terminalView(_ view: TakoTerminalNSView, sendInputData data: Data) {
        sentInputData.append(data)
    }

    func terminalView(_ view: TakoTerminalNSView, sendDeviceReplyData data: Data) {
        sentDeviceReplyData.append(data)
    }

    func terminalView(_ view: TakoTerminalNSView, didResizeCols cols: Int, rows: Int) {}
    func terminalView(_ view: TakoTerminalNSView, didRequestClipboardCopy text: String) {
        requestedClipboardCopy.append(text)
    }

    func terminalView(_ view: TakoTerminalNSView, sendTextToAnotherPane text: String) {
        paneForwardedTexts.append(text)
    }
}

@MainActor
final class CommandActionsTests: XCTestCase {
    func testCopyCommandActionCopiesCommandInput() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var copiedText: String?
        view.copyStringConsumer = { copiedText = $0 }

        let input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}echo \"hello world\"\r\n\u{1b}]133;C\u{07}hello world\r\n\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))

        let commands = view.recordedCommands()
        XCTAssertEqual(commands.count, 1)
        guard let cmd = commands.first else { return }

        view.copyCommand(id: cmd.id)
        XCTAssertEqual(copiedText, "echo \"hello world\"")
    }

    func testCopyOutputActionCopiesCommandOutput() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var copiedText: String?
        view.copyStringConsumer = { copiedText = $0 }

        let input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}cat log.txt\r\n\u{1b}]133;C\u{07}line 1\r\nline 2\r\n\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))

        let commands = view.recordedCommands()
        guard let cmd = commands.first else {
            XCTFail("Expected recorded command")
            return
        }

        view.copyOutput(id: cmd.id)
        XCTAssertNotNil(copiedText)
        XCTAssertTrue(copiedText?.contains("line 1") == true)
        XCTAssertTrue(copiedText?.contains("line 2") == true)
    }

    func testCopyBothAsMarkdownActionFormatsCodeFences() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var copiedText: String?
        view.copyStringConsumer = { copiedText = $0 }

        let input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}ls -la\r\n\u{1b}]133;C\u{07}total 0\r\n-rw-r--r-- 1 test\r\n\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))

        guard let cmd = view.recordedCommands().first else {
            XCTFail("Expected recorded command")
            return
        }

        view.copyBothAsMarkdown(id: cmd.id)
        guard let md = copiedText else {
            XCTFail("Expected markdown copied to clipboard")
            return
        }

        XCTAssertTrue(md.hasPrefix("```bash\nls -la\n```"))
        XCTAssertTrue(md.contains("```\ntotal 0\r\n-rw-r--r-- 1 test\n```") || md.contains("total 0"))

        // Test with zero output: output fence should be omitted
        let zeroOutputMd = TakoTerminalNSView.formatCommandAndOutputAsMarkdown(command: "pwd", output: "")
        XCTAssertEqual(zeroOutputMd, "```bash\npwd\n```")
    }

    func testRerunCommandInsertsAtPromptWithoutExecuting() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = TestTerminalDelegate()
        view.delegate = delegate

        let input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}git pull --rebase\r\n\u{1b}]133;C\u{07}Already up to date.\r\n\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))

        guard let cmd = view.recordedCommands().first else {
            XCTFail("Expected recorded command")
            return
        }

        view.rerunCommand(id: cmd.id)

        XCTAssertFalse(delegate.sentInputData.isEmpty, "Rerun must send input data to terminal")
        let sentBytes = delegate.sentInputData.reduce(Data(), +)
        let sentString = String(decoding: sentBytes, as: UTF8.self)

        XCTAssertTrue(sentString.contains("git pull --rebase"))

        // CRITICAL REQUIREMENT: Must not execute without Enter:
        // Must NOT end with newline (\n) or carriage return (\r)
        if let lastByte = sentBytes.last {
            XCTAssertNotEqual(lastByte, 0x0A, "Rerun must NOT send trailing newline (0x0A)")
            XCTAssertNotEqual(lastByte, 0x0D, "Rerun must NOT send trailing carriage return (0x0D)")
        }
        // In bracketed paste, terminator is \x1b[201~ without following Enter
        if sentString.contains("\u{1b}[201~") {
            XCTAssertFalse(sentString.hasSuffix("\r"), "Bracketed paste must not end in \\r")
            XCTAssertFalse(sentString.hasSuffix("\n"), "Bracketed paste must not end in \\n")
        }
    }

    func testSendOutputToAnotherPaneAsTextWithoutExecuting() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var forwardedText: String?
        view.sendTextToAnotherPaneHandler = { text in
            forwardedText = text
        }

        let input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}cat result.txt\r\n\u{1b}]133;C\u{07}success: 42\r\n\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))

        guard let cmd = view.recordedCommands().first else {
            XCTFail("Expected recorded command")
            return
        }

        view.sendOutputToAnotherPane(id: cmd.id)

        XCTAssertNotNil(forwardedText)
        XCTAssertTrue(forwardedText?.contains("success: 42") == true)
        // Must not have trailing newline or carriage return that would execute
        XCTAssertFalse(forwardedText?.hasSuffix("\n") == true)
        XCTAssertFalse(forwardedText?.hasSuffix("\r") == true)
    }

    func testSaveOutputToFileDirectlyAndViaPanelMock() throws {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}echo report\r\n\u{1b}]133;C\u{07}report data\r\n\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))

        guard let cmd = view.recordedCommands().first else {
            XCTFail("Expected recorded command")
            return
        }

        // Test direct file saving
        let tempDir = FileManager.default.temporaryDirectory
        let directURL = tempDir.appendingPathComponent("direct-save-test-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: directURL) }

        try view.saveOutput(for: cmd.id, to: directURL)
        let directContent = try String(contentsOf: directURL, encoding: .utf8)
        XCTAssertTrue(directContent.contains("report data"))

        // Test save panel mock hook
        let panelURL = tempDir.appendingPathComponent("panel-save-test-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: panelURL) }

        let originalPanel = TakoTerminalNSView.saveFilePanel
        defer { TakoTerminalNSView.saveFilePanel = originalPanel }

        TakoTerminalNSView.saveFilePanel = { text, _, _, completion in
            do {
                try text.write(to: panelURL, atomically: true, encoding: .utf8)
                completion(panelURL)
            } catch {
                completion(nil)
            }
        }

        var completedURL: URL?
        view.saveOutputToFile(id: cmd.id) { url in
            completedURL = url
        }

        XCTAssertEqual(completedURL, panelURL)
        let panelContent = try String(contentsOf: panelURL, encoding: .utf8)
        XCTAssertTrue(panelContent.contains("report data"))
    }

    func testReportSaveErrorPresentsAlert() {
        var presentedAlert: NSAlert?
        let originalPresentAlert = TakoTerminalNSView.presentAlert
        defer { TakoTerminalNSView.presentAlert = originalPresentAlert }

        TakoTerminalNSView.presentAlert = { alert, _ in
            presentedAlert = alert
        }

        struct DummyError: LocalizedError {
            var errorDescription: String? { "Disk full or permission denied" }
        }

        TakoTerminalNSView.reportSaveError(DummyError(), window: nil)

        let exp = expectation(description: "Alert presented")
        DispatchQueue.main.async {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertNotNil(presentedAlert)
        XCTAssertEqual(presentedAlert?.messageText, "Failed to Save Output")
        XCTAssertEqual(presentedAlert?.informativeText, "Disk full or permission denied")
    }

    func testOpenWorkingDirectoryOpensCorrectURL() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var openedURL: URL?
        let originalOpenURL = TakoTerminalNSView.openURL
        defer { TakoTerminalNSView.openURL = originalOpenURL }

        TakoTerminalNSView.openURL = { url in
            openedURL = url
        }

        // Set working directory via OSC 7 and execute command
        let input = "\u{1b}]7;file:///tmp/tako_project\u{07}\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}cargo test\r\n\u{1b}]133;C\u{07}ok\r\n\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))

        guard let cmd = view.recordedCommands().first else {
            XCTFail("Expected recorded command")
            return
        }

        view.openWorkingDirectory(id: cmd.id)
        XCTAssertNotNil(openedURL)
        XCTAssertEqual(openedURL?.path, "/tmp/tako_project")
    }

    func testOpenWorkingDirectoryDisabledWhenCommandCwdIsNil() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var openedURL: URL?
        let originalOpenURL = TakoTerminalNSView.openURL
        defer { TakoTerminalNSView.openURL = originalOpenURL }

        TakoTerminalNSView.openURL = { url in
            openedURL = url
        }

        // 1. Command executed without OSC 7 (cwd is nil)
        let input1 = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}echo first\r\n\u{1b}]133;C\u{07}1\r\n\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input1.utf8))

        guard let cmd1 = view.recordedCommands().first else {
            XCTFail("Expected recorded command")
            return
        }
        XCTAssertNil(cmd1.cwd, "Command must not have a recorded cwd")

        // 2. Later OSC 7 updates the view's current working directory
        let input2 = "\u{1b}]7;file:///tmp/later_dir\u{07}"
        view.feed(data: Data(input2.utf8))
        XCTAssertEqual(view.workingDirectory, "/tmp/later_dir")

        // 3. Opening working directory for cmd1 must NOT fall back to later working directory
        view.openWorkingDirectory(id: cmd1.id)
        XCTAssertNil(openedURL, "openWorkingDirectory must refuse to open an unrelated later working directory")

        // 4. Context menu for cmd1 must have Open Working Directory disabled
        guard let menu = view.contextMenu(for: cmd1.id) else {
            XCTFail("Expected context menu")
            return
        }
        let openDirItem = menu.items.first(where: { $0.title == "Open Working Directory" })
        XCTAssertNotNil(openDirItem)
        XCTAssertFalse(openDirItem?.isEnabled == true, "Open Working Directory must be disabled when cmd.cwd is nil")
        if let openDirItem {
            XCTAssertFalse(view.validateUserInterfaceItem(openDirItem), "validateUserInterfaceItem must return false when cmd.cwd is nil")
        }
    }
}
#endif
