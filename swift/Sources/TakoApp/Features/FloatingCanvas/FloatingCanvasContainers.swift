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

/// Real AppKit `AXGroup` container backing `FloatingPane-<uuid>` so macOS Accessibility / XCUITest
/// reliably exposes the root pane group with its full header+body frame, live status `AXValue`,
/// and non-duplicated individually reachable child elements.
final class FloatingPaneAXContainerNSView<Content: View>: NSView {
    private let hostingView: NSHostingView<Content>
    private(set) var lastAppliedTransitionGeneration: UInt64 = 0
    private var pendingSurfaceId = UUID()
    private var pendingSettledFrame: CGRect = .zero
    private var pendingTransition: FloatingPaneTransition?
    private var pendingReduceMotion = false

    init(rootView: Content) {
        self.hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        hostingView.safeAreaRegions = []
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = bounds
        addSubview(hostingView)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func update(
        rootView: Content,
        surfaceId: UUID,
        settledFrame: CGRect,
        activeTransition: FloatingPaneTransition?,
        reduceMotion: Bool,
        identifier: String,
        label: String,
        value: String
    ) {
        hostingView.rootView = rootView
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(label)
        setAccessibilityValue(value)
        pendingSurfaceId = surfaceId
        pendingSettledFrame = settledFrame
        pendingTransition = activeTransition
        pendingReduceMotion = reduceMotion
        syncLayerMorph()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        syncLayerMorph()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncLayerMorph()
    }

    override func layout() {
        super.layout()
        if hostingView.frame != bounds {
            hostingView.frame = bounds
        }
        syncLayerMorph()
    }

    private func syncLayerMorph() {
        FloatingCanvasMotion.applyOrCancelLayerMorph(
            on: self,
            surfaceId: pendingSurfaceId,
            settledFrame: pendingSettledFrame,
            transition: pendingTransition,
            lastAppliedGeneration: &lastAppliedTransitionGeneration,
            reduceMotion: pendingReduceMotion
        )
    }

    override func accessibilityChildren() -> [Any]? {
        NSAccessibility.unignoredChildren(from: subviews)
    }
}

struct FloatingPaneAXContainer<Content: View>: NSViewRepresentable {
    let surfaceId: UUID
    let settledFrame: CGRect
    let activeTransition: FloatingPaneTransition?
    let reduceMotion: Bool
    let identifier: String
    let label: String
    let value: String
    let content: Content

    init(
        surfaceId: UUID,
        settledFrame: CGRect,
        activeTransition: FloatingPaneTransition?,
        reduceMotion: Bool,
        identifier: String,
        label: String,
        value: String,
        @ViewBuilder content: () -> Content
    ) {
        self.surfaceId = surfaceId
        self.settledFrame = settledFrame
        self.activeTransition = activeTransition
        self.reduceMotion = reduceMotion
        self.identifier = identifier
        self.label = label
        self.value = value
        self.content = content()
    }

    func makeNSView(context: Context) -> FloatingPaneAXContainerNSView<Content> {
        let view = FloatingPaneAXContainerNSView(rootView: content)
        view.update(
            rootView: content,
            surfaceId: surfaceId,
            settledFrame: settledFrame,
            activeTransition: activeTransition,
            reduceMotion: reduceMotion,
            identifier: identifier,
            label: label,
            value: value
        )
        return view
    }

    func updateNSView(_ nsView: FloatingPaneAXContainerNSView<Content>, context: Context) {
        nsView.update(
            rootView: content,
            surfaceId: surfaceId,
            settledFrame: settledFrame,
            activeTransition: activeTransition,
            reduceMotion: reduceMotion,
            identifier: identifier,
            label: label,
            value: value
        )
    }
}

struct EmptyFloatingCanvasView: View {
    let onCreateTerminal: () -> Void
    private typealias T = Tako.LivingTokens

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 26, weight: .regular))
                .foregroundColor(Color(nsColor: T.dim))

            Text("No open terminals in this session")
                .font(Font(T.monoFont(size: 13, weight: .medium)))
                .foregroundColor(Color(nsColor: T.textActive))

            Text("Open a new terminal pane here or press ⌘W to close this empty session.")
                .font(Font(T.monoFont(size: 11, weight: .regular)))
                .foregroundColor(Color(nsColor: T.dim))
                .multilineTextAlignment(.center)

            ZStack {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("New Terminal")
                        .font(Font(T.monoFont(size: 11.5, weight: .medium)))
                }
                .foregroundColor(Color(nsColor: T.textActive))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: T.surfaceActive))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color(nsColor: T.ghostBorder), lineWidth: 1)
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                FloatingActionButtonOverlay(
                    identifier: "FloatingCanvasNewTerminal",
                    label: "New Terminal",
                    value: "",
                    helpText: "Open a new terminal pane",
                    onHoverChange: { _ in },
                    action: onCreateTerminal
                )
            }
            .fixedSize(horizontal: true, vertical: true)
        }
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("FloatingCanvasEmptyState")
    }
}
