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
import TakoKit

extension Tako {
    /// Wrapper representing a surface model.
    open class Surface: @unchecked Sendable {
        /// The view that owns the engine and the PTY. Weak because the view
        /// owns the model, not the other way around.
        public weak var view: SurfaceView?

        public var unsafeCValue: tako_surface_t? { nil }

        public init(cSurface: tako_surface_t? = nil) {}

        public init(view: SurfaceView) { self.view = view }

        @MainActor public func sendText(_ text: String) {
            view?.write(text)
        }

        @MainActor public func sendKeyEvent(_ event: Tako.Input.KeyEvent) {
            view?.send(keyEvent: event)
        }

        @MainActor public func sendMouseButton(_ event: Tako.Input.MouseButtonEvent) {
            view?.send(mouseButton: event)
        }

        @MainActor public func sendMousePos(_ event: Tako.Input.MousePosEvent) {
            view?.send(mousePos: event)
        }

        @MainActor public func sendMouseScroll(_ event: Tako.Input.MouseScrollEvent) {
            view?.send(mouseScroll: event)
        }

        @MainActor public var mouseCaptured: Bool { view?.mouseCaptured ?? false }
        @MainActor public var foregroundPID: Int? { view?.pty?.foregroundPID }
        @MainActor public var ttyName: String? { view?.pty?.ttyName }

        @MainActor public func perform(action: String) -> Bool {
            view?.performBindingAction(action) ?? false
        }
    }

    public enum OSSurfaceView {}
}

extension Tako.OSSurfaceView {
    @MainActor class SearchState: ObservableObject {
        /// The pasteboard used to persist the search needle.
        ///
        /// The `.find` pasteboard lets us sync our needle across the system and other find bars.
        private let pasteboard: OSPasteboard

        @Published var needle: String = ""
        @Published var selected: UInt?
        @Published var total: UInt?

        /// The range of the needle's text selection in the find bar.
        @Published var needleSelection: Range<String.Index>?

        init(
            from startSearch: Tako.Action.StartSearch,
            pasteboard: OSPasteboard = OSPasteboard.find
        ) {
            self.pasteboard = pasteboard
            if let needle = startSearch.needle, !needle.isEmpty {
                self.needle = needle
                writePasteboardNeedle()
            } else {
                readPasteboardNeedle()
            }
        }

        func readPasteboardNeedle() {
            let pasteboardNeedle = pasteboard.string
            if let pasteboardNeedle, pasteboardNeedle != needle {
                needle = pasteboardNeedle
                needleSelection = needle.startIndex..<needle.endIndex
            }
        }

        func writePasteboardNeedle() {
            pasteboard.string = needle
        }
    }
}

extension Tako.SurfaceView {
    /// Whether this pane is currently in password/secure mode (e.g. no echo on PTY or explicit secure entry) (C8).
    public var isSecureInput: Bool {
        if _explicitSecureInput { return true }
        if let pty = currentProcess, pty.isPasswordMode { return true }
        return false
    }

    /// Pane-scoped secure input mode toggle. When set to true, registers the pane in SecureInput.shared.
    public var isSecureInputMode: Bool {
        get { isSecureInput }
        set {
            _explicitSecureInput = newValue
            SecureInput.shared.setScoped(self, isSecure: newValue, focused: window?.firstResponder === self)
        }
    }

    public var visibleText: String {
        (0..<rows).map { core.getLine(row: UInt32($0)) }.joined(separator: "\n")
    }

    /// Whether this surface currently takes the keys.
    public var isFirstResponderSurface: Bool { window?.firstResponder === self }

    public var processExited: Bool { pty?.alive == false }

    public var cellSize: NSSize {
        NSSize(width: renderer.metrics.cellWidth, height: renderer.metrics.cellHeight)
    }

    public var pid: Int { Int(pty?.child ?? 0) }

    public var ttyName: String {
        pty?.ttyName ?? ""
    }

    /// Flash the surface briefly so the user can find it after focus
    /// jumps to another window.
    @MainActor public func highlight() {}

    public convenience init(frame frameRect: NSRect) {
        self.init(nil, baseConfig: nil, uuid: UUID(), theme: nil)
        self.frame = frameRect
    }
}
