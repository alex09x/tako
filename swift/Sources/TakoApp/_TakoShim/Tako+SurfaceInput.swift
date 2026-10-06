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

extension Tako.SurfaceView {
        /// Where `copy-on-select` puts a selection by itself: a pasteboard of
        /// the app's own, which `paste_from_selection` reads.
        nonisolated(unsafe) static var selectionPasteboard = NSPasteboard(name: .init("com.tako-core.terminal.selection"))


        func setupCoreAndPty(workingDir: String?, restoring snapshot: SessionSnapshot? = nil,
                                     restored: Bool = false, hadPersistentSession: Bool = false,
                                     allowsPersistence: Bool = true, program: [String]? = nil,
                                     programEnvironment: [String: String] = [:]) {
            runProgram = program
            let persistent = persistenceEnabled && allowsPersistence && program == nil
            // A restored tab shows what it showed before, and only then does
            // its new shell start, so nothing the shell prints is overwritten.
            // With session-persistence the session decides: a live one paints
            // its own screen and the snapshot is shown only if it is gone.
            if !persistent, let snapshot {
                showSnapshot(snapshot)
            }

            // Default: when the child shell exits on its own (`exit`, Ctrl-D,
            // the command crashing), close this surface the same way a
            // manual close does, just without the confirmation prompt --
            // there's no live process left to confirm killing. Without this,
            // `pty.readLoop`'s `onExit` (below) fires into a nil closure and
            // the pane just sits there dead: no new prompt, no "process
            // exited" message, nothing. Callers that want different behavior
            // can still overwrite `onExit` after construction.
            onExit = { view in
                NotificationCenter.default.post(
                    name: Tako.Notification.takoCloseSurface,
                    object: view,
                    userInfo: ["process_alive": false]
                )
            }

            // Same story as `onExit`, found the same way (declared, called
            // from real pointer handling -- now the inherited surface's -- and
            // never assigned anywhere in the app target): clicking an unfocused
            // split's pane moved AppKit's own key-view focus there
            // (`makeFirstResponder`, already in `mouseDown`) but never told
            // the controller, so its own `focusedSurface` bookkeeping (the
            // custom tab bar's active-pane state, "new split opens next to
            // the focused one", etc.) stayed on whatever pane was focused
            // before the click. `.takoPresentTerminal` is the existing
            // notification for exactly this -- `takoDidPresentTerminal`
            // already does `Tako.moveFocus(to:)` for it elsewhere.
            onFocusRequest = { view in
                NotificationCenter.default.post(
                    name: Tako.Notification.takoPresentTerminal,
                    object: view
                )
            }

            // Same again: `self.title` (a `@Published` property) is what
            // actually drives the window title text, so this being unwired
            // didn't break that -- but it did mean the custom tab bar (which
            // reads titles by re-drawing, not by observing `$title`) never
            // got told to refresh on its own, only whenever some unrelated
            // event happened to trigger a redraw. A tab's label would sit
            // stale after e.g. `cd`ing to a new directory until something
            // else -- switching tabs, resizing -- forced a repaint.
            onTitleChange = { (_: Tako.SurfaceView) in
                Tako.TabBarController.refreshAll()
            }

            if let program {
                // The pane outlives its program: what it printed, and how it
                // ended, stay to be read.
                onExit = { (view: Tako.SurfaceView) in
                    // The terminal closed; the status comes with the process's
                    // own exit, which may follow a moment later.
                    let pty = view.pty
                    DispatchQueue.global(qos: .utility).async {
                        for _ in 0..<100 where pty?.exitStatus == nil && pty?.startError == nil { usleep(10_000) }
                        let status: String
                        if let error = pty?.startError {
                            status = "could not start: \(String(cString: strerror(error)))"
                        } else {
                            status = pty?.exitStatus.map { "exited with code \($0)" } ?? "exited"
                        }
                        DispatchQueue.main.async {
                            view.runEndNote = "[\(status)]"
                            view.core.feed(bytes: Data("\r\n\u{1b}[2m[\(status)]\u{1b}[0m\r\n".utf8))
                            view.needsDisplay = true
                        }
                    }
                }
                startProcess(workingDir: workingDir, program: program, environment: programEnvironment)
            } else if persistent {
                launchPersistentSession(workingDir: workingDir, snapshot: snapshot, restored: restored,
                                        hadPersistentSession: hadPersistentSession)
            } else {
                startProcess(workingDir: workingDir)
            }

            if restored || snapshot != nil {
                DispatchQueue.main.async { [weak self] in
                    self?.checkAndApplyResumeOnRestore(restoredDir: workingDir)
                }
            }

            // Cursor blinking is the inherited surface's, driven by its own
            // display link and suppressed inside a Synchronized Output frame.
        }

        /// Starts the terminal's process and the loop that reads it: the
        /// login shell, or `program` (the session runtime's client when the
        /// shell lives in a persistent session). May run again for the same
        /// surface, when a reattach found no session and a new one starts.
        public func focusDidChange(_ focused: Bool) {
            self.focused = focused
            if isSecureInput {
                SecureInput.shared.setScoped(self, isSecure: true, focused: focused)
            }
            if focused {
                crab.focused()
                NotificationStore.shared.markRead(surfaceId: self.id)
            } else {
                crab.unfocused()
            }
            needsDisplay = true
        }

        public func updateTheme(_ newTheme: TerminalTheme) {
            // Assigning the inherited `theme` rebuilds the text renderer and
            // stands up a fresh Metal stack, because font metrics and palette
            // are baked into rasterized glyph masks. Doing any of that here as
            // well is how the two surfaces drifted apart in the first place.
            configuredTheme = newTheme
            applyTheme(newTheme)
        }

