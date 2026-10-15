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

/// A single card in the pane overview grid, showing thumbnail preview, status, and metadata.
struct PaneOverviewCard: View, Equatable {
    let item: PaneOverviewItem
    let isSelected: Bool

    var body: some View {
        let chipColor = Color(nsColor: item.chipColor)

        VStack(alignment: .leading, spacing: 6) {
            // Card Top Row: UI Kit Status Chip + full-width status text (provenance moved to footer per P2 #13)
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    if item.status.isWaitingForHuman {
                        Circle()
                            .stroke(chipColor, lineWidth: 1.5)
                            .frame(width: 6, height: 6)
                    } else {
                        Circle()
                            .fill(chipColor)
                            .frame(width: 6, height: 6)
                    }

                    Text(item.chipLabel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(chipColor)
                        .lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(chipColor.opacity(0.10))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(chipColor.opacity(0.25), lineWidth: 1)
                )

                if let text = item.statusText, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(Color(nsColor: PaneOverviewPalette.dim))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)
            }

            // Pane Title
            Text(item.title)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(Color(nsColor: PaneOverviewPalette.activeText))
                .lineLimit(1)
                .truncationMode(.tail)

            // Live Thumbnail: Terminal Output Preview
            thumbnailView(item: item)

            // Card Footer: Working directory, dim elapsed timer (P2 #8), and Workspace · Tab tag (P2 #13)
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: PaneOverviewPalette.dim))

                Text(item.directoryDisplay)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(nsColor: PaneOverviewPalette.dim))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                Spacer(minLength: 4)

                if let elapsed = item.elapsed {
                    Text(elapsed)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(Color(nsColor: PaneOverviewPalette.dim))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                Text(item.workspaceName.isEmpty ? "Tab \(item.tabIndex + 1)" : "\(item.workspaceName) · Tab \(item.tabIndex + 1)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(Color(nsColor: PaneOverviewPalette.inactiveText))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: PaneOverviewPalette.badge))
                    .cornerRadius(4)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: isSelected ? PaneOverviewPalette.selectedCardBackground : PaneOverviewPalette.cardBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isSelected ? Color(nsColor: Tako.Brand.ember) : Color(nsColor: PaneOverviewPalette.hairline),
                    lineWidth: isSelected ? 2.0 : 1.0
                )
        )
        .contentShape(Rectangle())
    }

    private func thumbnailView(item: PaneOverviewItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if item.thumbnailLines.isEmpty {
                Text("~ $")
                    .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                    .foregroundColor(Color(nsColor: PaneOverviewPalette.dim))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text(item.thumbnailLines.prefix(8).joined(separator: "\n"))
                    .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                    .foregroundColor(Color(nsColor: PaneOverviewPalette.terminalText))
                    .lineSpacing(2)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Spacer(minLength: 0)

            // Progress bar if active (OSC 9;4)
            if item.progressState != .none {
                progressBarView(state: item.progressState, value: item.progressValue)
                    .frame(height: 3)
                    .padding(.top, 4)
            }
        }
        .padding(8)
        .frame(height: 110)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: PaneOverviewPalette.terminalBackground))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: PaneOverviewPalette.hairline), lineWidth: 1)
        )
    }

    private func progressBarView(state: TakoTerminalNSView.ProgressState, value: Int?) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = min(max(Double(value ?? (state == .indeterminate ? 40 : 0)) / 100.0, 0.05), 1.0)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(nsColor: PaneOverviewPalette.selectedCardBackground))

                if state == .error {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color(nsColor: Tako.Brand.error))
                        .frame(width: width * CGFloat(fraction))
                } else {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(nsColor: PaneOverviewPalette.progressGradientStart),
                                    Color(nsColor: PaneOverviewPalette.progressGradientEnd)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: width * CGFloat(fraction))
                }
            }
        }
    }
}
