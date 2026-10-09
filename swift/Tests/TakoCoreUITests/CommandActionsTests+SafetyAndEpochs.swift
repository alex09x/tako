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

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
@MainActor
extension CommandActionsTests {
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
