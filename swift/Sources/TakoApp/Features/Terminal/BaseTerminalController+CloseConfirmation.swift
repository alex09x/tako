/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Cocoa
import TakoKit

extension BaseTerminalController {
    func confirmCloseAsync(
        messageText: String,
        informativeText: String,
        confirmButtonTitle: String = "Close",
    ) async -> NSApplication.ModalResponse? {
        // If we already have an alert, we need to wait for that one.
        guard alert == nil else { return nil }

        guard !asking else { return nil }

        // If there is no window to attach the modal then we assume success
        // since we'll never be able to show the modal.
        guard let window else {
            return .OK
        }

        // Asked inside the terminal, in its own font and colours, rather
        // than in a macOS sheet; the sheet remains for a window without a
        // content view to draw in.
        asking = true
        let theme = (NSApp.delegate as? AppDelegate)?.tako.config.theme
        let answer = await TerminalDialogView.ask(in: window, title: messageText, message: informativeText,
                                                  confirm: confirmButtonTitle, theme: theme)
        asking = false
        if let answer { return answer ? .alertFirstButtonReturn : .alertSecondButtonReturn }

        // If we need confirmation by any, show one confirmation for all windows
        // in the tab group.
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: confirmButtonTitle)
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        // Store our alert so we only ever show one.
        self.alert = alert
        defer {
            // This is important so that we avoid losing focus when Stage
            // Manager is used.
            alert.window.orderOut(nil)
            self.alert = nil
        }
        return await alert.beginSheetModal(for: window)
    }

    func confirmClose(
        messageText: String,
        informativeText: String,
        confirmButtonTitle: String = "Close",
        completion: @escaping () -> Void
    ) {
        Task {
            // Nil: a question is already up. It is not an answer -- with the
            // question drawn in the window a second ⌘W reaches us while the
            // first waits -- so nothing closes until that one is answered.
            guard let response = await confirmCloseAsync(messageText: messageText, informativeText: informativeText, confirmButtonTitle: confirmButtonTitle),
                  [.alertFirstButtonReturn, .OK].contains(response)
            else { return }
            completion()
        }
    }

    /// Prompt the user to change the tab/window title.
    func promptTabTitle() {
        guard let window else { return }

        // Asked in the window, drawn as the terminal UI is (see
        // `TerminalDialogView`).
        let theme = (NSApp.delegate as? AppDelegate)?.tako.config.theme
        Task { @MainActor [weak self] in
            guard let self,
                  let newTitle = await TerminalDialogView.askText(
                    in: window, title: "Rename Tab", label: "Title",
                    value: self.titleOverride ?? window.title,
                    hint: "empty brings back the program's own title",
                    confirm: "Save", theme: theme)
            else { return }
            self.titleOverride = newTitle.isEmpty ? nil : newTitle
        }
    }

}
