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
        #expect(buttons.map(\.title) == ["Terminate", "Cancel"])
        buttons[1].performClick(nil)
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
}
