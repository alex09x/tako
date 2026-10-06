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

extension AppDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // If we have visible windows then we allow macOS to do its default behavior
        // of focusing one of them.
        guard !flag else { return true }

        // If we have any windows in our terminal manager we don't do anything.
        // This is possible with flag set to false if there a race where the
        // window is still initializing and is not visible but the user clicked
        // the dock icon.
        guard TerminalController.all.isEmpty else { return true }

        // If the application isn't active yet then we don't want to process
        // this because we're not ready. This happens sometimes in Xcode runs
        // but I haven't seen it happen in releases. I'm unsure why.
        guard applicationHasBecomeActive else { return true }

        // No visible windows, open a new one.
        _ = TerminalController.newWindow(tako)
        return false
    }

    /// 'why?', the quit event's reason attribute: `keyAEQuitReason`, which
    /// Swift does not import.
    static let quitReasonKeyword: AEKeyword = "why?".utf8.reduce(0) { $0 << 8 | AEKeyword($1) }

    /// Whether the quit `event` asks for is the system shutting down,
    /// restarting or logging out, when a quit is not confirmed. The reason is
    /// the event's `keyAEQuitReason` ('why?') attribute; the event is nil
    /// when every Tako window is in the background (Cmd-Q from Cmd-Tab).
    static func quitIsForcedBySystem(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let reason = event?.attributeDescriptor(forKeyword: quitReasonKeyword) else {
            return false
        }
        switch reason.typeCodeValue {
        case kAEShutDown, kAERestart, kAEReallyLogOut:
            return true
        default:
            return false
        }
    }

    /// The terminal that opening `filename` asks for. A directory opens a
    /// shell there. A file runs as `<file>; exit` in a shell started in its
    /// directory -- not as the command itself, so the shell's profile still
    /// loads (Homebrew and the like) -- and stays open after it exits.
    static func surfaceConfiguration(forOpening filename: String, isDirectory: Bool) -> Tako.SurfaceConfiguration {
        var config = Tako.SurfaceConfiguration()
        if isDirectory {
            config.workingDirectory = filename
        } else {
            config.initialInput = "\(Tako.Shell.quote(filename)); exit\n"
            config.waitAfterCommand = true
            config.workingDirectory = (filename as NSString).deletingLastPathComponent
        }
        return config
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        // Tako will validate as well but we can avoid creating an entirely new
        // surface by doing our own validation here. We can also show a useful error
        // this way.

        var isDirectory = ObjCBool(true)
        guard FileManager.default.fileExists(atPath: filename, isDirectory: &isDirectory) else { return false }

        // Running a file needs the user's go-ahead: a sandboxed application
        // could otherwise escape its sandbox by `open`-ing one with Tako.
        let requiresConfirm = !isDirectory.boolValue
        let config = Self.surfaceConfiguration(forOpening: filename, isDirectory: isDirectory.boolValue)

        if requiresConfirm {
            // Confirmation required. We use an app-wide NSAlert for now. In the future we
            // may want to show this as a sheet on the focused window (especially if we're
            // opening a tab). I'm not sure.
            let alert = NSAlert()
            alert.messageText = "Allow Tako to execute \"\(filename)\"?"
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            switch runModalAlert(alert) {
            case .alertFirstButtonReturn:
                break

            default:
                return false
            }
        }

        switch tako.config.macosDockDropBehavior {
        case .new_tab:
            _ = TerminalController.newTab(
                tako,
                from: TerminalController.preferredParent?.window,
                withBaseConfig: config
            )
        case .new_window: _ = TerminalController.newWindow(tako, withBaseConfig: config)
        }

        return true
    }

    /// Setup signal handlers
    func setupSignals() {
        // Register a signal handler for config reloading. It appears that all
        // of this is required. I've commented each line because its a bit unclear.
        // Warning: signal handlers don't work when run via Xcode. They have to be
        // run on a real app bundle.

        // We need to ignore signals we register with makeSignalSource or they
        // don't seem to handle.
        signal(SIGUSR2, SIG_IGN)

        // Make the signal source and register our event handle. We keep a weak
        // ref to ourself so we don't create a retain cycle.
        let sigusr2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        sigusr2.setEventHandler { [weak self] in
            guard let self else { return }
            Tako.logger.info("reloading configuration in response to SIGUSR2")
            self.tako.reloadConfig()
        }

        // The signal source starts unactivated, so we have to resume it once
        // we setup the event handler.
        sigusr2.resume()

        // We need to keep a strong reference to it so it isn't disabled.
        signals.append(sigusr2)

        // Handle SIGTERM cleanly so that state saving and layout recording
        // run before the process exits.
        signal(SIGTERM, SIG_IGN)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler {
            Tako.logger.info("terminating in response to SIGTERM")
            NSApp.terminate(nil)
        }
        sigterm.resume()
        signals.append(sigterm)
    }

}

