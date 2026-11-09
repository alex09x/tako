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
            let frames = store.presentedFrames(in: canvasSize)

            ZStack(alignment: .bottomTrailing) {
                // The field under the terminals is the shell's (app-appearance),
                // not the terminal theme's.
                Color(nsColor: Tako.LivingTokens.body)
                    .opacity(tako.config.backgroundOpacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .shellScheme()

                if controller.surfaceTree.isEmpty {
                    EmptyFloatingCanvasView(
                        onCreateTerminal: {
                            _ = controller.createSurfaceInCurrentSession()
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .shellScheme()
                } else {
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .frame(width: canvasSize.width, height: canvasSize.height)

                        ForEach(store.visiblePanesSortedByZ, id: \.surfaceId) { pane in
                            if let surfaceView = controller.surfaceTree.first(where: { $0.id == pane.surfaceId }) {
                                let frame = frames[pane.surfaceId] ?? FloatingPaneGeometry.presentedFrame(
                                    for: pane,
                                    in: canvasSize,
                                    hasMinimizedPanes: hasMinimized
                                )
                                FloatingPaneWindowView(
                                    surfaceView: surfaceView,
                                    crab: surfaceView.crab,
                                    pane: pane,
                                    isTiled: pane.mode == .normal && store.isTiled(pane.surfaceId),
                                    frame: frame,
                                    workArea: workArea,
                                    canvasSize: canvasSize,
                                    isFocused: controller.focusedSurface === surfaceView,
                                    canMoveToNewWindow: controller.surfaceTree.isSplit,
                                    activeTransition: store.activeTransition,
                                    reduceMotion: store.reduceMotionProvider(),
                                    onActivate: {
                                        controller.activateFloatingPane(surfaceView)
                                    },
                                    onDragMove: { rect in
                                        store.setInteractiveRect(rect, for: surfaceView.id, in: canvasSize)
                                    },
                                    onHeaderDrag: { rect in
                                        store.setInteractiveRect(rect, for: surfaceView.id, in: canvasSize)
                                        controller.updateCanvasDrop(for: surfaceView, in: canvasSize)
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
                                        if let target = store.dropTarget {
                                            _ = controller.dockCanvasPane(surfaceView, at: target)
                                        }
                                        store.dropTarget = nil
                                        store.commitInteractiveRect(for: surfaceView.id, in: canvasSize)
                                    },
                                    onMinimize: {
                                        controller.minimizeFloatingPane(surfaceView)
                                    },
                                    onToggleMaximize: {
                                        controller.toggleMaximizeFloatingPane(surfaceView, in: canvasSize)
                                    },
                                    onToggleFloating: {
                                        controller.togglePaneFloating(surfaceView, in: canvasSize)
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

                        if let target = store.dropTarget {
                            RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.16))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2))
                                .overlay(VStack(spacing: 4) {
                                    Text(target.label).font(.system(size: 12, weight: .medium))
                                    Text("⌥ to move freely").font(.system(size: 11))
                                })
                                .frame(width: target.frame.width, height: target.frame.height)
                                .position(x: target.frame.midX, y: target.frame.midY)
                                .allowsHitTesting(false)
                                .accessibilityIdentifier("CanvasDockPreview")
                                .zIndex(999_998)
                        }
                        if let ghost = store.activeTransition,
                           ghost.kind == .minimizing,
                           !store.reduceMotionProvider() {
                            FloatingPaneTransitionGhostView(transition: ghost)
                                .frame(width: max(1, ghost.fromRect.width), height: max(1, ghost.fromRect.height))
                                .position(x: ghost.fromRect.midX, y: ghost.fromRect.midY)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                                .id(ghost.generation)
                                .zIndex(999_999)
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
                        .shellScheme()
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
    let isTiled: Bool
    let frame: CGRect
    let workArea: CGRect
    let canvasSize: CGSize
    let isFocused: Bool
    let canMoveToNewWindow: Bool
    let activeTransition: FloatingPaneTransition?
    let reduceMotion: Bool
    let onActivate: () -> Void
    let onDragMove: (CGRect) -> Void
    let onHeaderDrag: (CGRect) -> Void
    let onDetachMaximized: (CGFloat, CGFloat) -> CGRect?
    let onGestureCommit: () -> Void
    let onMinimize: () -> Void
    let onToggleMaximize: () -> Void
    let onToggleFloating: () -> Void
    let onMoveToNewWindow: () -> Void
    let onClose: () -> Void

    @State private var isDraggingPane = false

    private var uuidKey: String {
        surfaceView.id.uuidString.lowercased()
    }

    private var statusValue: String {
        FloatingPaneGeometry.accessibilityStatusValue(for: crab.paneStatus)
    }

    /// Free floating: resize handles and the lifted shadow apply only here.
    private var isNormal: Bool {
        pane.mode == .normal && !isTiled
    }

    private var radius: CGFloat {
        pane.mode == .normal ? FloatingPaneGeometry.cornerRadius : 0
    }

    private var normalBorderColor: Color {
        if colorScheme == .light {
            return Color.black.opacity(isDraggingPane ? 0.18 : (isFocused ? 0.14 : 0.08))
        }
        return Color.white.opacity(isDraggingPane ? 0.17 : (isFocused ? 0.13 : 0.07))
    }

    private var paneContent: some View {
        VStack(spacing: 0) {
            FloatingPaneHeaderView(
                surfaceView: surfaceView,
                crab: surfaceView.crab,
                pane: pane,
                isTiled: isTiled,
                presentedFrame: frame,
                isFocused: isFocused,
                canvasSize: canvasSize,
                canMoveToNewWindow: canMoveToNewWindow,
                onDragStateChange: { isDraggingPane = $0 },
                onActivate: onActivate,
                onDragMove: onHeaderDrag,
                onDetachMaximized: onDetachMaximized,
                onDragCommit: onGestureCommit,
                onMinimize: onMinimize,
                onToggleMaximize: onToggleMaximize,
                onToggleFloating: onToggleFloating,
                onMoveToNewWindow: onMoveToNewWindow,
                onClose: onClose
            )
            .shellScheme()

            Tako.InspectableSurface(surfaceView: surfaceView, isSplit: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            (surfaceView.backgroundColor ?? surfaceView.derivedConfig.backgroundColor)
                .opacity(surfaceView.derivedConfig.backgroundOpacity)
        )
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            if pane.mode == .normal {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(normalBorderColor, lineWidth: 1)
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
            surfaceId: surfaceView.id,
            settledFrame: frame,
            activeTransition: activeTransition,
            reduceMotion: reduceMotion,
            identifier: "FloatingPane-\(uuidKey)",
            label: "\(FloatingPaneGeometry.shortTitle(for: surfaceView)), \(statusValue)",
            value: statusValue
        ) {
            paneContent
        }
        .focusedValue(\.takoSurfacePwd, isFocused ? (surfaceView.pwd ?? "") : nil)
        .focusedValue(\.takoSurfaceCellSize, isFocused ? surfaceView.cellSize : nil)
        .shadow(
            color: isNormal ? Color.black.opacity(isFocused ? 0.22 : 0.12) : .clear,
            radius: isNormal ? 4 : 0,
            x: 0,
            y: isNormal ? 2 : 0
        )
        .shadow(
            color: isNormal ? Color.black.opacity(isDraggingPane ? 0.52 : (isFocused ? 0.44 : 0.24)) : .clear,
            radius: isNormal ? (isDraggingPane ? 30 : (isFocused ? 24 : 12)) : 0,
            x: 0,
            y: isNormal ? (isDraggingPane ? 14 : (isFocused ? 10 : 5)) : 0
        )
    }
}
