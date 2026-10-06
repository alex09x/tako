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
import TakoKit

extension Tako.Config {
    /// Reads `scrollback-limit`, upstream's byte budget for history. Tako
    /// keeps one line of history per 1,000 bytes of it, so upstream's
    /// default of 10 MB is Tako's default of 10,000 lines.
    var scrollbackLimitLines: UInt32 {
        guard let bytes = rawValue("scrollback-limit").flatMap(UInt64.init) else { return 10_000 }
        return UInt32(min(bytes / 1000, UInt64(UInt32.max)))
    }

    /// Reads `mouse-hide-while-typing`, default false.
    var mouseHideWhileTyping: Bool {
        rawBool("mouse-hide-while-typing", default: false)
    }

    /// Reads `mouse-shift-capture`, default `false`: Shift selects unless
    /// the program asks for it.
    var mouseShiftCapture: MouseShiftCapture {
        rawValue("mouse-shift-capture").flatMap(MouseShiftCapture.init(rawValue:)) ?? .off
    }

    /// Reads `cursor-click-to-move`, default true.
    var cursorClickToMove: Bool {
        rawBool("cursor-click-to-move", default: true)
    }

    /// Reads `link-url`, default true.
    var linkURL: Bool {
        rawBool("link-url", default: true)
    }

    /// Reads `safe-paste`, default true.
    /// Protects against accidental execution of pasted multi-line snippets at a shell prompt.
    var safePaste: Bool {
        rawBool("safe-paste", default: true)
    }

    /// Where a finished selection is copied.
    enum CopyOnSelect: String {
        /// Nowhere.
        case off = "false"
        /// The selection pasteboard, which `paste_from_selection` reads.
        case selection = "true"
        /// The selection pasteboard and the general clipboard.
        case clipboard
    }

    /// Reads `copy-on-select`, default true (the selection pasteboard).
    var copyOnSelect: CopyOnSelect {
        rawValue("copy-on-select").flatMap(CopyOnSelect.init(rawValue:)) ?? .selection
    }

    /// When closing a terminal, or quitting, asks first.
    enum ConfirmCloseSurface: String {
        /// Never.
        case never = "false"
        /// While a program other than the shell is running in it.
        case whenBusy = "true"
        /// Always, while the terminal is alive.
        case always
    }

    /// Reads `confirm-close-surface`, default true.
    var confirmCloseSurface: ConfirmCloseSurface {
        rawValue("confirm-close-surface").flatMap(ConfirmCloseSurface.init(rawValue:)) ?? .whenBusy
    }

    /// Focus follows mouse hover in multi-pane splits.
    ///
    /// WHY: Click-to-focus is standard macOS window behavior; default focusFollowsMouse to false.
    var focusFollowsMouse: Bool { rawBool("focus-follows-mouse", default: false) }

    /// Main background color for terminal surfaces.
    ///
    /// WHY: Backed directly by `theme.background` parsed from user's Tako config / active theme.

    /// Dimming opacity applied to non-focused split panes.
    ///
    /// Reads `unfocused-split-opacity`, clamped to 0.15...1, default 0.15.
    /// The value stored here is the dimming amount, `1 - opacity`.
    var unfocusedSplitOpacity: Double {
        guard let raw = rawDouble("unfocused-split-opacity") else { return 0.15 }
        return 1 - min(max(raw, 0.15), 1)
    }

    /// Fill color for unfocused split pane overlay.
    ///
    /// Reads `unfocused-split-fill`, default white.
    var unfocusedSplitFill: Color {
        guard let raw = rawValue("unfocused-split-fill"),
              let color = TerminalTheme.parseColor(raw) else {
            return .white
        }
        return Color(NSColor(cgColor: color) ?? .windowBackgroundColor)
    }

    /// Color of divider lines between split terminal panes.
    ///
    /// It has to differ from the background or the panes run together --
    /// painting the gap in the background colour is the same as having
    /// no divider at all.
    var splitDividerColor: Color {
        Color(red: 0x2A / 255, green: 0x21 / 255, blue: 0x1B / 255)
    }

    /// Screen edge placement for Quick Terminal popup window (top, bottom, left, right).
    ///
    /// Reads `quick-terminal-position`, default `.top`.
    #if canImport(AppKit)
    var quickTerminalPosition: QuickTerminalPosition {
        rawValue("quick-terminal-position").flatMap(QuickTerminalPosition.init(rawValue:)) ?? .top
    }

    /// Target display monitor for Quick Terminal (main, mouse screen, focused screen).
    ///
    /// Reads `quick-terminal-screen`, default `.main`.
    var quickTerminalScreen: QuickTerminalScreen {
        rawValue("quick-terminal-screen").flatMap(QuickTerminalScreen.init(fromTakoConfig:)) ?? .main
    }

    /// Slide animation duration in seconds for Quick Terminal popup.
    ///
    /// Reads `quick-terminal-animation-duration`, default 0.2.
    var quickTerminalAnimationDuration: Double {
        rawDouble("quick-terminal-animation-duration") ?? 0.2
    }

    /// Automatically hide Quick Terminal when losing focus.
    ///
    /// Reads `quick-terminal-autohide`, default true.
    var quickTerminalAutoHide: Bool {
        rawBool("quick-terminal-autohide", default: true)
    }

    /// Behavior of Quick Terminal across macOS Spaces (move to active space vs switch space).
    ///
    /// Reads `quick-terminal-space-behavior`, default `.move`.
    var quickTerminalSpaceBehavior: QuickTerminalSpaceBehavior {
        rawValue("quick-terminal-space-behavior").flatMap(QuickTerminalSpaceBehavior.init(fromTakoConfig:)) ?? .move
    }

