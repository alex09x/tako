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

@MainActor extension AppDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return derivedConfig.shouldQuitAfterLastWindowClosed
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppUpdater.isRelaunching { return .terminateNow }
        let windows = NSApplication.shared.windows
        if windows.isEmpty { return .terminateNow }

        // This probably isn't fully safe. The isEmpty check above is aspirational, it doesn't
        // quite work with SwiftUI because windows are retained on close. So instead we check
        // if there are any that are visible. I'm guessing this breaks under certain scenarios.
        //
        // NOTE: I don't think we need this check at all anymore. I'm keeping it
        // here because I don't want to remove it in a patch release cycle but we should
        // target removing it soon.
        if (windows.allSatisfy { !$0.isVisible }) {
            return .terminateNow
        }

        // If the user is shutting down, restarting, or logging out, we don't confirm quit.
        if Self.quitIsForcedBySystem(NSAppleEventManager.shared().currentAppleEvent) {
            return .terminateNow
        }

        // If our app says we don't need to confirm, we can exit now.
        if !tako.needsConfirmQuit { return .terminateNow }

        return terminate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ControlCommands.stop()
        sessionSaver.save(Self.restorableSurfaces(), settings: sessionSaveSettings())
        sessionSaver.stop()
        // Quitting is confirmed (a cancelled quit never gets here): persistent
        // terminals let go of their sessions instead of ending them.
        SurfaceSession.detachAll(allLiveSurfaces())
        // Last: the final layout, then `clean`. Only a quit that got this far
        // is clean; a crash anywhere before leaves the journal in charge.
        LayoutRecorder.finish()
        // We have no notifications we want to persist after death,
        // so remove them all now. In the future we may want to be
        // more selective and only remove surface-targeted notifications.
        Self.notificationCenterProvider()?.removeAllDeliveredNotifications()
    }

    // MARK: - Termination Flow

    func terminate() -> NSApplication.TerminateReply {
        let controllersNeedConfirmation = NSApplication.shared.windows
            .compactMap { $0.windowController as? BaseTerminalController }
            .filter { !$0.windowCanBeClosedWithoutConfirmation(quitting: true) }

        guard !controllersNeedConfirmation.isEmpty else {
            return .terminateNow
        }

        if controllersNeedConfirmation.count == 1 {
            Task {
                let response = await controllersNeedConfirmation[0].confirmCloseAsync(
                    messageText: "Quit Tako?",
                    informativeText: "The terminal still has a running process. If you quit, the process will be killed.",
                    confirmButtonTitle: "Terminate",
                )

                if [.OK, .alertFirstButtonReturn].contains(response) {
                    await self.replyToTermination(true)
                } else {
                    await self.replyToTermination(false)
                }
            }

            return .terminateLater
        } else if let window = MainActor.assumeIsolated({
            AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows)
        }) {
            // Asked in a terminal window, drawn as the terminal UI is; the
            // alert below only when no terminal window is there to ask in.
            let count = controllersNeedConfirmation.count
            Task { @MainActor in
                let answer = await TerminalDialogView.choose(
                    in: window, title: "Quit Tako?",
                    lines: TUIText.plain("\(count) windows have running processes. Review them one by one, or end them all and quit.", width: 52),
                    choices: [.init(title: "Cancel", kind: .normal),
                              .init(title: "Review Windows…", kind: .normal),
                              .init(title: "Terminate Processes", kind: .destructive)],
                    selected: 1, cancelIndex: 0, theme: self.tako.config.theme)
                switch answer {
                case 1: self.reviewWindows(controllersNeedConfirmation)
                case 2: await self.replyToTermination(true)
                default: await self.replyToTermination(false)
                }
            }
            return .terminateLater
        } else {
            let alert = NSAlert()
            alert.messageText = "You have \(controllersNeedConfirmation.count) windows with running processes. Do you want to review these windows before quitting?"
            alert.informativeText = "If you don't review your windows, any running processes will be terminated"
            alert.addButton(withTitle: "Review Windows...")
            alert.addButton(withTitle: "Terminate Processes")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning

            switch runModalAlert(alert) {
            case .alertFirstButtonReturn:
                reviewWindows(controllersNeedConfirmation)
                return .terminateLater
            case .alertSecondButtonReturn:
                return .terminateNow
            default:
                return .terminateCancel
            }
        }
    }

    private func reviewWindows(_ controllers: [BaseTerminalController]) {
        Task {
            for controller in controllers {
                let response = await controller.confirmCloseAsync(
                    messageText: "Quit Tako?",
                    informativeText: "The terminal still has a running process. If you quit, the process will be killed.",
                    confirmButtonTitle: "Terminate",
                )

                if [.OK, .alertFirstButtonReturn].contains(response) {
                    // Close this window and until next review is cancelled
                    await controller.window?.close()
                    continue
                } else {
                    await self.replyToTermination(false)
                    // Cancel the review
                    return
                }
            }
            await self.replyToTermination(true)
        }
    }
}
