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
        VStack(spacing: 12) {
            Text("Tako Settings")
                .font(.headline)
            Text("Keybindings and configuration are managed via the in-terminal TUI settings card (⌘,).")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Open In-Terminal Settings") {
                if let window = AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows) {
                    TerminalSettingsDialog.show(in: window)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 400, minHeight: 180)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
