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

#if canImport(UIKit)
import UIKit

extension TakoTerminalView {
    public func insertText(_ typed: String) {
        guard !typed.isEmpty else { return }
        let text = SpaceBar.text(forCommitted: typed)
        revealLiveScreenForUserInput()
        let bytes: Data
        if text == "\n" || text == "\r" {
            bytes = core.encodeKey(event: FfiKeyEvent(
                key: .enter,
                text: "\r",
                physicalText: "",
                unshiftedText: "",
                shift: false, alt: false, ctrl: false, superKey: false,
                press: true, repeat: false, composing: false
            ))
        } else if text.count == 1, let ch = text.first {
            bytes = core.encodeKey(event: FfiKeyEvent(
                key: .character,
                text: String(ch),
                physicalText: String(ch),
                unshiftedText: String(ch),
                shift: false, alt: false, ctrl: false, superKey: false,
                press: true, repeat: false, composing: false
            ))
        } else {
            bytes = core.encodePaste(text: text)
        }
        if !bytes.isEmpty {
            delegate?.terminalView(self, sendInputData: bytes)
        }
    }

    public func deleteBackward() {
        revealLiveScreenForUserInput()
        let bytes = core.encodeKey(event: FfiKeyEvent(
            key: .backspace,
            text: "",
            physicalText: "",
            unshiftedText: "",
            shift: false, alt: false, ctrl: false, superKey: false,
            press: true, repeat: false, composing: false
        ))
        if !bytes.isEmpty {
            delegate?.terminalView(self, sendInputData: bytes)
        }
    }

    override public var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: "\u{1b}", modifierFlags: [], action: #selector(handleKeyCommand(_:))), // Esc
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleKeyCommand(_:))),     // Tab
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(handleKeyCommand(_:))),     // Enter
            UIKeyCommand(input: "\u{08}", modifierFlags: [], action: #selector(handleKeyCommand(_:))), // Backspace
        ]
        let letters = "abcdefghijklmnopqrstuvwxyz"
        for char in letters {
            commands.append(UIKeyCommand(input: String(char), modifierFlags: .control, action: #selector(handleKeyCommand(_:))))
        }
        commands.append(UIKeyCommand(input: " ", modifierFlags: .control, action: #selector(handleKeyCommand(_:))))
        return commands
    }

    @objc func handleKeyCommand(_ command: UIKeyCommand) {
        guard let input = command.input else { return }
        revealLiveScreenForUserInput()
        let isCtrl = command.modifierFlags.contains(.control)
        let isShift = command.modifierFlags.contains(.shift)
        let isAlt = command.modifierFlags.contains(.alternate)

        let key: FfiKey
        var text = ""

        switch input {
        case UIKeyCommand.inputUpArrow: key = .up
        case UIKeyCommand.inputDownArrow: key = .down
        case UIKeyCommand.inputLeftArrow: key = .left
        case UIKeyCommand.inputRightArrow: key = .right
        case "\u{1b}": key = .escape
        case "\t": key = .tab
        case "\r": key = .enter
        case "\u{08}": key = .backspace
        case " ": key = .space; text = " "
        default:
            key = .character
            text = input
        }

        let event = FfiKeyEvent(
            key: key,
            text: text,
            physicalText: text,
            unshiftedText: text,
            shift: isShift,
            alt: isAlt,
            ctrl: isCtrl,
            superKey: false,
            press: true,
            repeat: false,
            composing: false
        )
        let bytes = core.encodeKey(event: event)
        if !bytes.isEmpty {
            delegate?.terminalView(self, sendInputData: bytes)
        }
    }

    override public func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return UIPasteboard.general.hasStrings
        }
        if action == #selector(copy(_:)) {
            return core.hasSelection()
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override public func paste(_ sender: Any?) {
        guard let string = pasteStringProvider() else { return }
        revealLiveScreenForUserInput()
        let bytes = core.encodePaste(text: string)
        if !bytes.isEmpty {
            delegate?.terminalView(self, sendInputData: bytes)
        }
    }

    override public func copy(_ sender: Any?) {
        guard let text = core.selectedText() else { return }
        copyStringConsumer(text)
    }

    func revealLiveScreenForUserInput() {
        cancelKineticScroll()
        guard viewportOffset > 0 else { return }
        scrollViewportToBottom()
        notifyScrollPositionIfChanged()
    }
}
#endif
