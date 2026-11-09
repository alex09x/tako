/*
 * tako — Sidebar follows the terminal background
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import SwiftUI

struct TerminalSidebar: View {
    @ObservedObject var surface: Tako.SurfaceView
    @Binding var isPresented: Bool
    let window: NSWindow?
    let shortcut: KeyboardShortcut?

    var body: some View {
        // The shell's own background (app-appearance), not the terminal
        // theme's: a dark terminal in a light shell reads as two layers.
        SessionSidebarView(isPresented: $isPresented, containingWindow: window,
            backgroundColor: Color(nsColor: Tako.LivingTokens.body)
                .opacity(surface.derivedConfig.backgroundOpacity), newSessionShortcut: shortcut)
    }
}
