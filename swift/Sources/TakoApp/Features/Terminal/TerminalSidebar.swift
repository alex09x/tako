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
        SessionSidebarView(isPresented: $isPresented, containingWindow: window,
            backgroundColor: (surface.backgroundColor ?? surface.derivedConfig.backgroundColor)
                .opacity(surface.derivedConfig.backgroundOpacity), newSessionShortcut: shortcut)
    }
}