    /// Size configuration for Quick Terminal window.
    ///
    /// WHY: Default initializer uses standard half-screen popup dimensions.
    var quickTerminalSize: QuickTerminalSize { QuickTerminalSize() }
    #endif

    /// Trigger condition for pane resize overlay indicator.
    ///
    /// WHY: Upstream shows resize overlay after first resize event.
    var resizeOverlay: ResizeOverlay {
        rawValue("resize-overlay").flatMap(ResizeOverlay.init(rawValue:)) ?? .after_first
    }

    /// Screen alignment position for pane resize overlay.
    ///
    /// WHY: Center of terminal pane is upstream's default overlay position.
    var resizeOverlayPosition: ResizeOverlayPosition {
        rawValue("resize-overlay-position").flatMap(ResizeOverlayPosition.init(rawValue:)) ?? .center
    }

    /// Display duration in milliseconds for pane resize overlay.
    ///
    /// WHY: Upstream displays overlay for 1000ms (1 second).
    var resizeOverlayDuration: UInt { 1000 }

    /// Grace period duration for undoing closed tabs or windows.
    ///
    /// WHY: Upstream default undo timeout is 5 seconds.
    var undoTimeout: Duration { .seconds(5) }

    /// Release channel for automatic software updates (stable vs tip).
    ///
    /// WHY: Default to stable release updates.
    var autoUpdateChannel: AutoUpdateChannel { .stable }

    /// `auto-update`: `off` stops the check at launch; anything else, or
    /// nothing, leaves it on.
    var autoUpdateEnabled: Bool { rawValue("auto-update")?.lowercased() != "off" }

    /// `session-persistence` (experimental, default false): each terminal's
    /// shell runs in a session that outlives Tako, and a relaunch
    /// reattaches to it. Needs a Tako built with its session runtime.
    var sessionPersistence: Bool { rawBool("session-persistence", default: false) }

    /// `remote-control`: whether `takoctl` may drive this app -- `local`
    /// (default; requests from inside a Tako pane), `on` (any process of
    /// this user that can open the socket) or `off` (no socket).
    var remoteControl: RemoteControlMode {
        rawValue("remote-control").flatMap { RemoteControlMode(rawValue: $0.lowercased()) } ?? .local
    }

    /// `window-save-content` (default true): each tab's screen and
    /// scrollback are saved, so a relaunch shows them again. `false`
    /// writes nothing and removes what was saved.
    var windowSaveContent: Bool { rawBool("window-save-content", default: true) }

    /// `window-save-content-limit`: megabytes all saved tabs may take
    /// together, default 64. A tab whose share is too small for its
    /// scrollback is not saved rather than saved cut.
    var windowSaveContentLimit: UInt64 {
        guard let mb = rawDouble("window-save-content-limit"), mb.isFinite, mb >= 0 else { return 64 << 20 }
        // Past a terabyte it means "no practical limit"; the engine caps a
        // single tab far lower anyway.
        return UInt64(min(mb, 1_048_576) * 1_048_576)
    }

    /// Automatic activation of macOS Secure Input during password prompts.
    ///
    /// Reads `macos-auto-secure-input`, default true.
    var autoSecureInput: Bool {
        rawBool("macos-auto-secure-input", default: true)
    }

    /// Visual indicator in titlebar/menu when Secure Input is active.
    ///
    /// Reads `macos-secure-input-indication`, default true.
    var secureInputIndication: Bool {
        rawBool("macos-secure-input-indication", default: true)
    }

    /// Whether double-clicking titlebar maximizes window height/width.
    ///
    /// WHY: Upstream's real default is `false` (confirmed by
    /// ConfigTests.maximizeDefaultsToFalse when this shim's config-key
    /// parsing was added) -- this used to hardcode `true`, which was
    /// simply wrong, not a deliberate divergence like macosTitlebarStyle's.
    var maximize: Bool { rawBool("maximize", default: false) }

    /// Minimum runtime duration required before command exit is considered abnormal.
    ///
    /// WHY: Upstream sets 250ms threshold to detect instant shell crash loops.
    var abnormalCommandExitRuntime: Duration { .milliseconds(250) }

    /// Scrollbar display policy (system default vs never).
    ///
    /// WHY: Respect macOS system scrollbar visibility settings by default.
    var scrollbar: Scrollbar {
        rawValue("scrollbar").flatMap(Scrollbar.init(rawValue:)) ?? .system
    }

    /// Custom entries displayed in command palette popup.
    ///
    /// WHY: Command palette dynamically populates from available actions; default to empty list.
    var commandPaletteEntries: [Tako.Command] { [] }

    /// Terminal command progress indicator style (dock icon / tab progress bar / header / window).
    ///
    /// The `progress-style` setting can turn each surface off (e.g. `dock,tab,header,window`, `none`, `all`).
    var progressStyle: ProgressStyle {
        guard let val = rawValue("progress-style") else { return .all }
        let s = val.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty || s == "true" || s == "all" || s == "1" || s == "yes" {
            return .all
        }
        if s == "false" || s == "none" || s == "0" || s == "no" {
            return .none
        }
        var style: ProgressStyle = []
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for part in parts {
            switch part {
            case "dock": style.insert(.dock)
            case "tab", "tabs": style.insert(.tab)
            case "header", "pane": style.insert(.header)
            case "window": style.insert(.window)
            default: break
            }
        }
        return style
    }
}