        /// Evaluates safe paste guard before sending text to the shell.
        public func pasteText(_ text: String) {
            guard !text.isEmpty else { return }
            scrollViewportToBottom()
            let bytes = [UInt8](core.encodePaste(text: text))
            if !bytes.isEmpty {
                writeToShell(bytes)
            }
        }

        public func write(_ text: String) {
            writeToShell([UInt8](Data(text.utf8)))
        }

        public func sendText(_ text: String) {
            write(text)
            core.scrollViewportBottom()
            needsDisplay = true
        }

        /// Send a key the way `keyDown` would, but from a caller that has no
        /// NSEvent -- scripting, intents, or a keybinding replay.
        func send(keyEvent event: Tako.Input.KeyEvent) {
            var ffi = FfiKeyEvent(
                key: .character, text: event.text ?? "",
                physicalText: event.text ?? "", unshiftedText: event.text ?? "",
                shift: event.mods.contains(.shift), alt: event.mods.contains(.alt),
                ctrl: event.mods.contains(.ctrl), superKey: event.mods.contains(.super),
                press: event.action.isPress, repeat: event.action == .repeatKey, composing: false
            )
            if let named = Tako.Input.Key.ffiKeys[event.key] {
                ffi.key = named
            } else if event.key == .space {
                ffi.key = FfiKey.character
                ffi.text = " "
            } else if ffi.text.isEmpty {
                // No text and no key the engine knows: nothing to send.
                return
            }
            guard ffi.press else { return }
            pty?.write([UInt8](core.encodeKey(event: ffi)))
            core.scrollViewportBottom()
            // scheduleRedraw, not a direct needsDisplay: this fires on
            // every keystroke, unconditionally, and a fast TUI app can
            // already be replying -- mid its own Synchronized Output frame
            // -- before this line runs. On a real keyboard the two
            // essentially never race meaningfully; a burst of programmatic
            // or fast-repeat keystrokes is exactly when they can.
            scheduleRedraw()
        }

        func send(mouseButton event: Tako.Input.MouseButtonEvent) {
            guard let cell = mouseCell else { return }
            let button: FfiMouseButton = switch event.button {
            case .left: .left
            case .right: .right
            case .middle: .middle
            case .unknown: .none
            }
            let bytes = core.encodeMouse(event: FfiMouseEvent(
                button: button,
                action: event.action == .press ? .press : .release,
                shift: event.mods.contains(.shift),
                alt: event.mods.contains(.alt),
                ctrl: event.mods.contains(.ctrl),
                col: UInt32(cell.col), row: UInt32(cell.row)))
            pty?.write([UInt8](bytes))
        }

        func send(mousePos event: Tako.Input.MousePosEvent) {
            setMouseCell(cellAt(NSPoint(x: event.x, y: event.y)))
        }

        func send(mouseScroll event: Tako.Input.MouseScrollEvent) {
            let lines = Int(event.y.rounded())
            guard lines != 0 else { return }
            let cell = mouseCell ?? (row: 0, col: 0)
            let report = mouseReportBytes(
                button: lines > 0 ? .wheelUp : .wheelDown, action: .press, cell: cell)
            guard report.isEmpty else {
                writeToShell([UInt8](report))
                return
            }
            if lines > 0 {
                core.scrollViewportUp(lines: UInt32(lines))
            } else {
                core.scrollViewportDown(lines: UInt32(-lines))
            }
            needsDisplay = true
        }

        /// True while the running program has asked to receive mouse events
        /// itself, which is when the app must stop interpreting them.
        /// Read through `modes()`, not `snapshot()`: a snapshot takes the
        /// frame's damage list, which the renderer then never sees.
        public var mouseCaptured: Bool { core.modes().mouseTracking != .off }

        public func toggleReadonly(_ sender: Any?) {
            readonly.toggle()
        }

        /// Upstream's implementation, verbatim (SurfaceView_AppKit.swift) --
        /// pure logic with no dependency on the IME/marked-text machinery
        /// this shim doesn't carry, so it needed no adaptation.
        ///
        /// True when `text` is a single C0 control character (U+0000-U+001F)
        /// arriving while the IME is composing. Such input belongs to the IME
        /// and must not be forwarded to the terminal.
        // The parent already provides this rule; the app layer used to carry
        // its own copy of it.
        static func surfaceShouldSuppressComposingControlInput(
            _ text: String?,
            composing: Bool
        ) -> Bool {
            guard composing, let text else { return false }
            let scalars = text.unicodeScalars
            guard let scalar = scalars.first,
                  scalars.index(after: scalars.startIndex) == scalars.endIndex else {
                return false
            }
            return scalar.value < 0x20
        }



        func writeToShell(_ bytes: [UInt8]) {
            // A terminal waiting on its session (an error, a lost client)
            // has no process: Return tries again; other keys go nowhere.
            if pty == nil, let retry = sessionRetry {
                if bytes.contains(0x0d) { retry() }
                return
            }
            if selfTestCapturing {
                selfTestBytes += bytes
            } else {
                pty?.write(bytes)
            }
        }

        /// Upstream stores surfaces in a `Codable` SplitTree so a window's
        /// layout can be restored. A live surface owns a PTY, which cannot be
        /// serialized: restoring recreates the surface with a new shell. What
        /// travels is its identity, the directory its shell last reported
        /// (OSC 7), and -- in a file of its own, see `SessionSnapshotStore`
        /// -- what was on its screen.
}
