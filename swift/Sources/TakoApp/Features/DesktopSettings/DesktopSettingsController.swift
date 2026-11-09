/*
 * tako — Presents native settings centered in a host window and restores focus
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

/// Reusable entry points for global, workspace, session and pane settings.
/// One controller per host window; showing again re-targets it.
@MainActor
final class DesktopSettingsController {
    private static var active: [ObjectIdentifier: DesktopSettingsController] = [:]

    let model: DesktopSettingsModel
    let overlay: DesktopSettingsOverlayView
    private(set) weak var host: NSWindow?
    private weak var previousResponder: NSResponder?
    private var resizeObserver: NSObjectProtocol?

    static func current(in window: NSWindow) -> DesktopSettingsController? {
        active[ObjectIdentifier(window)]
    }

    @discardableResult
    static func show(in window: NSWindow, section: DesktopSettingsSection = .general,
                     context: ScopedAppearanceContext? = nil, configPath: String? = nil) -> DesktopSettingsController? {
        if let existing = current(in: window) {
            if existing.model.scope.context?.scope == context?.scope {
                existing.model.section = section
                return existing
            }
            existing.close()
        }
        guard let content = window.contentView else { return nil }
        let path = configPath ?? (NSApp.delegate as? AppDelegate)?.tako.activeConfigPath
        let model = DesktopSettingsModel(configPath: path, context: context, section: section)
        let controller = DesktopSettingsController(model: model, host: window, content: content)
        active[ObjectIdentifier(window)] = controller
        return controller
    }

    static func showGlobal(section: DesktopSettingsSection = .general, in window: NSWindow? = nil) {
        guard let host = window ?? hostWindow else { return }
        show(in: host, section: section)
    }

    static func showWorkspace(_ id: UUID, section: DesktopSettingsSection = .terminalAppearance, in window: NSWindow? = nil) {
        let workspaces = WorkspaceStore.shared
        guard let workspace = workspaces.workspace(for: id), let host = window ?? hostWindow,
              let app = (host.windowController as? TerminalController)?.tako else { return }
        let context = ScopedAppearanceContext(scope: .workspace(id), title: "Пространство «\(workspace.name)»",
            globalTheme: { [weak app] in app?.config.theme ?? .takoDefault },
            isAvailable: { workspaces.workspace(for: id) != nil })
        show(in: host, section: section, context: context)
    }

    /// Sessions resolve through their workspace; the caller supplies both lookups.
    static func showSession(_ id: String, title: String, workspaceID: @escaping () -> UUID?,
                            isAvailable: @escaping () -> Bool, section: DesktopSettingsSection = .terminalAppearance,
                            in window: NSWindow? = nil) {
        guard let host = window ?? hostWindow,
              let app = (host.windowController as? TerminalController)?.tako else { return }
        let context = ScopedAppearanceContext(scope: .session(id), title: title,
            globalTheme: { [weak app] in app?.config.theme ?? .takoDefault },
            workspaceID: workspaceID, isAvailable: isAvailable)
        show(in: host, section: section, context: context)
    }

    static func showPane(_ id: UUID, section: DesktopSettingsSection = .terminalAppearance, in window: NSWindow? = nil) {
        guard let controller = TerminalController.all.first(where: { $0.surfaceTree.contains { $0.id == id } }),
              let surface = controller.surfaceTree.first(where: { $0.id == id }),
              let host = window ?? hostWindow ?? controller.window else { return }
        let context = ScopedAppearanceContext(scope: .pane(id), title: "Панель",
            globalTheme: { [weak surface] in surface?.app?.config.theme ?? .takoDefault },
            workspaceID: { [weak surface] in surface?.appearanceWorkspaceID },
            sessionID: { [weak surface] in surface?.appearanceSessionID },
            isAvailable: { [weak surface] in surface != nil && TerminalController.all.contains { $0.surfaceTree.contains { $0.id == id } } })
        show(in: host, section: section, context: context)
    }

    private static var hostWindow: NSWindow? {
        if let key = NSApp.keyWindow, key.windowController is TerminalController { return key }
        return TerminalController.preferredParent?.window ?? NSApp.keyWindow
    }

    init(model: DesktopSettingsModel, host: NSWindow, content: NSView) {
        self.model = model
        self.host = host
        self.previousResponder = host.firstResponder
        overlay = DesktopSettingsOverlayView(model: model)
        overlay.frame = content.bounds
        overlay.autoresizingMask = [.width, .height]
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.panel.frame = DesktopSettingsGeometry.frame(in: overlay.bounds)
        model.onClose = { [weak self] in self?.close() }
        host.makeFirstResponder(overlay.panel)
    }

    var panelFrame: CGRect { overlay.panel.frame }

    /// Removes the overlay and gives focus back to whatever terminal had it.
    func close() {
        model.recorder.cancel()
        overlay.removeFromSuperview()
        if let host {
            Self.active.removeValue(forKey: ObjectIdentifier(host))
            if let previous = previousResponder, (previous as? NSView)?.window === host || previous === host {
                host.makeFirstResponder(previous)
            } else {
                host.makeFirstResponder(nil)
            }
        }
    }
}

/// Dims the host and keeps the panel centered and clamped on every layout.
@MainActor
final class DesktopSettingsOverlayView: NSView {
    let panel: NSHostingView<DesktopSettingsView>

    init(model: DesktopSettingsModel) {
        panel = NSHostingView(rootView: DesktopSettingsView(model: model))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        panel.wantsLayer = true
        panel.layer?.cornerRadius = DesktopMetrics.panelRadius
        panel.layer?.masksToBounds = true
        addSubview(panel)
        setAccessibilityIdentifier("desktop-settings")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        panel.frame = DesktopSettingsGeometry.frame(in: bounds)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        panel.frame = DesktopSettingsGeometry.frame(in: bounds)
    }

    /// Clicks outside the panel never reach the terminal underneath.
    override func mouseDown(with event: NSEvent) {}
    override var acceptsFirstResponder: Bool { true }
}
