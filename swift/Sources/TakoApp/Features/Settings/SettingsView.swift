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
import SwiftUI

/// Settings view container. Primary settings and keybindings are presented
/// through the in-terminal TUI card (TerminalSettingsDialog).
public struct SettingsView: View {
    @EnvironmentObject private var appDelegate: AppDelegate

    public init() {}

    public var body: some View {
        VStack(spacing: 14) {
            Text("Tako Settings")
                .font(.headline)
            Text("Keybindings, terminal behavior, and workspace options are managed via the in-terminal TUI settings card (⌘,).")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Terminal Settings") {
                    if let window = AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows) {
                        TerminalSettingsDialog.show(in: window, tab: .terminalSettings)
                    }
                }
                Button("Keybindings") {
                    if let window = AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows) {
                        TerminalSettingsDialog.show(in: window, tab: .keybindings)
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 440, minHeight: 180)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
