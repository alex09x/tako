/*
 * tako — «Current Zoom» for one terminal (reference A07, pdZoomRow)
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

/// A terminal's temporary zoom beside its saved size: «+2 pt — displayed at
/// 15.5 pt», − / + / «Reset Zoom». It is the same zoom as ⌘+ / ⌘− /
/// ⌘0 (SurfaceView.changeFontSize, 4–255 pt), never written to the config;
/// the saved base size (6–72 pt) is the field above. Other levels show the
/// hint only. It follows the zoom through `.takoSurfaceZoomDidChange`.
/// Accessibility: `DesktopZoomNow`, `DesktopZoomOut`, `DesktopZoomIn`, `DesktopZoomReset`.
struct DesktopPaneZoomRow: View {
    let paneID: UUID?
    let palette: DesktopPalette
    @State private var revision = 0

    private var surface: Tako.SurfaceView? {
        guard let paneID else { return nil }
        return TerminalController.all.lazy.flatMap { Array($0.surfaceTree) }.first { $0.id == paneID }
    }

    static func describe(delta: CGFloat, effective: CGFloat) -> String {
        guard delta != 0 else { return "No temporary zoom. ⌘+ / ⌘− / ⌘0 affect only this terminal." }
        let sign = delta > 0 ? "+" : "−"
        return "\(sign)\(DesktopStepper.render(Double(abs(delta)))) pt — displayed at \(DesktopStepper.render(Double(effective))) pt. Temporary, for this terminal only."
    }

    var body: some View {
        let _ = revision
        Group {
            if let surface {
                DesktopPrefRow(title: "Current Zoom",
                               detail: Self.describe(delta: surface.fontZoomDelta, effective: surface.theme.fontSize),
                               key: "increase_font_size · decrease_font_size · reset_font_size", palette: palette) {
                    HStack(spacing: 6) {
                        Button("−") { surface.changeFontSize(.decrease(1)) }
                            .accessibilityLabel("Zoom Out").accessibilityIdentifier("DesktopZoomOut")
                        Button("+") { surface.changeFontSize(.increase(1)) }
                            .accessibilityLabel("Zoom In").accessibilityIdentifier("DesktopZoomIn")
                        Button("Reset Zoom") { surface.changeFontSize(.reset) }
                            .disabled(surface.fontZoomDelta == 0)
                            .accessibilityIdentifier("DesktopZoomReset")
                    }
                    .buttonStyle(DesktopButtonStyle(palette: palette))
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("DesktopZoomNow")
            } else {
                DesktopHint(text: "⌘+ / ⌘− / ⌘0 temporarily zoom one terminal. The field above controls its saved, inherited font size.",
                            palette: palette)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .takoSurfaceZoomDidChange)) { note in
            if (note.object as? Tako.SurfaceView)?.id == paneID { revision &+= 1 }
        }
    }
}
