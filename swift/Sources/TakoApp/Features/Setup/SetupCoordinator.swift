/*
 * tako — First-run setup presentation and launch coordination
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

@MainActor
final class SetupCoordinator: NSObject, NSWindowDelegate {
    static let shared = SetupCoordinator()
    private(set) var panel: NSPanel?
    private var model: SetupModel?
    private weak var host: NSWindow?
    private var previousResponder: NSResponder?
    private var launchTask: Task<Void, Never>?
    private var hostCloseObserver: NSObjectProtocol?

    func offerAtLaunch(app: Tako.App) {
        let store = SetupProgressStore()
        guard SetupProgressStore.allowsLaunch(arguments: CommandLine.arguments,
                environment: ProcessInfo.processInfo.environment,
                isTesting: NSClassFromString("XCTestCase") != nil) else { return }
        guard !store.load().hasPresented else {
            WhatsNewNotice.offerAtLaunch(theme: app.config.theme)
            return
        }
        launchTask?.cancel()
        launchTask = Task { [weak self, weak app] in
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, !store.load().hasPresented, let self, let app else { return }
                if let window = TerminalController.preferredTabParent?.window,
                   self.show(app: app, in: window) { return }
            }
        }
    }

    @discardableResult
    func show(app: Tako.App, in window: NSWindow? = nil) -> Bool {
        guard let window = window ?? TerminalController.preferredTabParent?.window else { return false }
        return show(model: SetupModel(configPath: app.activeConfigPath), in: window)
    }

    @discardableResult
    func show(model: SetupModel, in window: NSWindow) -> Bool {
        if let panel { panel.makeKeyAndOrderFront(nil); return true }
        guard window.attachedSheet == nil, TerminalDialogView.pending(in: window) == nil,
              !Tako.CustomTabGroup.isClosed(window) else { return false }
        // Theme editors and setup must not fight for the host's keyboard focus.
        guard window.contentView?.subviews.contains(where: { $0 is TerminalSettingsDialog }) != true else { return false }
        let panel = SetupPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                               styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Set up Tako"
        panel.identifier = NSUserInterfaceItemIdentifier("TakoSetupWindow")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.backgroundColor = Tako.Brand.surface
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        // SwiftUI propagates a container identifier to its descendants on macOS.
        // Keep the container ID on AppKit so every button retains its own ID.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityIdentifier("SetupWizard")
        container.setAccessibilityLabel("Tako setup")
        container.setAccessibilityEnabled(true)
        let hosting = NSHostingView(rootView: SetupWizardView(model: model))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        panel.setAccessibilityIdentifier("TakoSetupWindow")
        panel.setAccessibilityLabel("Set up Tako")
        self.panel = panel
        self.model = model
        self.host = window
        self.previousResponder = window.firstResponder
        model.onClose = { [weak self] in self?.close() }
        panel.onEscape = { [weak model] in model?.dismiss() }
        hostCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close(force: true) }
            }
        window.beginSheet(panel)
        model.didPresent()
        return true
    }

    func close(force: Bool = false) {
        guard force || model?.isBusy != true, let panel else { return }
        if let hostCloseObserver { NotificationCenter.default.removeObserver(hostCloseObserver) }
        self.hostCloseObserver = nil
        if let host, host.attachedSheet === panel { host.endSheet(panel) }
        panel.orderOut(nil)
        panel.close()
        if !force, let previousResponder { host?.makeFirstResponder(previousResponder) }
        self.panel = nil
        self.model = nil
        self.host = nil
        self.previousResponder = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model?.isBusy != true else { NSSound.beep(); return false }
        close()
        return false
    }
}

@MainActor
private final class SetupPanel: NSPanel {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

extension AppDelegate {
    @IBAction func showSetup(_ sender: Any?) {
        SetupCoordinator.shared.show(app: tako)
    }

    func setupFirstRunMenuItem() {
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              !menu.items.contains(where: { $0.action == #selector(showSetup) }) else { return }
        let item = NSMenuItem(title: "Set Up Tako…", action: #selector(showSetup), keyEquivalent: "")
        item.target = self
        item.setImageIfDesired(systemSymbolName: "checklist")
        menu.insertItem(item, at: min(1, menu.items.count))
    }
}
