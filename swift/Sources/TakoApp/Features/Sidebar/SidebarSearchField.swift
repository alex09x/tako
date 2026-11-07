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
import SwiftUI

/// Native AppKit single-line search field for the collapsible Session Sidebar filter drawer.
/// Exposes `SessionSidebarSearchField` directly in AppKit/AX and intercepts `Escape`
/// (`cancelOperation(_:)`) in the field editor so pressing `Escape` clears and collapses search
/// instead of triggering macOS `NSTextView` word-completion.
final class SidebarSearchNSTextField: NSTextField {
    var onEscape: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        cell?.isScrollable = true
        cell?.wraps = false
        setAccessibilityIdentifier("SessionSidebarSearchField")
        setAccessibilityLabel("Search sessions")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func cancelOperation(_ sender: Any?) {
        _ = window?.makeFirstResponder(nil)
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            _ = window?.makeFirstResponder(nil)
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

struct SidebarSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequestToken: Int
    let font: NSFont
    let textColor: NSColor
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onEscape: onEscape)
    }

    func makeNSView(context: Context) -> SidebarSearchNSTextField {
        let field = SidebarSearchNSTextField(frame: .zero)
        field.delegate = context.coordinator
        field.font = font
        field.textColor = textColor
        field.stringValue = text
        field.onEscape = onEscape
        return field
    }

    func updateNSView(_ nsView: SidebarSearchNSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onEscape = onEscape
        nsView.onEscape = onEscape
        nsView.font = font
        nsView.textColor = textColor
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if context.coordinator.lastFocusToken != focusRequestToken {
            context.coordinator.lastFocusToken = focusRequestToken
            if let window = nsView.window {
                _ = window.makeFirstResponder(nsView)
            } else {
                DispatchQueue.main.async { [weak nsView] in
                    guard let nsView, let window = nsView.window else { return }
                    _ = window.makeFirstResponder(nsView)
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onEscape: () -> Void
        var lastFocusToken: Int = -1

        init(text: Binding<String>, onEscape: @escaping () -> Void) {
            self.text = text
            self.onEscape = onEscape
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if text.wrappedValue != field.stringValue {
                text.wrappedValue = field.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                _ = control.window?.makeFirstResponder(nil)
                onEscape()
                return true
            }
            return false
        }
    }
}
