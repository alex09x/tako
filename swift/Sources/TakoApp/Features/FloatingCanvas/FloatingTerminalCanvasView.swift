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

/// Right-hand desktop workspace canvas hosting freely floating/maximized terminal panes,
/// the bottom-right minimize shelf, and the empty-session state when all panes are closed.
struct FloatingTerminalCanvasView: View {
    @EnvironmentObject var tako: Tako.App
    @ObservedObject var controller: BaseTerminalController
    @ObservedObject var store: FloatingCanvasStore

    private typealias T = Tako.LivingTokens

    var body: some View {
        GeometryReader { geometry in
            let canvasSize = effectiveSize(from: geometry.size)
            let hasMinimized = store.hasMinimizedPanes
            let workArea = FloatingPaneGeometry.workArea(in: canvasSize, hasMinimizedPanes: hasMinimized)

            ZStack(alignment: .bottomTrailing) {
                tako.config.backgroundColor
                    .opacity(tako.config.backgroundOpacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if controller.surfaceTree.isEmpty {
                    EmptyFloatingCanvasView(
                        onCreateTerminal: {
                            _ = controller.createSurfaceInCurrentSession()
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .frame(width: canvasSize.width, height: canvasSize.height)

                        ForEach(store.visiblePanesSortedByZ, id: \.surfaceId) { pane in
                            if let surfaceView = controller.surfaceTree.first(where: { $0.id == pane.surfaceId }) {
                                let frame = FloatingPaneGeometry.presentedFrame(
                                    for: pane,
                                    in: canvasSize,
                                    hasMinimizedPanes: hasMinimized
                                )
                                FloatingPaneWindowView(
                                    surfaceView: surfaceView,
                                    crab: surfaceView.crab,
                                    pane: pane,
                                    frame: frame,
                                    workArea: workArea,
                                    canvasSize: canvasSize,
                                    isFocused: controller.focusedSurface === surfaceView,
                                    canMoveToNewWindow: controller.surfaceTree.isSplit,
                                    onActivate: {
                                        controller.activateFloatingPane(surfaceView)
                                    },
                                    onDragMove: { rect in
                                        store.setInteractiveRect(rect, for: surfaceView.id, in: canvasSize)
                                    },
                                    onDetachMaximized: { px, py in
                                        store.detachMaximizedForDrag(
                                            surfaceView.id,
                                            pointerXInCanvas: px,
                                            pointerYInHeader: py,
                                            in: canvasSize
                                        )
                                    },
                                    onGestureCommit: {
                                        store.commitInteractiveRect(for: surfaceView.id, in: canvasSize)
                                    },
                                    onMinimize: {
                                        controller.minimizeFloatingPane(surfaceView)
                                    },
                                    onToggleMaximize: {
                                        controller.toggleMaximizeFloatingPane(surfaceView, in: canvasSize)
                                    },
                                    onMoveToNewWindow: {
                                        NotificationCenter.default.post(
                                            name: .takoSurfaceDragEndedNoTarget,
                                            object: surfaceView
                                        )
                                    },
                                    onClose: {
                                        controller.closeFloatingPane(surfaceView)
                                    }
                                )
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                                .zIndex(Double(pane.zOrder))
                            }
                        }
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)

                    if hasMinimized {
                        FloatingMinimizeShelfView(
                            minimizedPanes: store.minimizedPanes,
                            surfaceLookup: { id in controller.surfaceTree.first(where: { $0.id == id }) },
                            onRestore: { surface in
                                controller.revealAndFocusFloatingPane(surface, in: canvasSize)
                            }
                        )
                        .zIndex(1_000_000)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .onAppear {
                if FloatingPaneGeometry.isValidCanvasSize(geometry.size) {
                    store.updateCanvasSize(geometry.size, tree: controller.surfaceTree)
                }
            }
            .onChange(of: geometry.size) { _, newSize in
                if FloatingPaneGeometry.isValidCanvasSize(newSize) {
                    store.updateCanvasSize(newSize, tree: controller.surfaceTree)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("FloatingTerminalCanvas")
    }

    private func effectiveSize(from rawSize: CGSize) -> CGSize {
        if FloatingPaneGeometry.isValidCanvasSize(rawSize) {
            return rawSize
        }
        return store.effectiveCanvasSize(fallback: controller.estimatedFloatingCanvasSize())
    }
}

private struct FloatingPaneWindowView: View {
    @EnvironmentObject private var tako: Tako.App
    @Environment(\.takoLastFocusedSurface) private var lastFocusedSurface
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var surfaceView: Tako.SurfaceView
    @ObservedObject var crab: Tako.CrabTracker
    let pane: FloatingPaneState
    let frame: CGRect
    let workArea: CGRect
    let canvasSize: CGSize
    let isFocused: Bool
    let canMoveToNewWindow: Bool
    let onActivate: () -> Void
    let onDragMove: (CGRect) -> Void
    let onDetachMaximized: (CGFloat, CGFloat) -> CGRect?
    let onGestureCommit: () -> Void
    let onMinimize: () -> Void
    let onToggleMaximize: () -> Void
    let onMoveToNewWindow: () -> Void
    let onClose: () -> Void

    private typealias T = Tako.LivingTokens

    private var uuidKey: String {
        surfaceView.id.uuidString.lowercased()
    }

    private var statusValue: String {
        FloatingPaneGeometry.accessibilityStatusValue(for: crab.paneStatus)
    }

    private var isNormal: Bool {
        pane.mode == .normal
    }

    private var radius: CGFloat {
        isNormal ? FloatingPaneGeometry.cornerRadius : 0
    }

    private var paneContent: some View {
        VStack(spacing: 0) {
            FloatingPaneHeaderView(
                surfaceView: surfaceView,
                crab: surfaceView.crab,
                pane: pane,
                presentedFrame: frame,
                isFocused: isFocused,
                canvasSize: canvasSize,
                canMoveToNewWindow: canMoveToNewWindow,
                onActivate: onActivate,
                onDragMove: onDragMove,
                onDetachMaximized: onDetachMaximized,
                onDragCommit: onGestureCommit,
                onMinimize: onMinimize,
                onToggleMaximize: onToggleMaximize,
                onMoveToNewWindow: onMoveToNewWindow,
                onClose: onClose
            )

            Tako.InspectableSurface(surfaceView: surfaceView, isSplit: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            (surfaceView.backgroundColor ?? surfaceView.derivedConfig.backgroundColor)
                .opacity(surfaceView.derivedConfig.backgroundOpacity)
        )
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            if isNormal {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        isFocused
                            ? Color(nsColor: T.ember).opacity(0.65)
                            : Color(nsColor: T.ghostBorder),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if isNormal {
                FloatingPaneResizeHandlesView(
                    surfaceId: surfaceView.id,
                    paneRect: frame,
                    workArea: workArea,
                    onActivate: onActivate,
                    onResizeMove: onDragMove,
                    onResizeCommit: onGestureCommit
                )
            }
        }
        .ignoresSafeArea()
        .environmentObject(tako)
        .takoLastFocusedSurface(lastFocusedSurface)
        .environment(\.colorScheme, colorScheme)
    }

    var body: some View {
        FloatingPaneAXContainer(
            identifier: "FloatingPane-\(uuidKey)",
            label: "\(FloatingPaneGeometry.shortTitle(for: surfaceView)), \(statusValue)",
            value: statusValue
        ) {
            paneContent
        }
        .focusedValue(\.takoSurfacePwd, isFocused ? (surfaceView.pwd ?? "") : nil)
        .focusedValue(\.takoSurfaceCellSize, isFocused ? surfaceView.cellSize : nil)
        .shadow(
            color: isNormal ? Color.black.opacity(isFocused ? 0.36 : 0.22) : .clear,
            radius: isNormal ? (isFocused ? 14 : 8) : 0,
            x: 0,
            y: isNormal ? 4 : 0
        )
    }
}

/// Real AppKit `AXGroup` container backing `FloatingPane-<uuid>` so macOS Accessibility / XCUITest
/// reliably exposes the root pane group with its full header+body frame, live status `AXValue`,
/// and non-duplicated individually reachable child elements.
final class FloatingPaneAXContainerNSView<Content: View>: NSView {
    private let hostingView: NSHostingView<Content>

    init(rootView: Content) {
        self.hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
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

    func update(rootView: Content, identifier: String, label: String, value: String) {
        hostingView.rootView = rootView
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(label)
        setAccessibilityValue(value)
    }

    override func layout() {
        super.layout()
        if hostingView.frame != bounds {
            hostingView.frame = bounds
        }
    }

    override func accessibilityChildren() -> [Any]? {
        NSAccessibility.unignoredChildren(from: subviews)
    }
}

private struct FloatingPaneAXContainer<Content: View>: NSViewRepresentable {
    let identifier: String
    let label: String
    let value: String
    let content: Content

    init(identifier: String, label: String, value: String, @ViewBuilder content: () -> Content) {
        self.identifier = identifier
        self.label = label
        self.value = value
        self.content = content()
    }

    func makeNSView(context: Context) -> FloatingPaneAXContainerNSView<Content> {
        let view = FloatingPaneAXContainerNSView(rootView: content)
        view.update(rootView: content, identifier: identifier, label: label, value: value)
        return view
    }

    func updateNSView(_ nsView: FloatingPaneAXContainerNSView<Content>, context: Context) {
        nsView.update(rootView: content, identifier: identifier, label: label, value: value)
    }
}

private struct EmptyFloatingCanvasView: View {
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
