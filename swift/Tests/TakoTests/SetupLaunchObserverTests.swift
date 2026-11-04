/*
 * tako — Event-driven setup readiness regressions
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Testing
@testable import Tako

@Suite(.serialized) @MainActor
struct SetupLaunchObserverTests {
    @Test func anInitiallyMissingHostCanBecomeReadyLater() throws {
        try fixture { observer, store, center in
            var ready = false
            var presentations = 0
            observer.start(store: store) {
                guard ready else { return false }
                presentations += 1
                return true
            }
            for _ in 0..<50 { center.post(name: NSWindow.didUpdateNotification, object: nil) }
            #expect(observer.isWaiting && presentations == 0)
            ready = true
            center.post(name: NSWindow.didBecomeKeyNotification, object: nil)
            #expect(!observer.isWaiting && presentations == 1)
            center.post(name: NSWindow.didUpdateNotification, object: nil)
            #expect(presentations == 1)
        }
    }

    @Test func manualPresentationCancelsTheAutomaticOffer() throws {
        try fixture { observer, store, center in
            var attempts = 0
            observer.start(store: store) { attempts += 1; return false }
            #expect(attempts == 1 && observer.isWaiting)
            store.save(SetupProgress(hasPresented: true))
            center.post(name: NSWindow.didEndSheetNotification, object: nil)
            #expect(attempts == 1 && !observer.isWaiting)
        }
    }

    @Test func synchronousPresentationEventsCannotReenterThePresenter() throws {
        try fixture { observer, store, center in
            var presentations = 0
            observer.start(store: store) {
                presentations += 1
                center.post(name: NSWindow.didBecomeKeyNotification, object: nil)
                return true
            }
            #expect(presentations == 1 && !observer.isWaiting)
        }
    }

    private func fixture(_ body: (SetupLaunchObserver, SetupProgressStore, NotificationCenter) throws -> Void) throws {
        let name = "SetupLaunchObserverTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let center = NotificationCenter()
        let observer = SetupLaunchObserver(center: center)
        defer { observer.stop() }
        try body(observer, SetupProgressStore(defaults: defaults), center)
    }
}
