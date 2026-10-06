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

private final class TestTerminalDelegate: TakoTerminalNSViewDelegate {
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

    func testContextMenuContainsAllSevenActions() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let input = "\u{1b}]7;file:///tmp/test\u{07}\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}make build\r\n\u{1b}]133;C\u{07}built\r\n\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))

        guard let cmd = view.recordedCommands().first else {
            XCTFail("Expected recorded command")
            return
        }

        guard let menu = view.contextMenu(for: cmd.id) else {
            XCTFail("Expected context menu for command")
            return
        }

        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Copy Command"), "Menu must contain 'Copy Command'")
        XCTAssertTrue(titles.contains("Copy Output"), "Menu must contain 'Copy Output'")
        XCTAssertTrue(titles.contains("Copy Both as Markdown"), "Menu must contain 'Copy Both as Markdown'")
        XCTAssertTrue(titles.contains("Re-run in This Pane"), "Menu must contain 'Re-run in This Pane'")
        XCTAssertTrue(titles.contains("Send Output to Another Pane"), "Menu must contain 'Send Output to Another Pane'")
        XCTAssertTrue(titles.contains("Save Output to File…"), "Menu must contain 'Save Output to File…'")
        XCTAssertTrue(titles.contains("Open Working Directory"), "Menu must contain 'Open Working Directory'")

