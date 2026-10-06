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
        func configDidReload(_ config: Tako.Config) {
            guard let owningApp, config === owningApp.config else { return }
            applySurfaceConfig(config)
            updateTheme(config.theme)
        }

        /// The config keys that belong to a terminal rather than its window.
        /// Attaches a surface built without an app -- one decoded from saved
        /// window state -- to the app whose window now holds it, so its config
        /// applies and its reloads arrive. A surface that has an app keeps it.
        func adopt(by app: Tako.App) {
            guard owningApp == nil else { return }
            owningApp = app
            derivedConfig = DerivedConfig(app.config)
            applySurfaceConfig(app.config)
            updateTheme(app.config.theme)
            if configObserver == nil {
                observeConfigReload()
            }
        }

        /// `Tako.App.reloadConfig()` replaces the app's config and announces
        /// it; nothing else reaches the surfaces already on screen, so each
        /// one listens and takes what applies to it.
        func observeConfigReload() {
            configObserver = NotificationCenter.default.addObserver(
                forName: .takoConfigDidChange, object: nil, queue: nil
            ) { [weak self] note in
                guard let config = note.userInfo?[Foundation.Notification.Name.TakoConfigChangeKey]
                        as? Tako.Config else { return }
                // The reload may be announced from any thread; a view is
                // only touched on the main one.
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.configDidReload(config) }
                } else {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.configDidReload(config) }
                    }
                }
            }
        }

        func applySurfaceConfig(_ config: Tako.Config) {
            optionAsAlt = config.macosOptionAsAlt
            hidesMouseWhileTyping = config.mouseHideWhileTyping
            copyOnSelect = config.copyOnSelect
            confirmCloseSurface = config.confirmCloseSurface
            mouseShiftCapture = config.mouseShiftCapture
            cursorClickToMove = config.cursorClickToMove
            linkURLDetectionEnabled = config.linkURL
            safePaste = config.safePaste
            commandMarksEnabled = config.commandMarks
            commandDurationsEnabled = config.commandDurations
            commandTimestampsEnabled = config.commandTimestamps
            stickyCommandHeaderEnabled = config.stickyCommandHeader
            paneProgressBarEnabled = config.progressStyle.showsInHeader
            configuredEditorCommand = config.editor
            core.setScrollbackLimit(lines: config.scrollbackLimitLines)
            core.setClipboardReadAllowed(allowed: config.clipboardRead)
            updateActiveRegexTriggers(config: config)
        }


        /// Whether closing this terminal should ask first
        /// (`confirm-close-surface`): never once its shell has exited or when
        /// set false; always when set always; otherwise while a program other
        /// than the shell holds the terminal -- the tty's foreground process
        /// group is not the shell's. That needs no shell integration.
        /// Whether quitting should ask. With a persistent session quitting
        /// ends nothing (the session keeps running), so only `always` asks.
        public var needsConfirmQuit: Bool {
            if persistence != nil { return confirmCloseSurface == .always }
            return needsConfirmEnding
        }

        /// Whether closing this terminal should ask -- closing ends its
        /// process, or its persistent session. A session's own foreground
        /// program cannot be seen from here, so with one Tako asks unless
        /// told `never`.
        var needsConfirmClose: Bool {
            if persistence != nil { return confirmCloseSurface != .never }
            return needsConfirmEnding
        }

        var needsConfirmEnding: Bool {
            guard let pty, pty.alive else { return false }
            switch confirmCloseSurface {
            case .never:
                return false
            case .always:
                return true
            case .whenBusy:
                guard let foreground = pty.foregroundPID else { return false }
                return foreground != Int(pty.child)
            }
        }
}
