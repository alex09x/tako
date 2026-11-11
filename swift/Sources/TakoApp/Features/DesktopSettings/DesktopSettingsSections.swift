/*
 * tako — Desktop settings pages: the reference's blocks over real keys
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

/// Page bodies follow PF_PAGES (prefs-window.js, prefs-detail.js). Every row
/// reads and writes the real config through DesktopPreferenceStore.
struct DesktopSettingsSectionBody: View {
    @ObservedObject var model: DesktopSettingsModel
    let palette: DesktopPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.section {
            case .general: general
            case .interface: interface
            case .terminalAppearance:
                DesktopAppearanceSection(model: model, scope: model.scope, themes: model.themes, palette: palette)
            case .input: input
            case .windows: windows
            case .quickTerminal: quickTerminal
            case .status: activity
            case .keys: DesktopKeysSection(model: model, recorder: model.recorder, palette: palette)
            case .agents:
                SetupAgentsStep(model: model.setup).task { await model.setup.refresh() }
            case .notifications:
                // The same list as the first-run «Permissions» (reference A15), notifications first.
                SetupPermissionPanel(model: model.setup).task { await model.setup.refresh() }
            case .advanced: advanced
            }
        }
    }

    private func rows(_ keys: [String]) -> some View {
        ForEach(keys, id: \.self) { DesktopRegistryRow(key: $0, preferences: model.preferences, palette: palette) }
    }

    private var general: some View {
        Group {
            DesktopBlock(title: "Closing", palette: palette) { rows(["confirm-close-surface"]) }
            DesktopBlock(title: "New Windows & Terminals", palette: palette) {
                rows(["window-inherit-working-directory", "window-inherit-font-size"])
            }
            DesktopBlock(title: "First Run", palette: palette) {
                DesktopPrefRow(title: "Set Up Tako", detail: "Choose a theme, connect agents and review permissions. You can finish later.",
                               key: "Tako › Set Up Tako…", palette: palette) {
                    Button("Open Setup…") {
                        model.onClose()
                        NSApp.sendAction(#selector(AppDelegate.showSetup(_:)), to: nil, from: nil)
                    }
                    .buttonStyle(DesktopButtonStyle(palette: palette))
                    .accessibilityIdentifier("DesktopOpenSetup")
                }
            }
        }
    }

    private var interface: some View {
        Group {
            DesktopBlock(title: "Color Scheme", note: "Sidebar, canvas, menus and settings", palette: palette) { rows(["app-appearance"]) }
            DesktopBlock(title: "Sidebar", note: "How sessions are listed; only the look changes", palette: palette) {
                DesktopSidebarStylePicker(preferences: model.preferences, palette: palette)
                rows(["sidebar-group", "sidebar-text-size", "sidebar-secondary-text"])
            }
            DesktopBlock(title: "Interface Text", palette: palette) {
                DesktopPrefRow(title: "Interface font and size",
                               detail: "Uses the macOS system font and size. Terminal Appearance controls terminal text independently; ⌘+ / ⌘− zoom only the terminal.",
                               key: "System setting · no separate configuration key", palette: palette) { EmptyView() }
            }
            DesktopBlock(title: "Terminal Theme Scope", palette: palette) {
                DesktopHint(text: "Terminal themes control the background, text, ANSI colors, cursor, selection and font. App appearance, focus borders and status colors remain independent.",
                            palette: palette)
            }
        }
    }

    private var input: some View {
        Group {
            DesktopBlock(title: "Cursor", note: "For all terminals unless overridden by their theme", palette: palette) {
                rows(["cursor-style", "cursor-style-blink"])
            }
            DesktopBlock(title: "Mouse & Selection", palette: palette) { rows(["mouse-hide-while-typing", "copy-on-select"]) }
            DesktopBlock(title: "Paste", palette: palette) { rows(["safe-paste"]) }
            DesktopBlock(title: "Shell", palette: palette) { rows(["shell-integration"]) }
        }
    }

    private var windows: some View {
        Group {
            DesktopBlock(title: "Workspace", palette: palette) { rows(["workspace-sync-window-frame"]) }
            DesktopBlock(title: "Window", note: "Tab style is not shown because this layout has no top tab bar",
                         palette: palette) { rows(["background-blur"]) }
        }
    }

    private var quickTerminal: some View {
        Group {
            DesktopBlock(title: "Position", note: "A drop-down terminal without a sidebar", palette: palette) {
                rows(["quick-terminal-position", "quick-terminal-autohide"])
            }
            DesktopBlock(title: "Activation", palette: palette) {
                DesktopPrefRow(title: "Shortcut", detail: "Available while Tako is active.",
                               key: "toggle_quick_terminal", palette: palette) {
                    HStack(spacing: 8) {
                        DesktopShortcutCaps(text: model.recorder.display(for: "toggle_quick_terminal"), palette: palette)
                        Button("Edit…") { model.showShortcut("toggle_quick_terminal") }
                            .buttonStyle(DesktopButtonStyle(palette: palette))
                            .accessibilityIdentifier("DesktopQuickTerminalShortcut")
                    }
                }
            }
        }
    }

    private var activity: some View {
        Group {
            DesktopBlock(title: "Indicators", note: "Focus and program status are independent", palette: palette) {
                DesktopStatusSamples(palette: palette)
                rows(["status-show", "status-animate"])
            }
            DesktopBlock(title: "Colors", note: "tab-status-color-*", palette: palette) {
                rows(["working", "waiting", "done", "error", "idle"].map { "tab-status-color-\($0)" })
                DesktopHint(text: "Status colors are shared across themes. Waiting for input and approval use the same status color.",
                            palette: palette)
            }
            DesktopBlock(title: "Sidebar Counts", palette: palette) {
                rows(["sidebar-count-waiting", "sidebar-count-error", "sidebar-count-done"])
                DesktopHint(text: "Counts terminal statuses and unread completions. Each terminal is counted once.",
                            palette: palette)
            }
            DesktopBlock(title: "Notifications", note: "Independent of visual indicators", palette: palette) {
                DesktopPrefRow(title: "Permission and sound", detail: "Manage banners, sounds and badges in macOS settings.", palette: palette) {
                    Button("Notifications & Permissions…") { model.section = .notifications }
                        .buttonStyle(DesktopButtonStyle(palette: palette))
                }
            }
        }
    }

    private var advanced: some View {
        Group {
            DesktopBlock(title: "Storage", palette: palette) {
                VStack(alignment: .leading, spacing: 6) {
                    storage(model.configFile.configPath ?? "Configuration file not found", "Global settings, global theme and keyboard shortcuts")
                    storage(model.themes.store.directory.path, "Custom themes, one file per theme")
                    storage(model.themes.scopes.fileURL.path, "Workspace and terminal appearance")
                }
                HStack(spacing: 8) {
                    Button("Show in Finder") { model.revealConfig() }.buttonStyle(DesktopButtonStyle(palette: palette))
                    Button("Reload Configuration") { DesktopThemeLibrary.reloadLiveApp() }
                        .buttonStyle(DesktopButtonStyle(palette: palette))
                        .accessibilityIdentifier("DesktopReloadConfig")
                }.padding(.top, 8)
            }
            DesktopBlock(title: "Configuration", note: "The configuration currently saved on disk", palette: palette) {
                ScrollView {
                    Text(model.configText.isEmpty ? "# Empty — using default settings" : model.configText)
                        .font(.system(size: 11.5, design: .monospaced)).lineSpacing(3)
                        .foregroundStyle(Color(palette.secondary)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .frame(maxHeight: 300)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color(palette.field)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(palette.separator)))
            }
        }
    }

    private func storage(_ path: String, _ what: String) -> some View {
        HStack(spacing: 8) {
            Text(path).font(.system(size: DesktopSettingsStyle.keySize, design: .monospaced))
                .foregroundStyle(Color(palette.secondary)).lineLimit(1).truncationMode(.middle)
            Text(what).font(.system(size: DesktopSettingsStyle.captionSize)).foregroundStyle(Color(palette.muted))
        }
    }
}

/// The footer outside the theme editor: always mounted, it observes every
/// store that can fail or change the level, so a refused value («73 pt»)
/// shows its error at once, and «Reset Appearance» appears with the
/// level's first override (also one written from a context menu).
struct DesktopSettingsFooterStatus: View {
    @ObservedObject var model: DesktopSettingsModel
    @ObservedObject var preferences: DesktopPreferenceStore
    @ObservedObject var scope: DesktopScopeEditor
    @ObservedObject var themes: DesktopThemeLibrary
    @ObservedObject var recorder: DesktopShortcutRecorder
    let showsReset: Bool
    let palette: DesktopPalette
    /// Bumped when scoped appearance changes outside this editor.
    @State private var scopedRevision = 0

    var error: String? { scope.lastError ?? preferences.lastError ?? themes.lastError ?? recorder.lastError }

    var body: some View {
        let _ = scopedRevision
        Group {
            if let error {
                Text(error).font(.system(size: DesktopSettingsStyle.captionSize)).lineLimit(2)
                    .foregroundStyle(Color(palette.accentBright))
                    .accessibilityIdentifier("DesktopSettingsError")
                    .background(DesktopViewMarker("DesktopSettingsError"))
            } else {
                Text("Tako \(model.version) · changes save immediately · Esc to close")
                    .font(.system(size: DesktopSettingsStyle.captionSize)).foregroundStyle(Color(palette.muted))
                    .accessibilityIdentifier("DesktopSettingsVersion")
                    .background(DesktopViewMarker("DesktopSettingsVersion"))
            }
        }
        Spacer(minLength: 0)
        if showsReset, !scope.isGlobal, scope.hasOwnOverrides {
            Button("Reset Appearance: \(scope.title)") { scope.resetAll() }
                .buttonStyle(DesktopButtonStyle(palette: palette))
                .help("Remove overrides at this level only; other levels keep their own settings")
                .accessibilityIdentifier("DesktopScopeResetAll")
                .background(DesktopViewMarker("DesktopScopeResetAll"))
        }
        Color.clear.frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .takoScopedAppearanceDidChange)) { _ in
                scopedRevision &+= 1
            }
    }
}
