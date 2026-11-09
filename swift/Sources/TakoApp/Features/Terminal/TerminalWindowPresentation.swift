/*
 * tako — Retain the latest window presentation state across SwiftUI suspension
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Combine

@MainActor
final class TerminalWindowPresentation: ObservableObject {
    @Published private(set) var isVisible = false
    private weak var window: NSWindow?
    private var observation: AnyCancellable?
    private var generation = 0

    func bind(to window: NSWindow?) {
        guard self.window !== window || observation == nil else { return }
        generation &+= 1
        let current = generation
        observation = nil
        self.window = window
        guard let window else { update(true); return }
        update(window.isVisible)
        observation = window.publisher(for: \.isVisible, options: [.initial, .new])
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    self.update(visible)
                }
            }
    }

    private func update(_ visible: Bool) {
        if isVisible != visible { isVisible = visible }
    }
}
