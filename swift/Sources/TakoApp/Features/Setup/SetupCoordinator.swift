/*
 * tako — First-run setup presentation and launch coordination
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Combine
import SwiftUI

@MainActor
final class SetupCoordinator: NSObject, NSWindowDelegate {
    static let shared = SetupCoordinator()
    private(set) var panel: NSPanel?
    private var model: SetupModel?
    private weak var host: NSWindow?
    private var previousResponder: NSResponder?
    private lazy var launchObserver = SetupLaunchObserver()
    private var hostCloseObserver: NSObjectProtocol?
    private var stageObservation: AnyCancellable?
    /// The terminal that gets the keys back when setup closes: the surface
    /// that had focus before, else the host controller's focused surface.
    /// Injectable for tests.
    var terminalToFocus: (NSWindow) -> NSResponder? = { host in
        guard let controller = host.windowController as? BaseTerminalController else { return nil }
        return controller.focusedSurface ?? controller.surfaceTree.first(where: { _ in true })
    }

    func offerAtLaunch(app: Tako.App) {
        launchObserver.stop()
        let store = SetupProgressStore()
        guard SetupProgressStore.allowsLaunch(arguments: CommandLine.arguments,
                environment: ProcessInfo.processInfo.environment,
                isTesting: NSClassFromString("XCTestCase") != nil) else { return }
        guard !store.load().hasPresented else {
            WhatsNewNotice.offerAtLaunch(theme: app.config.theme)
            return
        }
        launchObserver.start(store: store) { [weak self, weak app] in
            guard let self, let app else { return true }
            // Automatic setup never creates a window or overrides initial-window.
            guard NSApp.isActive, let window = TerminalController.preferredTabParent?.window,
                  window.isVisible, !window.isMiniaturized else { return false }
            return self.show(app: app, in: window)
        }
    }

    @discardableResult
    func show(app: Tako.App, in window: NSWindow? = nil) -> Bool {
        if let panel { panel.makeKeyAndOrderFront(nil); return true }
        guard let window = window ?? TerminalDialogView.ensureHostWindow(tako: app) else { return false }
        return show(model: SetupModel(configPath: app.activeConfigPath), in: window)
    }

    @discardableResult
    func show(model: SetupModel, in window: NSWindow) -> Bool {
        if let panel { panel.makeKeyAndOrderFront(nil); return true }
        guard window.attachedSheet == nil, TerminalDialogView.pending(in: window) == nil,
              !Tako.CustomTabGroup.isClosed(window) else { return false }
        // Theme editors and setup must not fight for the host's keyboard focus.
        guard window.contentView?.subviews.contains(where: { $0 is TerminalSettingsDialog }) != true else { return false }
        let size = SetupSheetGeometry.size(forHost: window.contentLayoutRect.size, stage: model.stage)
        let panel = SetupPanel(contentRect: NSRect(origin: .zero, size: size),
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
        panel.contentMinSize = SetupSheetGeometry.minimum
        let container = NSView(frame: NSRect(origin: .zero, size: size))
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
        // Hero stages are the short card, list stages the tall one; the top stays put.
        stageObservation = model.$progress.map { SetupStage($0.step).isHero }.removeDuplicates()
            .sink { [weak panel, weak window] hero in
                guard let panel, let window else { return }
                let size = SetupSheetGeometry.size(forHost: window.contentLayoutRect.size,
                                                   stage: hero ? .welcome : .access)
                guard panel.contentRect(forFrameRect: panel.frame).size != size else { return }
                let top = panel.frame.maxY
                panel.setContentSize(size)
                panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height))
            }
        model.didPresent()
        launchObserver.stop()
        return true
    }

    func close(force: Bool = false) {
        guard force || model?.isBusy != true, let panel else { return }
        if let hostCloseObserver { NotificationCenter.default.removeObserver(hostCloseObserver) }
        self.hostCloseObserver = nil
        stageObservation = nil
        if let host, host.attachedSheet === panel { host.endSheet(panel) }
        panel.orderOut(nil)
        panel.close()
        // Return focus to the existing terminal; setup never opens another one.
        // At launch the window itself was often first responder (the surface
        // had not taken focus yet), so restoring that left keys going nowhere.
        if !force, let host, host.isVisible {
            host.makeKeyAndOrderFront(nil)
            // The sidebar list also takes focus when it appears; the keys still
            // belong to the terminal. Another view is restored only without one.
            if let surface = previousResponder as? Tako.SurfaceView, surface.window === host {
                Tako.moveFocus(to: surface)
            } else if let terminal = terminalToFocus(host) {
                if let surface = terminal as? Tako.SurfaceView { Tako.moveFocus(to: surface) }
                else { host.makeFirstResponder(terminal) }
            } else if let view = previousResponder as? NSView, view.window === host {
                host.makeFirstResponder(view)
            }
        }
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
