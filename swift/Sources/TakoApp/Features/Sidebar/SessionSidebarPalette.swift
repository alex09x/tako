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

/// Color palette used across the Session Sidebar UI components (B5).
enum SessionSidebarPalette {
    static let bar = NSColor(srgbRed: 0x14 / 255, green: 0x10 / 255, blue: 0x0E / 255, alpha: 1)
    static let activeTab = NSColor(srgbRed: 0x24 / 255, green: 0x1C / 255, blue: 0x16 / 255, alpha: 1)
    static let hoverTab = NSColor(srgbRed: 0x1F / 255, green: 0x19 / 255, blue: 0x15 / 255, alpha: 1)
    static let hairline = NSColor(srgbRed: 0x2A / 255, green: 0x21 / 255, blue: 0x1B / 255, alpha: 1)
    static let badge = NSColor(srgbRed: 0x35 / 255, green: 0x2B / 255, blue: 0x23 / 255, alpha: 1)
    static let activeText = NSColor(srgbRed: 0xFA / 255, green: 0xF7 / 255, blue: 0xF2 / 255, alpha: 1)
    static let inactiveText = NSColor(srgbRed: 0xB7 / 255, green: 0xAC / 255, blue: 0xA1 / 255, alpha: 1)
    static let dim = NSColor(srgbRed: 0x8A / 255, green: 0x7F / 255, blue: 0x76 / 255, alpha: 1)
    static let progressGradientStart = NSColor(srgbRed: 0xC2 / 255, green: 0x3E / 255, blue: 0x0E / 255, alpha: 1)
    static let progressGradientEnd = Tako.Brand.ember
}

/// 15×15 pixel-art Crab indicator shape matching `Tako.CrabPainter.rows` (10×7 integer grid).
struct SidebarCrabShape: Shape {
    let raisedClaws: Bool

    private static let normalRows = Tako.CrabPainter.rows
    private static let waitingRows = [
        "C.C....C.C",
        "CC......CC",
        ".#......#.",
        "..######..",
        "..#o##o#..",
        "..######..",
        ".#.#..#.#.",
    ]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step: CGFloat = 1.0
        let originX = ((rect.width - 10 * step) / 2).rounded()
        let originY = ((rect.height - 7 * step) / 2).rounded()
        let rows = raisedClaws ? Self.waitingRows : Self.normalRows
        for (r, row) in rows.enumerated() {
            for (c, ch) in row.enumerated() where ch != "." && ch != "o" {
                path.addRect(CGRect(
                    x: originX + CGFloat(c) * step,
                    y: originY + CGFloat(r) * step,
                    width: step,
                    height: step
                ))
            }
        }
        return path
    }
}

/// Renders the 15×15 Crab icon on Level 1 session rows and 8×8 dot/ring on Level 2 child rows.
struct SidebarStatusIndicatorView: View {
    let status: Tako.PaneStatus
    let isChild: Bool

    var body: some View {
        let chipColor = Color(nsColor: status.uiChipColor)
        if isChild {
            ZStack {
                if status.isSidebarPulsing {
                    Circle().stroke(chipColor.opacity(0.45), lineWidth: 1.5).frame(width: 12, height: 12)
                }
                if status.isWaitingForHuman {
                    Circle().stroke(chipColor, lineWidth: 1.8).frame(width: 8, height: 8)
                } else {
                    Circle().fill(chipColor).frame(width: 8, height: 8)
                }
            }
            .frame(width: 12, height: 12)
        } else {
            ZStack {
                if status.isSidebarPulsing {
                    Circle().stroke(chipColor.opacity(0.45), lineWidth: 1.3).frame(width: 15, height: 15)
                }
                SidebarCrabShape(raisedClaws: status.isWaitingForHuman)
                    .fill(chipColor)
                    .frame(width: 15, height: 15)
            }
            .frame(width: 15, height: 15)
        }
    }
}

/// UI Kit status chip (6px dot/ring, 10px mono Title Case label, 10% fill + 1px 25% border).
struct SidebarStatusChipView: View {
    let status: Tako.PaneStatus
    let label: String

    var body: some View {
        let chipColor = Color(nsColor: status.uiChipColor)
        HStack(spacing: 4) {
            if status.isWaitingForHuman {
                Circle().stroke(chipColor, lineWidth: 1.5).frame(width: 6, height: 6)
            } else {
                Circle().fill(chipColor).frame(width: 6, height: 6)
            }
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(chipColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(chipColor.opacity(0.10)))
        .overlay(Capsule().stroke(chipColor.opacity(0.25), lineWidth: 1))
    }
}
