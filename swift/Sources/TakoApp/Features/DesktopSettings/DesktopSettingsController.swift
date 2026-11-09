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
        model.hostWindow = host
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
        model.cancelDraft()
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

/// Dims the host (reference scrim rgba(10,8,7,.08)) and keeps the panel
/// centered and clamped on every layout. The panel clips its content to the
/// 12 pt radius; a sibling layer behind it draws the 1 pt rim and shadow.
@MainActor
final class DesktopSettingsOverlayView: NSView {
    let panel: NSHostingView<DesktopSettingsView>
    private let rim = NSView()
    private var appearanceObservation: Any?

    init(model: DesktopSettingsModel) {
        panel = NSHostingView(rootView: DesktopSettingsView(model: model))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = DesktopSettingsStyle.scrim.cgColor
        rim.wantsLayer = true
        rim.layer?.cornerRadius = DesktopMetrics.panelRadius
        rim.layer?.borderWidth = 1
        rim.layer?.shadowOpacity = 1
        addSubview(rim)
        panel.wantsLayer = true
        panel.layer?.cornerRadius = DesktopMetrics.panelRadius
        panel.layer?.masksToBounds = true
        addSubview(panel)
        setAccessibilityIdentifier("DesktopSettingsScrim")
        paintRim()
        appearanceObservation = DesktopPresentation.shared.$isDark.sink { [weak self] _ in
            DispatchQueue.main.async { self?.paintRim() }
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func paintRim() {
        let palette = DesktopPresentation.shared.palette
        let dark = DesktopPresentation.shared.isDark
        rim.layer?.backgroundColor = palette.popover.cgColor
        rim.layer?.borderColor = palette.border.cgColor
        rim.layer?.shadowColor = palette.shadow.cgColor
        rim.layer?.shadowRadius = dark ? 22 : 20
        rim.layer?.shadowOffset = CGSize(width: 0, height: dark ? -18 : -16)
    }

    private func place() {
        let frame = DesktopSettingsGeometry.frame(in: bounds)
        panel.frame = frame
        rim.frame = frame.insetBy(dx: -1, dy: -1)
        rim.layer?.shadowPath = CGPath(roundedRect: rim.bounds, cornerWidth: DesktopMetrics.panelRadius + 1,
                                       cornerHeight: DesktopMetrics.panelRadius + 1, transform: nil)
    }

    override func layout() {
        super.layout()
        place()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        place()
    }

    /// Clicks outside the panel never reach the terminal underneath.
    override func mouseDown(with event: NSEvent) {}
    override var acceptsFirstResponder: Bool { true }
}
