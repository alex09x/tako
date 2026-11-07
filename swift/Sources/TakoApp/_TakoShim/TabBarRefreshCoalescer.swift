/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// Coalesces streamed chrome changes without delaying terminal parsing or
/// dropping title events. The refresh reads the latest state when it runs.
@MainActor
final class TabBarRefreshCoalescer {
    typealias Action = @MainActor () -> Void
    private let schedule: (@escaping Action) -> Void
    private let refresh: Action
    private var pending = false

    init(
        schedule: @escaping (@escaping Action) -> Void = { action in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { action() }
        },
        refresh: @escaping Action
    ) {
        self.schedule = schedule
        self.refresh = refresh
    }

    func request() {
        guard !pending else { return }
        pending = true
        schedule { [weak self] in
            guard let self else { return }
            self.pending = false
            self.refresh()
        }
    }
}
