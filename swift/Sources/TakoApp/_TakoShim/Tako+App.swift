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
import SwiftUI
import Combine
import OSLog
import TakoKit

extension Tako {
    // MARK: - Application Object
    /// Upstream's application-level singleton manager.
    /// In our architecture, surface management and core lifecycle are owned per-surface
    /// by TakoCore and PTY. Tako.App holds application readiness state, delegates,
    /// and global clipboard confirmation dispatching.
    open class App: ObservableObject {
        /// Find in All Tabs: one search, shared by every window's panel.
        @MainActor lazy var crossSessionSearch = CrossSessionSearch()

        public enum Readiness: String {
            case loading
            case error
            case ready
        }

        @Published public var readiness: Readiness = .ready {
            didSet {
                let args = CommandLine.arguments
                guard readiness == .ready,
                      args.contains("--selftest-keys")
                        || args.contains("--selftest-input")
                        || args.contains("--selftest-scroll")
                        || args.contains("--selftest-frame") else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    MainActor.assumeIsolated {
                        if args.contains("--selftest-input") {
                            Tako.runInputSelfTest()
                        } else if args.contains("--selftest-scroll") {
                            Tako.runScrollSelfTest()
                        } else if args.contains("--selftest-frame") {
                            Tako.runFrameSelfTest()
                        } else {
                            Tako.runKeySelfTest()
                        }
                    }
                }
            }
        }
        @Published public private(set) var config: Tako.Config
        public weak var delegate: Tako.Delegate?
        /// Upstream force-unwraps this handle, so it must be non-nil from
        /// the start. It carries no state -- the Rust core is reached
        /// through `TakoCore`, not through this handle.
        public var app: tako_app_t? = tako_app_t()

        /// Whether quitting may ask first. Which terminals are busy is each
        /// surface's to say (`SurfaceView.needsConfirmQuit`); the app only
        /// says whether asking is configured at all.
        public var needsConfirmQuit: Bool {
            config.confirmCloseSurface != .never
        }

        /// Where the configuration was loaded from, if not the default
        /// search path. Kept so a reload goes back to the same file.
        private let configPath: String?

        public init(configPath: String? = nil) {
            self.configPath = configPath
            self.config = Tako.Config(at: configPath)
            self.readiness = .ready
        }

        public func appTick() {
            // Unneeded in our Rust core architecture because PTY read loops run asynchronously on background queues.
        }

