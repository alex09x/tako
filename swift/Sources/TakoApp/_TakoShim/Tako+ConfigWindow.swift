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
    /// Features enabled for terminal bell alerts.
    ///
    /// WHY: Bell alerts are handled natively by macOS system beeps in our core; default to empty set.
    var bellFeatures: BellFeatures { .init() }

    /// Custom audio file path for bell sounds.
    ///
    /// WHY: Custom audio file loading for bell is not yet supported in Rust core; return nil for system default.
    var bellAudioPath: Tako.ConfigPath? { nil }

    /// Volume level for bell audio playback (0.0 to 1.0).
    ///
    /// WHY: Upstream default audio volume is 0.5.
    var bellAudioVolume: Float { 0.5 }

    /// `notify-on-command-finish`: `never` (default), `unfocused` -- only
    /// for a terminal that is not the one being looked at -- or `always`.
    /// Needs shell integration: only its command marks say when a
    /// command started and how it ended.
    var notifyOnCommandFinish: NotifyOnCommandFinish {
        rawValue("notify-on-command-finish").flatMap { NotifyOnCommandFinish(rawValue: $0.lowercased()) } ?? .never
    }

    /// `notify-on-command-finish-action`: a comma list of `bell`,
    /// `notify` and their `no-` forms, applied over the default `bell`.
    var notifyOnCommandFinishAction: NotifyOnCommandFinishAction {
        NotifyOnCommandFinishAction(parsing: rawValue("notify-on-command-finish-action"))
    }

    /// `notify-on-command-finish-after` (default `5s`): commands shorter
    /// than this never signal. Units `ms`, `s`, `m`, `h`, combinable
    /// (`1m30s`); a bare number is seconds.
    var notifyOnCommandFinishAfter: Duration {
        rawValue("notify-on-command-finish-after").flatMap(Tako.parseDuration) ?? .seconds(5)
    }

    /// Preserved zoom state when splitting panes.
    ///
    /// WHY: Pane zoom preservation is managed by our layout tree in Swift/Rust core; return empty options.
    var splitPreserveZoom: SplitPreserveZoom { .init() }

    /// Whether an initial terminal window should open on launch.
    ///
    /// WHY: Tako opens a main window upon launch unless configured headless; default to true.
    var initialWindow: Bool { rawBool("initial-window", default: true) }

    /// Whether the application should terminate after the last window closes.
    ///
    /// WHY: Standard macOS multi-window app behavior keeps app running when last window closes; default to false.
    var shouldQuitAfterLastWindowClosed: Bool { rawBool("quit-after-last-window-closed", default: false) }

    /// Custom title string override for the terminal window.
    ///
    /// WHY: Window titles are dynamically emitted by shell escape sequences in Rust core unless overridden.
    var title: String? { rawValue("title") }

    /// Whether windows come back after a restart.
    ///
    /// "always", not the system default: the system default depends on
    /// the "Close windows when quitting" checkbox in System Settings,
    /// and losing your window layout on every restart is not something
    /// a terminal should leave to a global preference. `never` turns it
    /// off; `default` leaves it to that checkbox.
    var windowSaveState: String {
        switch rawValue("window-save-state")?.lowercased() {
        case "never": return "never"
        case "default": return "default"
        default: return "always"
        }
    }

    /// Initial X coordinate position for new windows.
    ///
    /// WHY: Window positioning is left to macOS window manager auto-placement.
    var windowPositionX: Int16? { rawValue("window-position-x").flatMap(Int16.init) }

    /// Initial Y coordinate position for new windows.
    ///
    /// WHY: Window positioning is left to macOS window manager auto-placement.
    var windowPositionY: Int16? { rawValue("window-position-y").flatMap(Int16.init) }

    /// Target tab position when creating new tabs ("current" or "end").
    ///
    /// Reads `window-new-tab-position`. `TerminalController.newTab`'s
    /// consuming switch treats anything but "end" as "current", so an
    /// unset or unrecognised value is passed through unchanged rather
    /// than normalized.
    var windowNewTabPosition: String {
        switch rawValue("window-new-tab-position") {
        case "end": return "end"
        case "current": return "current"
        default: return ""
        }
    }

    /// New window terminal size in columns x rows, from `window-width`
    /// and `window-height`. Both are required -- upstream ignores
    /// either alone -- and each is clamped to upstream's minimum (10
    /// columns, 4 rows). Sizes only a brand-new window's terminal area;
    /// never a tab or a split.
    var windowSizeInCells: (columns: Int, rows: Int)? {
        guard let width = rawValue("window-width").flatMap(Int.init),
              let height = rawValue("window-height").flatMap(Int.init) else { return nil }
        return (max(width, 10), max(height, 4))
    }

    /// Where the app's very first terminal starts, from `working-directory`.
    enum WorkingDirectory: Equatable {
        /// A fixed path.
        case path(String)
        /// The user's home directory.
        case home
        /// Wherever the app process itself was launched with.
        case inherit
    }

    /// Reads `working-directory`. An unset value defaults to `.inherit`
    /// when the app was launched from a shell (which sets `TERM` before
    /// exec'ing it) and `.home` when launched from Finder or the Dock
    /// (which does not).
    var workingDirectory: WorkingDirectory {
        switch rawValue("working-directory") {
        case "home": return .home
        case "inherit": return .inherit
        case let path? where !path.isEmpty: return .path(path)
        default: return ProcessInfo.processInfo.environment["TERM"] != nil ? .inherit : .home
        }
    }

    /// Whether a new window, tab or split starts in the focused
    /// terminal's directory instead of `working-directory`.
    ///
    /// Reads `window-inherit-working-directory`, default true.
    var windowInheritWorkingDirectory: Bool {
        rawBool("window-inherit-working-directory", default: true)
    }

    /// Whether a new window, tab or split starts at the focused
    /// terminal's current (possibly zoomed) font size instead of the
    /// configured one.
    ///
    /// Reads `window-inherit-font-size`, default true.
    var windowInheritFontSize: Bool {
        rawBool("window-inherit-font-size", default: true)
    }

    /// Whether thin marks appear beside command prompt lines in the gutter
    /// and on the scrollbar track.
    ///
    /// Reads `command-marks`, default true.
    var commandMarks: Bool {
        rawBool("command-marks", default: true)
    }

    /// Whether elapsed durations appear beside command marks in the gutter (E10).
    /// Reads `command-durations`, default false.
    var commandDurations: Bool {
        rawBool("command-durations", default: false)
    }

    /// Whether start timestamps appear beside command marks in the gutter (E10).
    /// Reads `command-timestamps`, default false.
    var commandTimestamps: Bool {
        rawBool("command-timestamps", default: false)
    }

    /// Whether the sticky command header stays pinned at the top while scrolling through long output.
    ///
    /// Reads `sticky-command-header`, default true.
    var stickyCommandHeader: Bool {
        rawBool("sticky-command-header", default: true)
    }

    /// The configured editor command for opening semantic paths (Cmd+Click) (E6).
    /// Reads `editor`, falls back to $EDITOR, $VISUAL, or "code".
    var editor: String? {
        rawValue("editor")
    }

    /// Whether passive regex triggers are enabled (E7).
    /// Reads `passive-regex-triggers`, default true.
    var passiveRegexTriggers: Bool {
        rawBool("passive-regex-triggers", default: true)
    }

    /// Whether escape sequences may query/read the host clipboard (OSC 52 ; ... ; ?) (Track G4).
    /// Reads `clipboard-read`, default false (policy: WriteOnly).
    var clipboardRead: Bool {
        rawBool("clipboard-read", default: false)
    }

    /// Which bundled shell-integration script, if any, is injected into
    /// a new shell.
    enum ShellIntegration: String {
        /// Inject nothing.
        case none
        /// Detect from the login shell -- today's behavior.
        case detect
        case bash, elvish, fish, zsh
    }

    /// Reads `shell-integration`, default `.detect`.
    var shellIntegration: ShellIntegration {
        rawValue("shell-integration").flatMap(ShellIntegration.init(rawValue:)) ?? .detect
    }

    /// Raw comma list from `shell-integration-features`, applied over
    /// Tako's own defaults (`sudo`, `prompt`, `highlight`) by
    /// `PTY.shellFeatures`: a bare name enables it, `no-<name>` disables
    /// it. `nil` when unset, so the defaults are used unmodified.
    var shellIntegrationFeatures: String? {
        rawValue("shell-integration-features")
    }

    /// Whether standard window decorations (titlebar and borders) are visible.
    ///
    /// WHY: Tako windows show standard titlebar decorations by default; `window-decoration
    /// = none` (upstream's only value this shim distinguishes) turns them off.
    var windowDecorations: Bool { rawValue("window-decoration") != "none" }


    /// Whether window resize snaps to character cell grid steps.
    ///
    /// WHY: Upstream default allows smooth continuous window resizing.
    var windowStepResize: Bool { rawBool("window-step-resize", default: false) }

    /// Current active fullscreen display mode, or nil if not fullscreen.
    ///
    /// WHY: Window controllers toggle fullscreen mode dynamically at runtime; initial default is nil.
    #if canImport(AppKit)
    var windowFullscreen: FullscreenMode? { nil }
    #else
    var windowFullscreen: Bool { false }
    #endif

    /// Preferred fullscreen style for toggle actions (native vs non-native borderless).
    ///
    /// WHY: Native macOS space fullscreen is upstream's default behavior.
    #if canImport(AppKit)
    var windowFullscreenMode: FullscreenMode { .native }
    #endif

    /// Custom font family specified for titlebar text.
    ///
    /// WHY: `window-title-font-family` is a distinct key from `font-family` (which backs
    /// `theme.fontFamily`), so it's read from the raw config directly rather than the theme.
    var windowTitleFontFamily: String? { rawValue("window-title-font-family") }

    /// Visibility of window control buttons (close, minimize, zoom).
    ///
    /// WHY: Upstream default keeps window buttons visible.
    var macosWindowButtons: Tako.MacOSWindowButtons {
        rawValue("macos-window-buttons").flatMap(Tako.MacOSWindowButtons.init(rawValue:)) ?? .visible
    }

    /// Titlebar style for macOS windows (transparent, tabs, native, hidden).
    ///
    /// WHY: the design puts the tabs in the titlebar, coloured by the
    /// terminal itself. Upstream already implements exactly that under
    /// the `tabs` style -- there is no reason to draw a tab bar by hand.
    /// This is a deliberate product default, not upstream's own
    /// (upstream defaults to `.transparent`) -- an explicit
    /// `macos-titlebar-style` config line still overrides it either way.
    var macosTitlebarStyle: MacOSTitlebarStyle {
        rawValue("macos-titlebar-style").flatMap(MacOSTitlebarStyle.init(rawValue:)) ?? .tabs
    }

    /// Visibility of the file/folder proxy icon in the window titlebar.
    ///
    /// Reads `macos-titlebar-proxy-icon`, default `.visible`.
    var macosTitlebarProxyIcon: Tako.MacOSTitlebarProxyIcon {
        rawValue("macos-titlebar-proxy-icon").flatMap(Tako.MacOSTitlebarProxyIcon.init(rawValue:)) ?? .visible
    }

    /// Drag-and-drop file behavior on dock icon (new tab vs new window).
    ///
    /// WHY: Opening dropped files in a new tab matches upstream default.
    var macosDockDropBehavior: MacDockDropBehavior { .new_tab }

    /// Whether windows drop a standard macOS shadow effect.
    ///
    /// WHY: Standard macOS windows render system shadows.
    var macosWindowShadow: Bool { rawBool("macos-window-shadow", default: true) }

    /// Selected app icon variant.
    ///
    /// WHY: Default to official Tako branding.
    var macosIcon: Tako.MacOSIcon {
        rawValue("macos-icon").flatMap(Tako.MacOSIcon.init(rawValue:)) ?? .official
    }

    /// Path to custom `.icns` file if `macosIcon == .custom`.
    ///
    /// WHY: Returns empty path when no custom icon is specified.
    var macosCustomIcon: String { "" }

    /// Frame material around custom app icons.
    ///
    /// WHY: Upstream default icon frame material is aluminum.
    var macosIconFrame: Tako.MacOSIconFrame {
        rawValue("macos-icon-frame").flatMap(Tako.MacOSIconFrame.init(rawValue:)) ?? .aluminum
    }

    /// Custom tint color for the "custom-style" app icon's mark.
    ///
    /// Parsed from `macos-icon-ghost-color`, upstream's color syntax.
    /// Upstream tints its own trademarked ghost graphic with this; here
    /// it colours Tako's own mark instead (see `CustomStyleIcon.swift`).
    /// `nil` when unset or unparsable, in which case `AppIcon` falls
    /// back to the brand default.
    var macosIconGhostColor: OSColor? {
        rawValue("macos-icon-ghost-color").flatMap(TerminalTheme.parseColor).flatMap(OSColor.init(cgColor:))
    }

    /// Custom background colors for the "custom-style" app icon's screen
    /// gradient, in `macos-icon-screen-color`'s comma-separated order.
    ///
    /// `nil` when unset or every entry is unparsable, in which case
    /// `AppIcon` falls back to the brand default gradient.
    var macosIconScreenColor: [OSColor]? {
        guard let raw = rawValue("macos-icon-screen-color") else { return nil }
        let colors = raw.split(separator: ",")
            .compactMap { TerminalTheme.parseColor($0.trimmingCharacters(in: .whitespaces)) }
            .compactMap { OSColor(cgColor: $0) }
        return colors.isEmpty ? nil : colors
    }

    /// Application visibility in dock and app switcher (always hidden, never hidden, etc.).
    ///
    /// Reads `macos-hidden`, default `.never`.
    var macosHidden: MacHidden {
        rawValue("macos-hidden").flatMap(MacHidden.init(rawValue:)) ?? .never
    }

    /// Which Option key, if any, acts as Alt (sends ESC + base key)
    /// instead of composing characters.
    ///
    /// Reads `macos-option-as-alt`, default `.off` (today's behaviour).
    var macosOptionAsAlt: OptionAsAlt {
        rawValue("macos-option-as-alt").flatMap(OptionAsAlt.init(rawValue:)) ?? .off
    }
}
