/*
 * tako — Configuration reload delivery regression
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */
import AppKit
import Combine
import Foundation
import Testing
@testable import Tako

private final class ReloadThreadRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var threads: [Bool] = []

    func append() { lock.lock(); threads.append(Thread.isMainThread); lock.unlock() }
    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return threads
    }
}

// Install the Combine closure outside a main-actor context: the recorder
// observes the delivery thread without itself asserting actor isolation.
private func observeReload(_ app: Tako.App, record: ReloadThreadRecord) -> AnyCancellable {
    app.$config.dropFirst().sink { _ in record.append() }
}

/// A real, live UI config subscriber while the same off-main reload as
/// SurfaceConfigReloadTests runs. No window is shown and
/// the controller's empty surface tree starts no PTY.
@Suite(.serialized) @MainActor
struct HostedConfigReloadProbeTests {
    @Test func backgroundReloadWithAWindowControllerObserver() async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("reload-probe-\(UUID().uuidString).tako")
        try "background = #102030\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let app = Tako.App(configPath: file.path)
        let controller = QuickTerminalController(app)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        defer { controller.window = nil; window.close() }
        try #require(controller.surfaceTree.isEmpty, "diagnostic controller must not start a terminal")
        let record = ReloadThreadRecord()
        let published = ReloadThreadRecord()
        let subscription = observeReload(app, record: published)
        defer { subscription.cancel() }
        let token = NotificationCenter.default.addObserver(forName: .takoConfigDidChange,
                                                          object: nil, queue: nil) { _ in record.append() }
        defer { NotificationCenter.default.removeObserver(token) }
        try "background = #405060\n".write(to: file, atomically: true, encoding: .utf8)
        nonisolated(unsafe) let unsafeApp = app
        await Task.detached { unsafeApp.reloadConfig() }.value
        let deadline = Date().addingTimeInterval(3)
        while record.values.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(record.values == [true], "all UI config subscribers must be notified on the main thread")
        #expect(published.values == [true], "ObservableObject config publication must also be on the main thread")
        #expect(controller.surfaceTree.isEmpty)
    }

    @Test func mainThreadReloadStillPublishesSynchronously() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("reload-sync-\(UUID().uuidString).tako")
        try "background = #102030\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let app = Tako.App(configPath: file.path)
        let published = ReloadThreadRecord()
        let notifications = ReloadThreadRecord()
        let subscription = observeReload(app, record: published)
        defer { subscription.cancel() }
        let token = NotificationCenter.default.addObserver(forName: .takoConfigDidChange,
                                                          object: nil, queue: nil) { _ in notifications.append() }
        defer { NotificationCenter.default.removeObserver(token) }
        try "background = #405060\n".write(to: file, atomically: true, encoding: .utf8)
        app.reloadConfig()
        #expect(published.values == [true])
        #expect(notifications.values == [true])
    }
}
