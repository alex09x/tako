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

        // Verify representedObject on items is cmd.id
        let actionTitles = [
            "Copy Command", "Copy Output", "Copy Both as Markdown",
            "Re-run in This Pane", "Send Output to Another Pane", "Save Output to File…",
            "Open Working Directory"
        ]
        for title in actionTitles {
            let item = menu.items.first(where: { $0.title == title })
            XCTAssertEqual(item?.representedObject as? UInt64, cmd.id, "Item '\(title)' must carry command ID")
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
        XCTAssertEqual(copyCmdItem?.representedObject as? UInt64, stickyHeader?.commandId)
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

        for item in menu.items where item.action != nil && !item.isSeparatorItem {
            let isValid = view.validateUserInterfaceItem(item)
            XCTAssertTrue(isValid, "Item '\(item.title)' should be valid")
        }
    }
}
#endif
