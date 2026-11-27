/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Combine
import Foundation
import TakoCoreUI

/// Gate UI publication, not the raw terminal title or protocol events.
@MainActor
final class SurfaceTitlePublication {
    static let shared = SurfaceTitlePublication()
    private final class PendingSurface {
        weak var value: Tako.SurfaceView?
        init(_ value: Tako.SurfaceView) { self.value = value }
    }
    private var pending: [ObjectIdentifier: PendingSurface] = [:]
    private let requests = PassthroughSubject<Void, Never>()
    private var watch: AnyCancellable?

    private init() {
        watch = requests
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.deliver() } }
    }

    func request(_ surface: Tako.SurfaceView) {
        pending[ObjectIdentifier(surface)] = PendingSurface(surface)
        requests.send(())
    }

    private func deliver() {
        let surfaces = Array(pending.values)
        pending.removeAll(keepingCapacity: true)
        for surface in surfaces { surface.value?.publishCurrentTitle() }
    }
}

extension Tako.SurfaceView {
    func requestTitlePublication() {
        SurfaceTitlePublication.shared.request(self)
    }

    /// Read the current value so a queued delivery cannot undo a focus flush.
    func publishCurrentTitle() {
        guard titleText != title else { return }
        titleText = title
        Tako.TabBarController.requestRefresh()
    }
}