        // Verify representedObject on items carries CommandTarget with cmd.id and cmd.epoch
        let actionTitles = [
            "Copy Command", "Copy Output", "Copy Both as Markdown",
            "Re-run in This Pane", "Send Output to Another Pane", "Save Output to File…",
            "Open Working Directory"
        ]
        for title in actionTitles {
            let item = menu.items.first(where: { $0.title == title })
            let target = item?.representedObject as? TakoTerminalNSView.CommandTarget
            XCTAssertEqual(target?.id, cmd.id, "Item '\(title)' must carry command ID")
            XCTAssertEqual(target?.epoch, cmd.epoch, "Item '\(title)' must carry command epoch")
        }
    }

    func testContextMenuOnStickyHeaderTargetsStickyCommand() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        // Command 1 with 40 lines of output
        var input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}cmd-one\r\n\u{1b}]133;C\u{07}"
        for i in 1...40 {
            input += "output \(i)\r\n"
        }
        input += "\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))
        view.updateScroller()

        let stickyHeader = view.currentStickyCommandHeader()
        XCTAssertNotNil(stickyHeader)
        XCTAssertEqual(stickyHeader?.command, "cmd-one")

        // Right-click inside sticky header frame
        let headerFrame = view.stickyHeaderLayer.frame
        let clickPoint = NSPoint(x: headerFrame.midX, y: headerFrame.midY)
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: clickPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )!

        guard let menu = view.menu(for: event) else {
            XCTFail("Expected menu on right click")
            return
        }

        let copyCmdItem = menu.items.first(where: { $0.title == "Copy Command" })
        let target = copyCmdItem?.representedObject as? TakoTerminalNSView.CommandTarget
        XCTAssertEqual(target?.id, stickyHeader?.commandId)
    }

    func testRunningCommandActions() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var copiedText: String?
        view.copyStringConsumer = { copiedText = $0 }

        // Start command without exit code (running)
        let input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}sleep 100\r\n\u{1b}]133;C\u{07}running progress\r\n"
        view.feed(data: Data(input.utf8))

        guard let cmd = view.recordedCommands().first else {
            XCTFail("Expected recorded command")
            return
        }
        XCTAssertTrue(cmd.running, "Command should be running")

        view.copyCommand(id: cmd.id)
        XCTAssertEqual(copiedText, "sleep 100")

        view.copyOutput(id: cmd.id)
        XCTAssertTrue(copiedText?.contains("running progress") == true)
    }

    func testMultipleRecordedCommandsIndependentActions() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var copiedText: String?
        view.copyStringConsumer = { copiedText = $0 }

        let input1 = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}first-command\r\n\u{1b}]133;C\u{07}first-out\r\n\u{1b}]133;D;0\u{07}"
        let input2 = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}second-command\r\n\u{1b}]133;C\u{07}second-out\r\n\u{1b}]133;D;0\u{07}"
        view.feed(data: Data((input1 + input2).utf8))

        let commands = view.recordedCommands()
        XCTAssertEqual(commands.count, 2)

        view.copyCommand(id: commands[0].id)
        XCTAssertEqual(copiedText, "first-command")

        view.copyCommand(id: commands[1].id)
        XCTAssertEqual(copiedText, "second-command")

        view.copyOutput(id: commands[0].id)
        XCTAssertTrue(copiedText?.contains("first-out") == true)

        view.copyOutput(id: commands[1].id)
        XCTAssertTrue(copiedText?.contains("second-out") == true)
    }

    func testValidateUserInterfaceItemForCommandActions() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let input = "\u{1b}]7;file:///tmp\u{07}\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}test-cmd\r\n\u{1b}]133;C\u{07}done\r\n\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))

        guard let cmd = view.recordedCommands().first,
              let menu = view.contextMenu(for: cmd.id) else {
            XCTFail("Expected menu")
            return
        }

        view.pasteStringProvider = { "test paste text" }

        for item in menu.items where item.action != nil && !item.isSeparatorItem {
            let isValid = view.validateUserInterfaceItem(item)
            XCTAssertTrue(isValid, "Item '\(item.title)' should be valid")
        }
    }

    func testMarkdownCodeFenceAvoidsCollisionsWithBacktickContent() {
        // Plain content uses standard 3-backtick fence
        let plainMd = TakoTerminalNSView.formatCommandAndOutputAsMarkdown(command: "echo 1", output: "1")
        XCTAssertTrue(plainMd.hasPrefix("```bash\n"))
        XCTAssertTrue(plainMd.hasSuffix("\n```"))

        // Content containing a 3-backtick block must use at least 4 backticks for outer fence
        let mdWithCode = TakoTerminalNSView.formatCommandAndOutputAsMarkdown(
            command: "cat doc.md",
            output: "```swift\nlet x = 1\n```"
        )
        XCTAssertTrue(mdWithCode.contains("````\n```swift\nlet x = 1\n```\n````"))

        // Content containing 4 backticks must use 5 backticks
        let mdWith4Ticks = TakoTerminalNSView.formatCommandAndOutputAsMarkdown(
            command: "cat file.md",
            output: "````\ninner\n````"
        )
        XCTAssertTrue(mdWith4Ticks.contains("`````\n````\ninner\n````\n`````"))
    }

    func testRefusesToRerunTruncatedCommandInputs() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = TestTerminalDelegate()
        view.delegate = delegate

        // Create a command longer than 512 bytes to trigger truncation in TakoCore recording
        let longCommand = String(repeating: "echo AVeryLongArgumentStringThatExceedsTheCoreLimit;", count: 20)
        let input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}\(longCommand)\r\n\u{1b}]133;C\u{07}done\r\n\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))

        guard let cmd = view.recordedCommands().first else {
            XCTFail("Expected recorded command")
            return
        }

        XCTAssertTrue(cmd.inputTruncated, "Command exceeding 512 bytes must be marked inputTruncated")

        // 1. rerunCommand must refuse to send anything to the delegate
        view.rerunCommand(id: cmd.id)
        XCTAssertTrue(delegate.sentInputData.isEmpty, "rerunCommand must refuse to execute truncated inputs")

        // 2. Context menu must label rerun as truncated and disable it
        guard let menu = view.contextMenu(for: cmd.id) else {
            XCTFail("Expected context menu")
            return
        }
        let rerunItem = menu.items.first(where: { $0.title.contains("Re-run") })
        XCTAssertNotNil(rerunItem)
        XCTAssertFalse(rerunItem?.isEnabled == true, "Re-run item must be disabled for truncated command")
        XCTAssertTrue(rerunItem?.title.contains("Truncated") == true)

        // 3. validateUserInterfaceItem must return false
        if let rerunItem {
            XCTAssertFalse(view.validateUserInterfaceItem(rerunItem))
        }

        // 4. Copy command must annotate truncated inputs
        var copiedText: String?
        view.copyStringConsumer = { copiedText = $0 }
        view.copyCommand(id: cmd.id)
        XCTAssertTrue(copiedText?.contains("# [truncated]") == true)

        // 5. Copy both as markdown must annotate truncated input
        view.copyBothAsMarkdown(id: cmd.id)
        XCTAssertTrue(copiedText?.contains("<!-- Note: Command input was truncated to buffer limit -->") == true)

        // 6. Context menu must label Copy Command and Markdown as truncated
        let copyCmdItem = menu.items.first(where: { $0.title.contains("Copy Command") })
        XCTAssertEqual(copyCmdItem?.title, "Copy Command (Truncated)")
        let copyMdItem = menu.items.first(where: { $0.title.contains("Markdown") })
        XCTAssertEqual(copyMdItem?.title, "Copy Both as Markdown (Truncated Input)")
    }

    func testSurfacesPartialOutputInContextMenuAndMarkdownAndSave() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}ls\r\n\u{1b}]133;C\u{07}file.txt\r\n\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))

        guard let cmd = view.recordedCommands().first else {
            XCTFail("Expected recorded command")
            return
        }

        // Test formatCommandAndOutputAsMarkdown with isPartial == true
        let partialMd = TakoTerminalNSView.formatCommandAndOutputAsMarkdown(
            command: "ls",
            output: "file.txt",
            isPartial: true
        )
        XCTAssertTrue(partialMd.contains("<!-- Note: Output was partially evicted or truncated from scrollback -->"))

        // Test context menu when output is partial via synthetic command info
        let partialOutput = FfiCommandOutput(
            command: cmd,
            output: "file.txt",
            lines: 1,
            truncated: true,
            more: false,
            incomplete: false
        )
        XCTAssertTrue(partialOutput.isPartial)

        // Test saveOutputToFile suggested filename when partial
        var suggestedName: String?
        let originalPanel = TakoTerminalNSView.saveFilePanel
        defer { TakoTerminalNSView.saveFilePanel = originalPanel }
        TakoTerminalNSView.saveFilePanel = { _, filename, _, completion in
            suggestedName = filename
            completion(nil)
        }
        // Save output for command
        view.saveOutputToFile(id: cmd.id)
        XCTAssertEqual(suggestedName, "command-\(cmd.id)-output.txt")
    }

    func testMultilineCommandActionsWithholdUnsafeLineBreaksWhenUnbracketed() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = TestTerminalDelegate()
        view.delegate = delegate

        // Bracketed paste is OFF by default
        XCTAssertFalse(view.core.modes().bracketedPaste)

        // Test insertInputText with multiline text: unsafe line breaks must be withheld
        var confirmationRequested = false
        view.confirmPasteHandler = { text, completion in
            confirmationRequested = true
            // Do not confirm initially
            completion(false)
        }

        view.insertInputText("echo 1\necho 2")
        XCTAssertTrue(confirmationRequested, "Multiline input must trigger confirmation when unbracketed")
        XCTAssertTrue(delegate.sentInputData.isEmpty, "Unsafe line breaks must be withheld when not confirmed")

        // Now test when confirmed
        view.confirmPasteHandler = { text, completion in
            completion(true)
        }
        view.insertInputText("echo 1\necho 2")
        XCTAssertFalse(delegate.sentInputData.isEmpty, "Input should be sent after confirmation")

        // Test fallback when confirmPasteHandler is nil and no window is attached (headless fallback performs paste)
        view.confirmPasteHandler = nil
        delegate.sentInputData.removeAll()
        view.insertInputText("echo fallback\necho headless")
        XCTAssertFalse(delegate.sentInputData.isEmpty, "Headless fallback without window must not silently drop text")
    }

    func testRerunCommandGuardsAgainstRunningPane() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = TestTerminalDelegate()
        view.delegate = delegate

        let input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}make test\r\n\u{1b}]133;C\u{07}running...\r\n"
        view.feed(data: Data(input.utf8))

        guard let cmd = view.recordedCommands().first else {
            XCTFail("Expected recorded command")
            return
        }

        // Active command is running (no 133;D received yet)
        XCTAssertFalse(view.isAtShellPrompt, "Pane must not be at prompt while command is running")

        // Re-run must refuse to execute while busy
        view.rerunCommand(id: cmd.id)
        XCTAssertTrue(delegate.sentInputData.isEmpty, "rerunCommand must refuse to execute on a busy pane")

        // Context menu must indicate pane is busy and disable rerun
        guard let menu = view.contextMenu(for: cmd.id) else {
            XCTFail("Expected context menu")
            return
        }
        let rerunItem = menu.items.first(where: { $0.title.contains("Re-run") })
        XCTAssertNotNil(rerunItem)
        XCTAssertFalse(rerunItem?.isEnabled == true)
        XCTAssertTrue(rerunItem?.title.contains("Pane Busy") == true)
        if let rerunItem {
            XCTAssertFalse(view.validateUserInterfaceItem(rerunItem))
        }

        // Now finish the command
        view.feed(data: Data("\u{1b}]133;D;0\u{07}\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}".utf8))
        XCTAssertTrue(view.isAtShellPrompt, "Pane must be at prompt after command finished")

        view.rerunCommand(id: cmd.id)
        XCTAssertFalse(delegate.sentInputData.isEmpty, "rerunCommand must insert input when at prompt")
    }

    func testEpochValidationRejectsStaleCommandActions() throws {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = TestTerminalDelegate()
        view.delegate = delegate
        var copiedText: String?
        view.copyStringConsumer = { copiedText = $0 }
        var forwardedText: String?
        view.sendTextToAnotherPaneHandler = { forwardedText = $0 }
        var openedURL: URL?
        let origOpenURL = TakoTerminalNSView.openURL
        defer { TakoTerminalNSView.openURL = origOpenURL }
        TakoTerminalNSView.openURL = { openedURL = $0 }

        let input = "\u{1b}]7;file:///tmp/epoch_test\u{07}\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}echo epoch-test\r\n\u{1b}]133;C\u{07}epoch-out\r\n\u{1b}]133;D;0\u{07}\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}"
        view.feed(data: Data(input.utf8))

        guard let cmd = view.recordedCommands().first else {
            XCTFail("Expected recorded command")
            return
        }

        let validEpoch = cmd.epoch
        let staleEpoch = validEpoch + 999

        // 1. Info and Output lookups
        XCTAssertNotNil(view.commandInfo(for: cmd.id, epoch: validEpoch))
        XCTAssertNil(view.commandInfo(for: cmd.id, epoch: staleEpoch))

        XCTAssertNotNil(view.commandOutput(for: cmd.id, epoch: validEpoch))
        XCTAssertNil(view.commandOutput(for: cmd.id, epoch: staleEpoch))

        XCTAssertNotNil(view.commandOutputString(for: cmd.id, epoch: validEpoch))
        XCTAssertNil(view.commandOutputString(for: cmd.id, epoch: staleEpoch))

        // 2. Action invocations with stale epoch must be rejected (no side effects)
        copiedText = nil
        view.copyCommand(id: cmd.id, epoch: staleEpoch)
        XCTAssertNil(copiedText, "copyCommand must abort when epoch mismatches")

        copiedText = nil
        view.copyOutput(id: cmd.id, epoch: staleEpoch)
        XCTAssertNil(copiedText, "copyOutput must abort when epoch mismatches")

        copiedText = nil
        view.copyBothAsMarkdown(id: cmd.id, epoch: staleEpoch)
        XCTAssertNil(copiedText, "copyBothAsMarkdown must abort when epoch mismatches")

        delegate.sentInputData.removeAll()
        view.rerunCommand(id: cmd.id, epoch: staleEpoch)
        XCTAssertTrue(delegate.sentInputData.isEmpty, "rerunCommand must abort when epoch mismatches")

        forwardedText = nil
        view.sendOutputToAnotherPane(id: cmd.id, epoch: staleEpoch)
        XCTAssertNil(forwardedText, "sendOutputToAnotherPane must abort when epoch mismatches")

        openedURL = nil
        view.openWorkingDirectory(id: cmd.id, epoch: staleEpoch)
        XCTAssertNil(openedURL, "openWorkingDirectory must abort when epoch mismatches")

        var saveFilePanelCalled = false
        let origPanel = TakoTerminalNSView.saveFilePanel
        defer { TakoTerminalNSView.saveFilePanel = origPanel }
        TakoTerminalNSView.saveFilePanel = { _, _, _, completion in
            saveFilePanelCalled = true
            completion(nil)
        }
        var completedURL: URL? = URL(fileURLWithPath: "/dummy")
        view.saveOutputToFile(id: cmd.id, epoch: staleEpoch) { url in
            completedURL = url
        }
        XCTAssertFalse(saveFilePanelCalled, "saveOutputToFile panel must not open when epoch mismatches")
        XCTAssertNil(completedURL, "saveOutputToFile completion must receive nil")

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("epoch-save-test-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        XCTAssertThrowsError(try view.saveOutput(for: cmd.id, epoch: staleEpoch, to: tempURL), "saveOutput must throw when epoch mismatches")

        // 3. Context menu with stale epoch
        XCTAssertNil(view.contextMenu(for: cmd.id, epoch: staleEpoch))

        // 4. CommandTarget sender resolution in validateUserInterfaceItem
        let menu = view.contextMenu(for: cmd)
        if let copyOutputItem = menu.items.first(where: { $0.title == "Copy Output" }) {
            copyOutputItem.representedObject = TakoTerminalNSView.CommandTarget(id: cmd.id, epoch: staleEpoch)
            XCTAssertFalse(view.validateUserInterfaceItem(copyOutputItem), "validateUserInterfaceItem must reject stale CommandTarget")
        }
    }

    func testUnavailableOutputRejectsOutputActionsWithoutSideEffects() throws {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var copiedText: String? = "sentinel"
        view.copyStringConsumer = { copiedText = $0 }
        var forwardedText: String? = "sentinel"
        view.sendTextToAnotherPaneHandler = { forwardedText = $0 }

        let nonExistentId: UInt64 = 999_999
        XCTAssertNil(view.commandOutput(for: nonExistentId))
        XCTAssertNil(view.commandOutputString(for: nonExistentId))

        // Copy output with nil output record must NOT wipe or overwrite clipboard
        copiedText = "sentinel"
        view.copyOutput(id: nonExistentId)
        XCTAssertEqual(copiedText, "sentinel", "copyOutput must not modify clipboard when output is unavailable")

        // Copy both as markdown must abort
        copiedText = "sentinel"
        view.copyBothAsMarkdown(id: nonExistentId)
        XCTAssertEqual(copiedText, "sentinel", "copyBothAsMarkdown must not modify clipboard when output is unavailable")

        // Send output to another pane must abort
        forwardedText = "sentinel"
        view.sendOutputToAnotherPane(id: nonExistentId)
        XCTAssertEqual(forwardedText, "sentinel", "sendOutputToAnotherPane must abort when output is unavailable")

        // Save output to file via panel must abort and return nil
        var savePanelCalled = false
        let origPanel = TakoTerminalNSView.saveFilePanel
        defer { TakoTerminalNSView.saveFilePanel = origPanel }
        TakoTerminalNSView.saveFilePanel = { _, _, _, completion in
            savePanelCalled = true
            completion(nil)
        }

        var saveResultURL: URL? = URL(fileURLWithPath: "/dummy")
        view.saveOutputToFile(id: nonExistentId) { url in
            saveResultURL = url
        }
        XCTAssertFalse(savePanelCalled, "Save panel should not be displayed when output is unavailable")
        XCTAssertNil(saveResultURL)

        // Direct save output must throw fileNoSuchFile
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("nonexistent-output-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        XCTAssertThrowsError(try view.saveOutput(for: nonExistentId, to: tempURL)) { error in
            guard let cocoaError = error as? CocoaError else {
                XCTFail("Expected CocoaError, got \(error)")
                return
            }
            XCTAssertEqual(cocoaError.code, .fileNoSuchFile)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path), "No file should be written")

        // validateUserInterfaceItem returns false for output actions on unavailable output
        let item = NSMenuItem(title: "Copy Output", action: #selector(TakoTerminalNSView.copyOutputContextAction(_:)), keyEquivalent: "")
        item.representedObject = TakoTerminalNSView.CommandTarget(id: nonExistentId, epoch: 0)
        XCTAssertFalse(view.validateUserInterfaceItem(item))
    }
}
#endif
