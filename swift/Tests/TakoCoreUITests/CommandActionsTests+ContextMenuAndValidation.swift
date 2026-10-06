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
import XCTest
@testable import TakoCoreUI

@MainActor
extension CommandActionsTests {
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


}
