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
import TakoKit

extension TerminalWindow {
    struct DerivedConfig {
        let title: String?
        let backgroundBlur: Tako.Config.BackgroundBlur
        let backgroundColor: NSColor
        let backgroundOpacity: Double
        let macosWindowButtons: Tako.MacOSWindowButtons
        let macosTitlebarStyle: Tako.Config.MacOSTitlebarStyle
        let windowCornerRadius: CGFloat

        init() {
            self.title = nil
            self.backgroundColor = NSColor.windowBackgroundColor
            self.backgroundOpacity = 1
            self.macosWindowButtons = .visible
            self.backgroundBlur = .disabled
            self.macosTitlebarStyle = .default
            self.windowCornerRadius = 16
        }

        init(_ config: Tako.Config) {
            self.title = config.title
            self.backgroundColor = NSColor(config.backgroundColor)
            self.backgroundOpacity = config.backgroundOpacity
            self.macosWindowButtons = config.macosWindowButtons
            self.backgroundBlur = config.backgroundBlur
            self.macosTitlebarStyle = config.macosTitlebarStyle

            // Set corner radius based on macos-titlebar-style
            // Native, transparent, and hidden styles use 16pt radius
            // Tabs style uses 20pt radius
            switch config.macosTitlebarStyle {
            case .tabs:
                self.windowCornerRadius = 20
            default:
                self.windowCornerRadius = 16
            }
        }
}
}

// MARK: SwiftUI View

extension TerminalWindow {
    class ViewModel: ObservableObject {
        @Published var isSurfaceZoomed: Bool = false
        @Published var hasToolbar: Bool = false
        @Published var isMainWindow: Bool = true
    }
}

/// A small circle indicator displayed in the tab accessory view that shows
/// the user-assigned tab color. When no color is set, the view is hidden.
struct TabColorIndicatorView: View {
    /// The tab color to display.
    let tabColor: TerminalTabColor

    var body: some View {
        if let color = tabColor.displayColor {
            Circle()
                .fill(Color(color))
                .frame(width: 6, height: 6)
        } else {
            Circle()
                .fill(Color.clear)
                .frame(width: 6, height: 6)
                .hidden()
        }
    }
}

