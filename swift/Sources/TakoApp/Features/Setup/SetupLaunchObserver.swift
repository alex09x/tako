/*
 * tako — Wait for the first eligible setup host without a deadline
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

@MainActor
final class SetupLaunchObserver {
    private let center: NotificationCenter
    private var observations: [NSObjectProtocol] = []
    private var store: SetupProgressStore?
    private var present: (() -> Bool)?
    private var checking = false
    var isWaiting: Bool { !observations.isEmpty }

    init(center: NotificationCenter = .default) { self.center = center }

    func start(store: SetupProgressStore, present: @escaping () -> Bool) {
        stop()
        self.store = store
        self.present = present
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didUpdateNotification,
                     NSWindow.didEndSheetNotification, NSApplication.didBecomeActiveNotification] {
            observations.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkReadiness() }
            })
        }
        checkReadiness()
    }

    func stop() {
        observations.forEach(center.removeObserver)
        observations.removeAll()
        store = nil
        present = nil
    }

    private func checkReadiness() {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        guard let store, !store.load().hasPresented, let present else { stop(); return }
        if present() { stop() }
    }
}
