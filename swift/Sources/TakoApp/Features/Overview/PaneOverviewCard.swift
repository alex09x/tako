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
struct PaneOverviewCard: View {
    let item: PaneOverviewItem
    let isSelected: Bool

    var body: some View {
        let statusColor = Color(nsColor: item.statusColor)

        VStack(alignment: .leading, spacing: 10) {
            // Card Top Row: Status badge and window/tab provenance
            HStack(spacing: 8) {
                // Status Pill
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)

                    Text(item.statusLabel.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(statusColor)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(statusColor.opacity(0.15))
                .clipShape(Capsule())

                if let text = item.statusText, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(nsColor: PaneOverviewPalette.dim))
                        .lineLimit(1)
                }

                Spacer()

                // Window / Tab provenance tag
                Text("Tab \(item.tabIndex + 1)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(nsColor: PaneOverviewPalette.dim))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: PaneOverviewPalette.badge))
                    .cornerRadius(4)
            }

            // Pane Title
            Text(item.title)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(nsColor: PaneOverviewPalette.activeText))
                .lineLimit(1)

            // Live Thumbnail: Terminal Output Preview
            thumbnailView(item: item)

            // Card Footer: Working directory & running elapsed time
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: PaneOverviewPalette.dim))

                Text(item.directoryDisplay)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(nsColor: PaneOverviewPalette.dim))
                    .lineLimit(1)

                Spacer()

                if let elapsed = item.elapsed {
                    Text(elapsed)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(nsColor: Tako.Brand.ember))
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: PaneOverviewPalette.cardBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isSelected ? Color(nsColor: Tako.Brand.ember) : statusColor.opacity(0.85),
                    lineWidth: isSelected ? 2.5 : 1.5
                )
        )
        .shadow(
            color: isSelected ? Color(nsColor: Tako.Brand.ember).opacity(0.35) : statusColor.opacity(0.15),
            radius: isSelected ? 8 : 4,
            x: 0,
            y: 2
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
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(item.thumbnailLines.prefix(8).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                            .foregroundColor(Color(nsColor: PaneOverviewPalette.terminalText))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Spacer(minLength: 0)

            // Progress bar if active
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
                .stroke(Color(nsColor: PaneOverviewPalette.hairline), lineWidth: 0.5)
        )
    }

    private func progressBarView(state: TakoTerminalNSView.ProgressState, value: Int?) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let color: Color = switch state {
            case .normal: Color(nsColor: Tako.Brand.ok)
            case .error: Color(nsColor: Tako.Brand.error)
            case .paused: Color(nsColor: Tako.Brand.ember)
            case .indeterminate: Color(nsColor: Tako.Brand.ember)
            case .none: Color.clear
            }

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color.opacity(0.2))

                let fraction = min(max(Double(value ?? (state == .indeterminate ? 50 : 0)) / 100.0, 0.05), 1.0)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: width * CGFloat(fraction))
            }
        }
    }
}
