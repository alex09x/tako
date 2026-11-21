/*
 * tako — Setup presentation lifecycle regressions
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
struct SetupCoordinatorTests {
    @Test func setupIsSingleInstanceAndReturnsTheFirstResponder() throws {
        try fixture { coordinator, model, host, editor in
            host.makeKeyAndOrderFront(nil)
            host.makeFirstResponder(editor)
            #expect(coordinator.show(model: model, in: host))
            let panel = try #require(coordinator.panel)
            #expect(host.attachedSheet === panel)
            #expect(coordinator.show(model: model, in: host))
            #expect(coordinator.panel === panel)
            #expect(model.progress.hasPresented)
            coordinator.close()
            #expect(coordinator.panel == nil)
            #expect(host.attachedSheet == nil)
            #expect(host.firstResponder === editor)
        }
    }

    @Test func anExistingSheetIsNotDismissedToShowSetup() throws {
        try fixture { coordinator, model, host, _ in
            let other = NSPanel(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
            host.beginSheet(other)
            defer { host.endSheet(other); other.close() }
            #expect(!coordinator.show(model: model, in: host))
            #expect(host.attachedSheet === other)
            #expect(!model.progress.hasPresented)
        }
    }

    @Test func closingTheHostReleasesItsSetupPanel() throws {
        try fixture { coordinator, model, host, _ in
            #expect(coordinator.show(model: model, in: host))
            host.close()
            #expect(coordinator.panel == nil)
            #expect(model.store.load().hasPresented)
            #expect(!model.store.load().completed)
        }
    }

    private func fixture(_ body: (SetupCoordinator, SetupModel, NSWindow, NSTextView) throws -> Void) throws {
        _ = NSApplication.shared
        let name = "SetupCoordinatorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let services = SetupServices(checkCLI: { .init(installed: false, detail: "Optional") },
            installCLI: { .init(installed: false, detail: "Unused") }, checkAgents: { [] },
            connectAgents: { _ in [] }, checkNotifications: { .init(access: .notAsked) },
            enableNotifications: { .init(access: .denied) }, openNotificationSettings: {})
        let model = SetupModel(store: SetupProgressStore(defaults: defaults), services: services,
                               configPath: "/nonexistent/tako-setup-test-config")
        let coordinator = SetupCoordinator()
        let host = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1000, height: 720),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        let editor = NSTextView(frame: host.contentView!.bounds)
        host.contentView?.addSubview(editor)
        defer { coordinator.close(force: true); host.close() }
        try body(coordinator, model, host, editor)
    }
}
