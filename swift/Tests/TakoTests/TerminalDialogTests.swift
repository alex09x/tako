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
import Foundation
import Testing
@testable import Tako

/// The confirmation drawn in the terminal window: keys answer it, its buttons
/// are buttons, and it can be withdrawn.
@MainActor
struct TerminalDialogTests {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        return window
    }

    private func key(_ code: UInt16, _ characters: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    /// Asks, presses `keys` once the question is up, and returns the answer.
    private func answer(after keys: [NSEvent]) async -> Bool? {
        let window = window()
        let asked = Task { await TerminalDialogView.ask(in: window, title: "Close Terminal?",
                                                        message: "A process is running.", confirm: "Close",
                                                        theme: nil) }
        while TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        let dialog = TerminalDialogView.pending(in: window)!
        for event in keys { dialog.keyDown(with: event) }
        let result = await asked.value
        #expect(TerminalDialogView.pending(in: window) == nil)
        return result
    }

    @Test func returnConfirmsTheChosenButtonWhichStartsAsTheFirst() async {
        #expect(await answer(after: [key(36, "\r")]) == true)
    }

    @Test func escapeAndNCancel() async {
        #expect(await answer(after: [key(53)]) == false)
        #expect(await answer(after: [key(45, "n")]) == false)
    }

    @Test func tabMovesToCancelAndBackAndYConfirms() async {
        #expect(await answer(after: [key(48, "\t"), key(36, "\r")]) == false)
        #expect(await answer(after: [key(48, "\t"), key(124), key(36, "\r")]) == true)
        #expect(await answer(after: [key(48, "\t"), key(16, "y")]) == true)
    }

    @Test func itsButtonsAreButtonsThatAnswer() async {
        let window = window()
        let asked = Task { await TerminalDialogView.ask(in: window, title: "Quit Tako?", message: "m",
                                                        confirm: "Terminate", theme: nil) }
        while TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        let buttons = TerminalDialogView.pending(in: window)!.subviews.compactMap { $0 as? NSButton }
        // The safe choice on the left, the destructive one on the right.
        #expect(buttons.map(\.title) == ["Cancel", "Terminate"])
        buttons[0].performClick(nil)
        #expect(await asked.value == false)
    }

    @Test func aWithdrawnQuestionIsACancel() async {
        let window = window()
        let asked = Task { await TerminalDialogView.ask(in: window, title: "t", message: "m",
                                                        confirm: "Close", theme: nil) }
        while TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        TerminalDialogView.pending(in: window)!.withdraw()
        #expect(await asked.value == false)
        #expect(TerminalDialogView.pending(in: window) == nil)
    }

    @Test func aSecondCloseWhileTheQuestionIsUpClosesNothing() async {
        let (controller, window) = TerminalTestSupport.makeController()
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        defer { TerminalTestSupport.tearDown(controller, window) }
        var closed = 0
        controller.confirmClose(messageText: "Close Terminal?", informativeText: "m") { closed += 1 }
        while TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        // Another ⌘W while the first is unanswered.
        controller.confirmClose(messageText: "Close Terminal?", informativeText: "m") { closed += 1 }
        for _ in 0..<50 { await Task.yield() }
        #expect(closed == 0)
        #expect(TerminalDialogView.pending(in: window) != nil)
        // The first question's answer is the only one that counts.
        TerminalDialogView.pending(in: window)!.keyDown(with: key(36, "\r"))
        for _ in 0..<50 where closed == 0 { await Task.yield() }
        #expect(closed == 1)
    }

    @Test func releaseNotesBecomeStyledWrappedLines() {
        let notes = "## New\n\n- **Find in All Tabs** (Cmd+Shift+F) searches `every` tab, see [docs](https://x).\n\nPlain."
        let lines = TUIText.markdown(notes, width: 30, maxLines: 20)
        #expect(lines.first?.runs == [TUIText.Run(text: "New", kind: .heading)])
        #expect(lines[2].runs.first == TUIText.Run(text: "• ", kind: .bullet))
        #expect(lines[2].runs.contains(TUIText.Run(text: "Find in All Tabs", kind: .bold)))
        let all = lines.flatMap(\.runs)
        #expect(all.contains(TUIText.Run(text: "every", kind: .code)))
        #expect(all.contains(TUIText.Run(text: "docs", kind: .link)))
        #expect(lines.allSatisfy { $0.width <= 30 })
        // A wrapped bullet continues under its text, not under the bullet.
        #expect(lines[3].indent == 2)
    }

    @Test func longNotesStopWithAPointerToTheRest() {
        let notes = (1...40).map { "- item \($0)" }.joined(separator: "\n")
        let lines = TUIText.markdown(notes, width: 40, maxLines: 10)
        #expect(lines.count == 10)
        #expect(lines.last?.runs.first?.kind == .muted)
    }

    @Test func aLongBodyScrollsByKeysAndStopsAtItsEnds() async {
        let window = window()
        let lines = (1...60).map { TUIText.Line(runs: [TUIText.Run(text: "line \($0)", kind: .plain)]) }
        let asked = Task { await TerminalDialogView.choose(in: window, title: "Notes", lines: lines,
                                                           choices: [.init(title: "OK", kind: .primary)],
                                                           cancelIndex: 0, theme: nil) }
        while TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        let dialog = TerminalDialogView.pending(in: window)!
        dialog.layoutSubtreeIfNeeded()
        #expect(dialog.scrollOffset == 0)
        dialog.keyDown(with: key(125))                       // down
        #expect(dialog.scrollOffset == 1)
        dialog.keyDown(with: key(126)); dialog.keyDown(with: key(126))   // up past the top
        #expect(dialog.scrollOffset == 0)
        dialog.keyDown(with: key(119))                       // end
        let end = dialog.scrollOffset
        #expect(end > 0 && end < 60)
        dialog.keyDown(with: key(121))                       // page down past the end
        #expect(dialog.scrollOffset == end)
        dialog.keyDown(with: key(116))                       // page up
        #expect(dialog.scrollOffset < end)
        dialog.withdraw()
        _ = await asked.value
    }

    @Test func aWordLongerThanALineIsSplitNotDropped() {
        let hash = String(repeating: "0123456789abcdef", count: 5)   // 80 characters
        let lines = TUIText.wrap([TUIText.Run(text: "commit \(hash) done", kind: .code)], width: 30)
        #expect(lines.allSatisfy { $0.width <= 30 })
        let text = lines.map { $0.runs.map(\.text).joined() }.joined()
        #expect(text.replacingOccurrences(of: " ", with: "") == "commit\(hash)done")
    }

    @Test func anUpdateNoticeGoesToATerminalWindowNotSettings() {
        let settings = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
                                backing: .buffered, defer: true)
        let (controller, terminal) = TerminalTestSupport.makeController()
        defer { TerminalTestSupport.tearDown(controller, terminal) }
        terminal.orderFront(nil)
        #expect(AppUpdater.noticeWindow(key: settings, windows: [settings, terminal]) === terminal)
        #expect(AppUpdater.noticeWindow(key: terminal, windows: [settings, terminal]) === terminal)
        #expect(AppUpdater.noticeWindow(key: settings, windows: [settings]) == nil)
    }

    @Test func aQuestionDescribesItselfAndAButtonCanBePressedByName() async {
        let window = window()
        let asked = Task { await TerminalDialogView.ask(in: window, title: "Quit Tako?", message: "A process runs.",
                                                        confirm: "Terminate", theme: nil) }
        while TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        let dialog = TerminalDialogView.pending(in: window)!
        #expect(dialog.summary["title"] == .string("Quit Tako?"))
        #expect(dialog.summary["text"] == .string("A process runs."))
        #expect(dialog.summary["buttons"] == .array([.string("Cancel"), .string("Terminate")]))
        #expect(dialog.summary["selected"] == .string("Terminate"))
        #expect(!dialog.press("Nope"))
        #expect(TerminalDialogView.pending(in: window) != nil)
        #expect(dialog.press("cancel"))
        #expect(await asked.value == false)
    }

    @Test func aTextQuestionAnswersWhatWasTypedOrNothing() async {
        let window = window()
        let asked = Task { await TerminalDialogView.askText(in: window, title: "Rename Tab", label: "Title",
                                                            value: "old", hint: nil, confirm: "Save", theme: nil) }
        while TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        let dialog = TerminalDialogView.pending(in: window)!
        let field = (dialog.field ?? dialog.subviews.compactMap { $0 as? NSTextField }.first(where: { $0.isEditable }))!
        #expect(field.stringValue == "old")
        field.stringValue = "build logs"
        #expect(dialog.press("Save"))
        #expect(await asked.value == "build logs")

        let cancelled = Task { await TerminalDialogView.askText(in: window, title: "Rename Tab", label: "Title",
                                                                value: "x", hint: nil, confirm: "Save", theme: nil) }
        while TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        TerminalDialogView.pending(in: window)!.withdraw()
        #expect(await cancelled.value == nil)
    }

    @Test func returnInTheFieldPressesTheButtonShownAsChosen() async {
        let window = window()
        let asked = Task { await TerminalDialogView.askText(in: window, title: "Rename Tab", label: "Title",
                                                            value: "x", hint: nil, confirm: "Save", theme: nil) }
        while TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        let dialog = TerminalDialogView.pending(in: window)!
        let field = (dialog.field ?? dialog.subviews.compactMap { $0 as? NSTextField }.first(where: { $0.isEditable }))!
        let editor = NSTextView()
        #expect(dialog.summary["selected"] == .string("Save"))
        _ = dialog.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:)))
        #expect(dialog.summary["selected"] == .string("Cancel"))
        _ = dialog.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(await asked.value == nil)
    }

    @Test func windowCloseCancelsPendingDialogContinuation() async {
        let window = window()
        let asked = Task {
            await TerminalDialogView.ask(
                in: window,
                title: "Grant Access?",
                message: "A remote client requested access.",
                confirm: "Allow",
                cancel: "Deny",
                destructive: false,
                theme: nil
            )
        }
        while TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        #expect(TerminalDialogView.pending(in: window) != nil)

        // Close the window while the dialog is awaiting input
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)

        let result = await asked.value
        #expect(result == false)
        #expect(TerminalDialogView.pending(in: window) == nil)
    }

    @Test func viewRemovalCancelsPendingDialogContinuation() async {
        let window = window()
        let asked = Task {
            await TerminalDialogView.choose(
                in: window,
                title: "Choose Action",
                lines: TUIText.plain("Select an option", width: 40),
                choices: [.init(title: "Cancel", kind: .normal), .init(title: "Execute", kind: .primary)],
                selected: 1,
                cancelIndex: 0,
                theme: nil
            )
        }
        while TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        let dialog = TerminalDialogView.pending(in: window)!

        // Remove the view from hierarchy without answering
        dialog.removeFromSuperview()

        let result = await asked.value
        #expect(result == 0)
        #expect(TerminalDialogView.pending(in: window) == nil)
    }

    @Test func windowCloseCancelsPendingAskTextContinuation() async {
        let window = window()
        let asked = Task {
            await TerminalDialogView.askText(
                in: window,
                title: "New Workspace",
                label: "Name:",
                value: "test",
                hint: nil,
                confirm: "Create",
                cancel: "Cancel",
                theme: nil
            )
        }
        while TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        #expect(TerminalDialogView.pending(in: window) != nil)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)

        let result = await asked.value
        #expect(result == nil)
        #expect(TerminalDialogView.pending(in: window) == nil)
    }

    @Test func configureTerminalDialogHandlersReplacesNSAlertWithInTerminalDialogs() async {
        let prevConfirm = TakoTerminalNSView.confirmOpenURL
        let prevAlert = TakoTerminalNSView.presentAlert
        defer {
            TakoTerminalNSView.confirmOpenURL = prevConfirm
            TakoTerminalNSView.presentAlert = prevAlert
        }

        AppDelegate.configureTerminalDialogHandlers()
        let window = window()

        // 1. unsafeScheme -> "Open External Application?", default "Open" (index 1), Return confirms (true)
        var unsafeOutcome: Bool?
        TakoTerminalNSView.confirmOpenURL(
            URL(string: "ssh://prod.codes")!,
            .unsafeScheme("ssh"),
            window
        ) { unsafeOutcome = $0 }
        while TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        let unsafeDialog = TerminalDialogView.pending(in: window)!
        #expect(window.attachedSheet == nil)
        #expect(unsafeDialog.title == "Open External Application?")
        #expect(unsafeDialog.subviews.compactMap { $0 as? NSButton }.map(\.title) == ["Cancel", "Open"])
        unsafeDialog.keyDown(with: key(36, "\r"))
        while unsafeOutcome == nil { await Task.yield() }
        #expect(unsafeOutcome == true)

        // 2. urlMismatch -> "Suspicious Link Destination", default "Cancel" (index 0), Return cancels (false)
        var mismatchOutcome: Bool?
        TakoTerminalNSView.confirmOpenURL(
            URL(string: "https://evil.example")!,
            .urlMismatch(displayedText: "https://trusted.example", targetURL: URL(string: "https://evil.example")!),
            window
        ) { mismatchOutcome = $0 }
        while TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        let mismatchDialog = TerminalDialogView.pending(in: window)!
        #expect(window.attachedSheet == nil)
        #expect(mismatchDialog.title == "Suspicious Link Destination")
        #expect(mismatchDialog.subviews.compactMap { $0 as? NSButton }.map(\.title) == ["Cancel", "Open Anyway"])
        mismatchDialog.keyDown(with: key(36, "\r"))
        while mismatchOutcome == nil { await Task.yield() }
        #expect(mismatchOutcome == false)

        // 3. unconfirmedDestination -> "Open Link?", Escape cancels (false)
        var unconfirmedOutcome: Bool?
        TakoTerminalNSView.confirmOpenURL(
            URL(string: "https://prod.codes/docs")!,
            .unconfirmedDestination(URL(string: "https://prod.codes/docs")!),
            window
        ) { unconfirmedOutcome = $0 }
        while TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        let unconfirmedDialog = TerminalDialogView.pending(in: window)!
        #expect(window.attachedSheet == nil)
        #expect(unconfirmedDialog.title == "Open Link?")
        #expect(unconfirmedDialog.subviews.compactMap { $0 as? NSButton }.map(\.title) == ["Cancel", "Open"])
        unconfirmedDialog.keyDown(with: key(53, "\u{1B}"))
        while unconfirmedOutcome == nil { await Task.yield() }
        #expect(unconfirmedOutcome == false)

        // 4. presentAlert -> in-terminal "OK" dialog instead of NSAlert sheet
        let alert = NSAlert()
        alert.messageText = "Terminal Alert Title"
        alert.informativeText = "Detailed terminal notice."
        TakoTerminalNSView.presentAlert(alert, window)
        while TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        let alertDialog = TerminalDialogView.pending(in: window)!
        #expect(window.attachedSheet == nil)
        #expect(alertDialog.title == "Terminal Alert Title")
        #expect(alertDialog.subviews.compactMap { $0 as? NSButton }.map(\.title) == ["OK"])
        alertDialog.keyDown(with: key(36, "\r"))
        while TerminalDialogView.pending(in: window) != nil { await Task.yield() }
        #expect(TerminalDialogView.pending(in: window) == nil)
    }
}

