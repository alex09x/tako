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

/// In-terminal artifact and document overlay container view (D1).
///
/// Features an origin and sandbox boundary indicator header bar, dismiss button,
/// live file reload notifications, and sandboxed webview document preview.
struct ArtifactOverlayView: View {
    let overlay: OverlayState
    let surfaceView: Tako.SurfaceView
    var theme: TerminalTheme?

    @ObservedObject private var store = OverlayStore.shared

    init(overlay: OverlayState, surfaceView: Tako.SurfaceView, theme: TerminalTheme? = nil) {
        self.overlay = overlay
        self.surfaceView = surfaceView
        self.theme = theme ?? (NSApp.delegate as? AppDelegate)?.tako.config.theme
    }

    private var reloadToken: UUID? {
        store.reloadTokens[overlay.paneId]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerBar

            Divider()
                .background(Color.white.opacity(0.15))

            // Sandboxed Preview Content
            SandboxedWebView(overlay: overlay, reloadToken: reloadToken, theme: theme)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: NSColor(cgColor: theme?.background ?? CGColor(gray: 0.1, alpha: 1.0)) ?? .windowBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 12, x: 0, y: 6)
        .onExitCommand {
            dismiss()
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            // Type badge
            HStack(spacing: 4) {
                Image(systemName: overlay.fileType.systemIconName)
                    .font(.system(size: 11, weight: .bold))
                Text(overlay.fileType.badgeTitle)
                    .font(.system(size: 10, weight: .bold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.2))
            .foregroundColor(.accentColor)
            .cornerRadius(4)

            // Filename
            Text(overlay.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            // Sandboxed origin path indicator
            Text("[sandboxed: \(overlay.sandboxedDirectory.path)]")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer()

            // Manual Reload button
            Button(action: {
                store.reloadOverlay(paneId: overlay.paneId)
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Reload Preview")

            // Close button
            Button(action: {
                dismiss()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("OverlayCloseButton")
            .accessibilityLabel("Close Overlay")
            .accessibilityAction {
                dismiss()
            }
            .help("Close Overlay (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.25))
    }

    private func dismiss() {
        store.closeOverlay(paneId: overlay.paneId)
        // Return focus to the terminal pane
        DispatchQueue.main.async {
            self.surfaceView.window?.makeFirstResponder(self.surfaceView)
        }
    }
}
