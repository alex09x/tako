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

/// Banner presented at the top of a restored terminal pane offering
/// to resume the previous agent session (C6).
public struct ResumeBannerView: View {
    public let command: String
    public let cwd: String
    public let isImported: Bool
    public let onResume: (_ alwaysAllow: Bool) -> Void
    public let onDismiss: () -> Void

    public init(
        command: String,
        cwd: String,
        isImported: Bool = false,
        onResume: @escaping (_ alwaysAllow: Bool) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.command = command
        self.cwd = cwd
        self.isImported = isImported
        self.onResume = onResume
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundColor(.accentColor)
                .font(.system(size: 16, weight: .semibold))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Resume Agent Session:")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)

                    if isImported {
                        Text("[Imported]")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(4)
                    }
                }

                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button(action: { onResume(false) }) {
                    Text("Resume")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if !isImported {
                    Button(action: { onResume(true) }) {
                        Text("Always Allow")
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.95))
                .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}