        public func openConfig() {
            let path = ("~/.config/tako/config" as NSString).expandingTildeInPath
            if !FileManager.default.fileExists(atPath: path) {
                let dir = (path as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? "# Tako configuration\n".write(toFile: path, atomically: true, encoding: .utf8)
            }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }

        public func reloadConfig(soft: Bool = false) {
            // Reload the file we actually loaded. Passing nil here sent every
            // reload back to the default search path, so an app started
            // against a specific config -- a UI test, or anyone using
            // TAKO_CONFIG_PATH -- silently lost it on the first reload.
            let config = Tako.Config(at: configPath)
            self.config = config
            NotificationCenter.default.post(
                name: .takoConfigDidChange,
                object: nil,
                userInfo: [Foundation.Notification.Name.TakoConfigChangeKey: config])
        }

        // Upstream's surface-scoped app calls. They take the view, not a C
        // handle: there is no C surface behind a view here, and a handle
        // that is always nil is how these used to do nothing at all. Calls
        // with no implementation were removed rather than left empty; the
        // controllers reach those through their own actions and
        // notifications.

        /// Double-clicking a divider equalizes the splits around it.
        @MainActor public func splitEqualize(surface: Tako.SurfaceView) {
            NotificationCenter.default.post(name: Tako.Notification.didEqualizeSplits, object: surface)
        }

        /// The window holding `surface` enters or leaves fullscreen.
        @MainActor public func toggleFullscreen(surface: Tako.SurfaceView, mode: FullscreenMode = .native) {
            NotificationCenter.default.post(
                name: Tako.Notification.takoToggleFullscreen,
                object: surface,
                userInfo: [Tako.Notification.FullscreenModeKey: mode])
        }

        public enum FontSizeModification: Equatable {
            case increase(Int)
            case decrease(Int)
            case reset
        }

        @MainActor public func changeFontSize(surface: Tako.SurfaceView, _ change: FontSizeModification) {
            surface.changeFontSize(change)
        }

        @MainActor public func resetTerminal(surface: Tako.SurfaceView) {
            surface.resetTerminal()
        }

        /// A notification names the pane it is about (`surface` in its
        /// user info): clicking it brings that pane forward, if it is open.
        /// If structured notification requested activation or close reporting,
        /// write the escape sequence back to the PTY.
        public func handleUserNotification(response: UNNotificationResponse) {
            let userInfo = response.notification.request.content.userInfo
            if let promptId = userInfo["tako_prompt_id"] as? String {
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        PromptManager.shared.handleNotificationResponse(promptId: promptId, response: response)
                    }
                } else {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            PromptManager.shared.handleNotificationResponse(promptId: promptId, response: response)
                        }
                    }
                }
                return
            }
            guard let raw = userInfo[Tako.notificationSurfaceKey] as? String,
                  let id = UUID(uuidString: raw) else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    guard let pane = ControlCommands.panes().first(where: { $0.surface.id == id }) else { return }
                    Tako.dispatchNotificationResponse(surface: pane.surface, response: response)
                }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let pane = ControlCommands.panes().first(where: { $0.surface.id == id }) else { return }
                        Tako.dispatchNotificationResponse(surface: pane.surface, response: response)
                    }
                }
            }
        }

        /// While Tako is in front its own notifications stay quiet -- the
        /// tab shows what happened -- except one a script posted on purpose
        /// with `takoctl notify`, or an explicit structured notification
        /// unless suppressed by macOS Focus or only-when-unfocused mode.
        public func shouldPresentNotification(notification: UNNotification) -> Bool {
            let userInfo = notification.request.content.userInfo
            var isLookedAt = false
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    if let surfaceRaw = userInfo[Tako.notificationSurfaceKey] as? String,
                       let surfaceId = UUID(uuidString: surfaceRaw) {
                        let pane = ControlCommands.panes().first(where: { $0.surface.id == surfaceId })
                        isLookedAt = pane?.surface.isBeingLookedAt ?? false
                    }
                }
            }
            return Tako.shouldPresent(userInfo: userInfo, surfaceLookedAt: isLookedAt)
        }

        /// Completes an asynchronous clipboard read or paste operation.
        /// Upstream calls this callback after paste confirmation or clipboard retrieval.
        public static func completeClipboardRequest(
            _ surface: tako_surface_t,
            data: String,
            state: UnsafeMutableRawPointer?,
            confirmed: Bool = false
        ) {
            tako_surface_complete_clipboard_request(surface, data, state, confirmed)
        }

        public static func completeClipboardRequest(
            _ surfaceView: Tako.SurfaceView,
            data: String,
            state: UnsafeMutableRawPointer?,
            confirmed: Bool = false
        ) {
            // `pasteText` is main-actor isolated because it touches the view;
            // execute directly on the main thread or dispatch asynchronously if on background.
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    surfaceView.pasteText(data)
                }
            } else {
                DispatchQueue.main.async { surfaceView.pasteText(data) }
            }
        }
    }

    // MARK: - Surface Model & Configuration
    /// Lightweight configuration for initializing new surfaces.
    /// Everything a new surface can be seeded with. The AppleScript layer
    /// converts these to and from a scripting record, so the member names
    /// are upstream's record keys.
    /// Run the key path against the real `keyDown` and write what came out.
    ///
    /// Reproducing a keyboard bug from outside the process needs
    /// Accessibility permission, which a build like this does not have. This
    /// builds the events itself and reports what each one produced.
    /// Does a precise trackpad delta move the grid by a fraction of a row?
    ///
    /// The arithmetic has unit tests, but they run against the accumulator in
    /// isolation. This asks the question of the shipped app: real scroll
    /// events, through the real responder chain, into the surface the window
    /// actually contains -- which is the part that was a second, unmaintained
    /// terminal until recently.
    /// Where the self-tests write their reports. `TAKO_SELFTEST_DIR`
    /// overrides /tmp, so two runs on one machine -- or a test suite running
    /// beside the app's own self-test -- do not overwrite each other's files.
    nonisolated(unsafe) static var selfTestReportDirectory: String =
        ProcessInfo.processInfo.environment["TAKO_SELFTEST_DIR"] ?? "/tmp"

    static func selfTestReportPath(_ name: String) -> String {
        (selfTestReportDirectory as NSString).appendingPathComponent(name)
    }


    /// The surface holding the keys currently, so a new tab, split or window
    /// can start where it is.
    @MainActor private static var focusedSurfaceInKeyWindow: SurfaceView? {
        guard let window = NSApplication.shared.keyWindow else { return nil }
        func find(_ view: NSView) -> SurfaceView? {
            if let surface = view as? SurfaceView, surface.isFirstResponderSurface {
                return surface
            }
            for sub in view.subviews {
                if let found = find(sub) { return found }
            }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    /// Where the surface holding the keys currently is, so a new tab can
    /// open in the same place.
    @MainActor static var focusedWorkingDirectory: String? {
        focusedSurfaceInKeyWindow?.pwd
    }

    /// The font size (in points, possibly zoomed) of the surface holding the
    /// keys currently, so a new window, tab or split can start at it.
    @MainActor static var focusedFontSize: CGFloat? {
        focusedSurfaceInKeyWindow?.theme.fontSize
    }

    /// Where a terminal starts when nothing else supplies a directory:
    /// `working-directory`, resolved to an actual path.
    static func resolvedWorkingDirectory(_ config: Tako.Config) -> String {
        switch config.workingDirectory {
        case .path(let path): return (path as NSString).expandingTildeInPath
        case .home: return NSHomeDirectory()
        case .inherit: return FileManager.default.currentDirectoryPath
        }
    }

    /// What a window or a tab is called when the shell has not said.
    ///
    /// The last path component, which is what identifies a project at a
    /// glance. Home and root have no useful basename, so they get `~` and
    /// `/` respectively -- but a bare `/` as a title is meaningless in a
    /// tab strip, so home wins when the directory is either.
    static func titleForDirectory(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let home = NSHomeDirectory()
        if expanded == home || expanded == "/" || expanded.isEmpty { return "~" }
        let name = (expanded as NSString).lastPathComponent
        return name.isEmpty ? "~" : name
    }

}
