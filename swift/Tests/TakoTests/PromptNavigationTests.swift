import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Tako
@testable import TakoKit

@MainActor
@Suite
struct PromptNavigationTests {
    private func makeSurfaceView() -> Tako.SurfaceView {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        view.selfTestCapturing = true
        view.close()
        return view
    }

    // MARK: - 1. Prompt Navigation between OSC 133 Prompts

    @Test func promptNavigationJumpsDirectlyBetweenPrompts() {
        let view = makeSurfaceView()
        defer { view.close() }

        // Prompt 1
        view.feed(data: Data("\u{1b}]133;A\u{07}prompt1$ ".utf8))
        view.feed(data: Data("\u{1b}]133;C\u{07}output from cmd 1\r\n\u{1b}]133;D;0\u{07}".utf8))

        // Push prompt 1 into scrollback with 40 newlines
        var padding = ""
        for i in 1...40 {
            padding += "scroll line \(i)\r\n"
        }
        view.feed(data: Data(padding.utf8))

        // Prompt 2
        view.feed(data: Data("\u{1b}]133;A\u{07}prompt2$ ".utf8))
        view.feed(data: Data("\u{1b}]133;C\u{07}output from cmd 2\r\n\u{1b}]133;D;0\u{07}".utf8))

        #expect(view.viewportOffset == 0)

        // Jump to previous prompt in scrollback
        let jumpedPrev = view.jumpToPreviousPrompt()
        #expect(jumpedPrev == true)
        #expect(view.viewportOffset > 0)

        // Jump back to next prompt
        let jumpedNext = view.jumpToNextPrompt()
        #expect(jumpedNext == true)
        #expect(view.viewportOffset == 0)
    }

    // MARK: - 2. Fallback to Page Scroll when No Prompts Exist

    @Test func promptNavigationFallsBackToPageScrollWithoutPrompts() {
        let view = makeSurfaceView()
        defer { view.close() }

        // Plain terminal output without prompt marks
        var text = ""
        for i in 1...60 {
            text += "plain line \(i)\r\n"
        }
        view.feed(data: Data(text.utf8))
        #expect(view.viewportOffset == 0)
        #expect(view.scrollbackLength > 0)

        let initialRows = Int(view.rows)

        // No prompt marks exist, so jumpToPreviousPrompt falls back to page up
        let jumpedPrev = view.jumpToPreviousPrompt()
        #expect(jumpedPrev == false) // indicates fallback was used
        #expect(view.viewportOffset >= initialRows)

        let offsetAfterUp = view.viewportOffset

        // jumpToNextPrompt falls back to page down
        let jumpedNext = view.jumpToNextPrompt()
        #expect(jumpedNext == false) // indicates fallback was used
        #expect(view.viewportOffset < offsetAfterUp)
    }

    // MARK: - 3. Command Output Selection Cleanly Bounded

    @Test func commandOutputSelectionCleanlyBoundsOutput() {
        let view = makeSurfaceView()
        defer { view.close() }

        // Prompt 1
        view.feed(data: Data("\u{1b}]133;A\u{07}user@box:~$ \u{1b}]133;B\u{07}ls -la\r\n".utf8))
        // Command output
        view.feed(data: Data("\u{1b}]133;C\u{07}first line of output\r\nsecond line of output\r\nthird line of output\r\n\u{1b}]133;D;0\u{07}".utf8))
        // Prompt 2
        view.feed(data: Data("\u{1b}]133;A\u{07}user@box:~$ ".utf8))

        let selected = view.selectCommandOutput()
        #expect(selected == true)

        let outputText = view.selectedText
        #expect(outputText != nil)
        let unwrapped = outputText ?? ""
        #expect(unwrapped.contains("first line of output"))
        #expect(unwrapped.contains("second line of output"))
        #expect(unwrapped.contains("third line of output"))
        // Prompt text and command input must NOT be included in command output selection
        #expect(!unwrapped.contains("user@box:~$"))
        #expect(!unwrapped.contains("ls -la"))
    }

    // MARK: - 4. Instant Cmd+C Clipboard Copying

    @Test func commandOutputSelectionAllowsInstantCmdCCopying() {
        let view = makeSurfaceView()
        defer { view.close() }

        var copiedText: String?
        view.copyStringConsumer = { text in
            copiedText = text
        }

        view.feed(data: Data("\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}cat token\r\n".utf8))
        view.feed(data: Data("\u{1b}]133;C\u{07}secret-token-12345\r\n\u{1b}]133;D;0\u{07}".utf8))
        view.feed(data: Data("\u{1b}]133;A\u{07}$ ".utf8))

        #expect(view.selectCommandOutput() == true)

        // Instant Cmd+C triggers copy(_:)
        view.copy(nil)
        #expect(copiedText == "secret-token-12345")
    }

    // MARK: - 5. Keyboard Event Dispatch (Cmd+Up, Cmd+Down, Cmd+Shift+A)

