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
}

