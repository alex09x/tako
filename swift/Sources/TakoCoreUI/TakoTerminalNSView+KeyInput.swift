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

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

extension TakoTerminalNSView {
    // MARK: - First Responder & Focus

    override open var acceptsFirstResponder: Bool { true }

    var ownInputContext: NSTextInputContext {
        if let storedInputContext { return storedInputContext }
        inputContextCreations += 1
        let context = NSTextInputContext(client: self)
        storedInputContext = context
        return context
    }

    var inputContextCreationCountForTesting: Int { inputContextCreations }

    override open var inputContext: NSTextInputContext? {
        guard window != nil, !isHiddenOrHasHiddenAncestor, !isLeavingWindow else {
            return storedInputContext
        }
        return ownInputContext
    }

    var shouldHoldInputContext: Bool {
        Self.shouldHoldInputContext(
            hasWindow: window != nil,
            isKeyWindow: window?.isKeyWindow ?? false,
            isFirstResponder: window?.firstResponder === self,
            isHidden: isHiddenOrHasHiddenAncestor
        )
    }

    static func shouldHoldInputContext(
        hasWindow: Bool,
        isKeyWindow: Bool,
        isFirstResponder: Bool,
        isHidden: Bool
    ) -> Bool {
        guard hasWindow, !isHidden else { return false }
        return isKeyWindow && isFirstResponder
    }

    func updateInputContextActivation() {
        let shouldBeActive = shouldHoldInputContext
        guard shouldBeActive != inputContextIsActive else { return }
        inputContextIsActive = shouldBeActive
        if shouldBeActive {
            ownInputContext.activate()
        } else {
            storedInputContext?.deactivate()
        }
    }

    var isInputContextActiveForTesting: Bool { inputContextIsActive }

    override open func becomeFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.updateInputContextActivation() }
        }
        scheduleRedraw()
        return true
    }

    override open func resignFirstResponder() -> Bool {
        if hasMarkedText() { unmarkText() }
        deactivateInputContext()
        scheduleRedraw()
        return true
    }

    func deactivateInputContext() {
        guard inputContextIsActive else { return }
        inputContextIsActive = false
        storedInputContext?.deactivate()
    }

    override open func viewDidHide() {
        super.viewDidHide()
        updateInputContextActivation()
    }

    override open func viewDidUnhide() {
        super.viewDidUnhide()
        updateInputContextActivation()
    }

    @objc func windowKeyStateChanged(_ note: Notification) {
        guard (note.object as? NSWindow) === window else { return }
        updateInputContextActivation()
    }

    func observeWindowKeyState() {
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            center.addObserver(
                self,
                selector: #selector(windowKeyStateChanged(_:)),
                name: name,
                object: window
            )
        }
    }

    // MARK: - Keyboard Input

    override open func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags
        if mods.contains(.command) {
            super.keyDown(with: event)
            return
        }

        let optionActsAsAlt = mods.contains(.option) && optionAsAlt.appliesTo(event)
        if hidesMouseWhileTyping {
            Self.hideMouseUntilMoved()
        }
        let namedKey = NamedKey.byKeyCode[event.keyCode]

        var ffi = FfiKeyEvent(
            key: .character,
            text: "",
            physicalText: "",
            unshiftedText: "",
            shift: mods.contains(.shift),
            alt: mods.contains(.option)
                && (optionActsAsAlt || (namedKey != nil && namedKey != .space)),
            ctrl: mods.contains(.control),
            superKey: false,
            press: true,
            repeat: event.isARepeat,
            composing: false
        )

        if let named = namedKey {
            ffi.key = named
            if named == .space {
                ffi.text = " "
                ffi.unshiftedText = " "
            }
        } else if optionActsAsAlt {
            guard let chars = event.characters(byApplyingModifiers: mods.subtracting(.option)),
                  !chars.isEmpty else { return }
            ffi.text = chars
            ffi.unshiftedText = event.charactersIgnoringModifiers ?? chars
            ffi.physicalText = PhysicalKey.character(for: event.keyCode)
        } else {
            guard let chars = event.characters, !chars.isEmpty else { return }
            ffi.text = chars
            ffi.unshiftedText = event.charactersIgnoringModifiers ?? chars
            ffi.physicalText = PhysicalKey.character(for: event.keyCode)
        }

        if !optionActsAsAlt {
            keyTextAccumulator = ""
            let handled = inputContext?.handleEvent(event) == true
            var committed = keyTextAccumulator ?? ""
            keyTextAccumulator = nil
            if namedKey == .space {
                committed = SpaceBar.text(forCommitted: committed)
            }

            if !committed.isEmpty {
                insertText(committed, replacementRange: NSRange(location: NSNotFound, length: 0))
                return
            }

            if handled, markedText != nil {
                scheduleRedraw()
                return
            }
        }

        revealLiveScreenForUserInput()
        let bytes = core.encodeKey(event: ffi)
        if !bytes.isEmpty {
            delegate?.terminalView(self, sendInputData: bytes)
        }
        core.clearSelection()
        blinkStateVisible = true
        scheduleRedraw()
    }

    func revealLiveScreenForUserInput() {
        guard viewportOffset > 0 else { return }
        scrollViewportToBottom()
    }
}
#endif
