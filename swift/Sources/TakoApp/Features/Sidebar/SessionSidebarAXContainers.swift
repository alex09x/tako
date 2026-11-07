/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

/// Real AppKit `AXGroup` element exposing `SessionSidebarWorkspace-<name>` with live `"active"` / `"inactive"`
/// `AXValue` while passing all mouse clicks, context menus, and drag-and-drop gestures through untouched.
final class SidebarWorkspaceAXNSView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct SidebarWorkspaceAXElement: NSViewRepresentable {
    let name: String
    let isActive: Bool

    func makeNSView(context: Context) -> SidebarWorkspaceAXNSView {
        let view = SidebarWorkspaceAXNSView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ nsView: SidebarWorkspaceAXNSView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: SidebarWorkspaceAXNSView) {
        view.setAccessibilityIdentifier("SessionSidebarWorkspace-\(name)")
        view.setAccessibilityLabel(name)
        view.setAccessibilityValue(isActive ? "active" : "inactive")
    }
}

/// Real AppKit `AXGroup` container backing `session-tab-<id>` / `session-pane-<id>` so macOS
/// Accessibility and XCUITest reliably read `"selected"` / `"unselected"` `AXValue` and `dot:#...`
/// `AXHelp` without duplicate row identifiers while keeping `XCUIElement.isHittable`, clicks,
/// drag-and-drop, and right-click context menus intact.
@MainActor
final class SidebarRowAXContainerNSView<Content: View>: NSView {
    private let hostingController: NSHostingController<Content>
    private var lastFittedHeight: CGFloat = -1

    init(rootView: Content) {
        self.hostingController = NSHostingController(rootView: rootView)
        super.init(frame: .zero)
        hostingController.safeAreaRegions = []
        hostingController.sizingOptions = []
        let hostedView = hostingController.view
        hostedView.translatesAutoresizingMaskIntoConstraints = true
        hostedView.autoresizingMask = [.width, .height]
        hostedView.frame = bounds
        addSubview(hostedView)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func update(
        rootView: Content,
        identifier: String,
        label: String,
        value: String,
        help: String,
        closeActionName: String?,
        onClose: (() -> Void)?
    ) {
        hostingController.rootView = rootView
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(label)
        setAccessibilityValue(value)
        setAccessibilityHelp(help)
        if let closeActionName, let onClose {
            setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: closeActionName) {
                    onClose()
                    return true
                }
            ])
        } else {
            setAccessibilityCustomActions(nil)
        }
        if bounds.width > 0 {
            let h = hostingController.sizeThatFits(in: CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
            if abs(h - lastFittedHeight) > 0.5 {
                lastFittedHeight = h
                invalidateIntrinsicContentSize()
            }
        }
    }

    func fittingRowSize(for proposal: ProposedViewSize) -> CGSize {
        if let w = proposal.width {
            guard w.isFinite else {
                let fitted = hostingController.view.fittingSize
                return CGSize(width: w, height: fitted.height)
            }
            guard w > 0 else {
                let fitted = hostingController.sizeThatFits(in: CGSize(width: CGFloat.zero, height: CGFloat.greatestFiniteMagnitude))
                return CGSize(width: 0, height: fitted.height)
            }
            let fitted = hostingController.sizeThatFits(in: CGSize(width: w, height: .greatestFiniteMagnitude))
            lastFittedHeight = fitted.height
            return CGSize(width: w, height: fitted.height)
        }
        let fitted = hostingController.view.fittingSize
        lastFittedHeight = fitted.height
        return fitted
    }

    override func layout() {
        super.layout()
        let hostedView = hostingController.view
        if hostedView.frame != bounds {
            hostedView.frame = bounds
        }
    }

    override func accessibilityChildren() -> [Any]? {
        NSAccessibility.unignoredChildren(from: subviews)
    }
}

struct SidebarRowAXContainer<Content: View>: NSViewRepresentable {
    let identifier: String
    let label: String
    let value: String
    let help: String
    let closeActionName: String?
    let onClose: (() -> Void)?
    let content: Content

    init(
        identifier: String,
        label: String,
        value: String,
        help: String,
        closeActionName: String?,
        onClose: (() -> Void)?,
        @ViewBuilder content: () -> Content
    ) {
        self.identifier = identifier
        self.label = label
        self.value = value
        self.help = help
        self.closeActionName = closeActionName
        self.onClose = onClose
        self.content = content()
    }

    func makeNSView(context: Context) -> SidebarRowAXContainerNSView<Content> {
        let view = SidebarRowAXContainerNSView(rootView: content)
        view.update(
            rootView: content,
            identifier: identifier,
            label: label,
            value: value,
            help: help,
            closeActionName: closeActionName,
            onClose: onClose
        )
        return view
    }

    func updateNSView(_ nsView: SidebarRowAXContainerNSView<Content>, context: Context) {
        nsView.update(
            rootView: content,
            identifier: identifier,
            label: label,
            value: value,
            help: help,
            closeActionName: closeActionName,
            onClose: onClose
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: SidebarRowAXContainerNSView<Content>,
        context: Context
    ) -> CGSize? {
        nsView.fittingRowSize(for: proposal)
    }
}
