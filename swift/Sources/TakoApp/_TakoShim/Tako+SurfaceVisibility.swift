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

extension Tako {
    /// Stops a surface drawing while nobody can see it. Every tab is a
    /// window of its own and the ones behind the selected tab are ordered
    /// out, yet each kept planning and presenting a frame for every change
    /// on its screen: an agent's spinner or a `tail -f` in a background tab
    /// cost the main thread as much as the tab being looked at. A hidden
    /// surface keeps its changes pending and draws them once it shows.
    @MainActor
    final class SurfaceVisibilityWatch {
        private weak var surface: TakoTerminalNSView?
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private let isShowing: @MainActor (NSWindow) -> Bool

        init(surface: TakoTerminalNSView, window: NSWindow,
             isShowing: @escaping @MainActor (NSWindow) -> Bool = SurfaceVisibilityWatch.isShowing) {
            self.surface = surface
            self.window = window
            self.isShowing = isShowing
            let center = NotificationCenter.default
            // Occlusion follows ordering in and out, minimizing and being
            // covered; becoming key comes first when a tab is selected, so
            // the tab draws in the same pass that shows it.
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didBecomeKeyNotification,
                         NSWindow.didDeminiaturizeNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.update() }
                })
            }
            update()
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        /// Whether `window` shows its content to anyone now.
        static func isShowing(_ window: NSWindow) -> Bool {
            window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        }

        func update() {
            guard let surface, let window else { return }
            surface.isPresentationPaused = !isShowing(window)
        }
    }
}
