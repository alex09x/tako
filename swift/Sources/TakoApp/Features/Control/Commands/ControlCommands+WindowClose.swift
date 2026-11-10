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

extension ControlCommands {
    /// `window close`: closes the window's tabs the way ⇧⌘W does, asking
    /// first when a process still runs, and answers once: `closed` when the
    /// window has really closed, `cancelled` when the user said no or did not
    /// answer within `closeWait` (the question is then withdrawn).
    ///
    /// Refused, with nothing touched, when the question could not be seen:
    /// a window in a workspace not shown (⇧⌘W there would close the shown
    /// workspace's tabs instead), or one minimized to the Dock with a process
    /// running. The last window is refused unless `force`, which lifts only
    /// that: a busy window still asks.
    static func windowClose(_ request: ControlRequest, all: [Pane],
                            reply: @escaping @Sendable (ControlResponse) -> Void) throws {
        let groups = windowGroups()
        let target = try windowGroup(request, all: all, groups: groups)
        guard let shown = target.shown, let window = shown.window else {
            throw ControlError(.notFound, "the window \(target.id) has no tab on screen")
        }
        let tabs = target.group.visibleWindows
        guard tabs.contains(where: { $0 === window }) else {
            throw ControlError(.invalid, "the window is in a workspace not shown; switch to it before closing it")
        }
        let busy = tabs.compactMap { $0.windowController as? BaseTerminalController }
            .contains { $0.surfaceTree.contains(where: \.needsConfirmClose) }
        if busy, window.isMiniaturized || !window.isVisible {
            throw ControlError(.invalid, "something runs in the window and it is not on screen to ask; window restore first")
        }
        if groups.count == 1, request.args["force"] != .bool(true), shown.quitsAfterLastWindow {
            throw ControlError(.invalid, "this is the last window: closing it quits Tako (--force to do it anyway)")
        }
        recordActivity(for: request, on: shown.surfaceTree.first?.id ?? UUID(), action: "window close")

        // Closed means the window's own close happened -- not that it left
        // the screen, which a workspace switch also does.
        // Touched only on the main thread: the notification is posted there.
        final class Closing: @unchecked Sendable { var done = false; var answered = false; var observer: NSObjectProtocol? }
        let closing = Closing()
        closing.observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil) { _ in closing.done = true }
        func answer(_ state: String) {
            guard !closing.answered else { return }
            closing.answered = true
            closing.observer.map(NotificationCenter.default.removeObserver)
            reply(.ok(["window": .string(target.id), "state": .string(state)]))
        }
        shown.closeWindow(nil)
        let deadline = Date().addingTimeInterval(ControlLayout.closeWait)
        func check() {
            guard !closing.done else { return answer("closed") }
            let dialog = tabs.lazy.compactMap { TerminalDialogView.pending(in: $0) }.first
            let sheet = tabs.lazy.compactMap(\.attachedSheet).first
            guard dialog != nil || sheet != nil else { return answer("cancelled") }
            guard Date() < deadline else {
                if let dialog { dialog.withdraw() } else if let sheet { sheet.sheetParent?.endSheet(sheet, returnCode: .abort) }
                DispatchQueue.main.async { answer(closing.done ? "closed" : "cancelled") }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }
        }
        if closing.done { return answer("closed") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { check() }
    }
}