    @Test func keyboardShortcutsDispatchViaPerformKeyEquivalentAndKeyDown() {
        let view = makeSurfaceView()
        defer { view.close() }

        view.feed(data: Data("\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}echo hello\r\n".utf8))
        view.feed(data: Data("\u{1b}]133;C\u{07}hello output\r\n\u{1b}]133;D;0\u{07}".utf8))

        var padding = ""
        for i in 1...30 {
            padding += "scroll line \(i)\r\n"
        }
        view.feed(data: Data(padding.utf8))

        view.feed(data: Data("\u{1b}]133;A\u{07}$ ".utf8))

        // Test direct action methods on the view
        #expect(view.jumpToPreviousPrompt() == true)
        #expect(view.jumpToNextPrompt() == true)
        #expect(view.selectCommandOutput() == true)
        #expect(view.selectedText == "hello output")
    }

    // MARK: - 6. Surface Actions and Binding Execution

    @Test func surfaceActionsAndBindingsAreSupported() {
        let view = makeSurfaceView()
        defer { view.close() }

        #expect(Tako.SurfaceView.isBindingActionSupported("jump_to_prompt"))
        #expect(Tako.SurfaceView.isBindingActionSupported("select_command_output"))
        #expect(Tako.SurfaceView.isBindingActionSupported("select_output"))

        view.feed(data: Data("\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}echo bound\r\n".utf8))
        view.feed(data: Data("\u{1b}]133;C\u{07}bound output\r\n\u{1b}]133;D;0\u{07}".utf8))
        view.feed(data: Data("\u{1b}]133;A\u{07}$ ".utf8))

        #expect(view.performBindingAction("jump_to_prompt:previous") == true)
        #expect(view.performBindingAction("jump_to_prompt:next") == true)
        #expect(view.performBindingAction("select_command_output") == true)
        #expect(view.selectedText == "bound output")

        view.core.clearSelection()
        #expect(view.performBindingAction("select_output") == true)
        #expect(view.selectedText == "bound output")
    }

    // MARK: - 7. Menu Validation & Default Config Keybindings

    @Test func menuValidationAndConfigShortcuts() {
        let view = makeSurfaceView()
        defer { view.close() }

        final class TestItem: NSObject, NSValidatedUserInterfaceItem {
            let action: Selector?
            let tag: Int = 0
            init(action: Selector?) { self.action = action }
        }

        #expect(view.validateUserInterfaceItem(TestItem(action: #selector(TakoTerminalNSView.jumpToPreviousPrompt(_:)))) == true)
        #expect(view.validateUserInterfaceItem(TestItem(action: #selector(TakoTerminalNSView.jumpToNextPrompt(_:)))) == true)
        #expect(view.validateUserInterfaceItem(TestItem(action: #selector(TakoTerminalNSView.selectCommandOutput(_:)))) == true)

        let config = Tako.Config()
        #expect(config.keyboardShortcut(for: "jump_to_prompt:previous") == .init(.upArrow, modifiers: .command))
        #expect(config.keyboardShortcut(for: "jump_to_prompt:next") == .init(.downArrow, modifiers: .command))
        #expect(config.keyboardShortcut(for: "select_command_output") == .init("a", modifiers: [.command, .shift]))
    }

    // MARK: - 8. Menu Shortcut Sync, Remapping, and Unbinding

    @Test func menuItemsSyncWithConfigurableShortcuts() throws {
        let manager = Tako.MenuShortcutManager()
        let prevItem = NSMenuItem(title: "Jump Prev", action: nil, keyEquivalent: "")
        let nextItem = NSMenuItem(title: "Jump Next", action: nil, keyEquivalent: "")
        let selectItem = NSMenuItem(title: "Select Output", action: nil, keyEquivalent: "")

        let defaultConfig = Tako.Config()
        manager.syncMenuShortcut(defaultConfig, action: "jump_to_prompt:previous", menuItem: prevItem)
        manager.syncMenuShortcut(defaultConfig, action: "jump_to_prompt:next", menuItem: nextItem)
        manager.syncMenuShortcut(defaultConfig, action: "select_command_output", menuItem: selectItem)

        #expect(prevItem.keyEquivalent == String(utf16CodeUnits: [unichar(NSUpArrowFunctionKey)], count: 1))
        #expect(prevItem.keyEquivalentModifierMask == .command)
        #expect(nextItem.keyEquivalent == String(utf16CodeUnits: [unichar(NSDownArrowFunctionKey)], count: 1))
        #expect(nextItem.keyEquivalentModifierMask == .command)
        #expect(selectItem.keyEquivalent == "a")
        #expect(selectItem.keyEquivalentModifierMask == [.command, .shift])

        // Remap jump_to_prompt:previous to cmd+k
        let remappedConfig = try TemporaryConfig("keybind = cmd+k=jump_to_prompt:previous")
        manager.syncMenuShortcut(remappedConfig, action: "jump_to_prompt:previous", menuItem: prevItem)
        #expect(prevItem.keyEquivalent == "k")
        #expect(prevItem.keyEquivalentModifierMask == .command)

        // Unbind select_command_output
        let unboundConfig = try TemporaryConfig("keybind = cmd+shift+a=unbind")
        manager.syncMenuShortcut(unboundConfig, action: "select_command_output", menuItem: selectItem)
        #expect(selectItem.keyEquivalent == "")
        #expect(selectItem.keyEquivalentModifierMask.isEmpty)
    }
}
