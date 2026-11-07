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
import QuartzCore
import SwiftUI

/// Kind of short visual pane transition on the floating canvas.
enum FloatingPaneTransitionKind: String, Equatable, Sendable {
    case minimizing
    case restoring
    case modeMorph
}

/// Generation-counted visual transition metadata for `180–220ms` transform-only pane motion.
/// Never alters `SurfaceView` layout bounds or triggers intermediate PTY/grid resizes.
struct FloatingPaneTransition: Equatable {
    let generation: UInt64
    let surfaceId: UUID
    let kind: FloatingPaneTransitionKind
    let fromRect: CGRect
    let toRect: CGRect
    let title: String
    let backgroundColor: NSColor
    let backgroundOpacity: Double
    let statusColor: NSColor
}

/// Pure geometry and CoreAnimation helpers for `190ms` floating pane motion.
enum FloatingCanvasMotion {
    static let duration: TimeInterval = 0.19
    static let layerAnimationKey = "takoFloatingPaneMorph"
    static let shelfGhostWidth: CGFloat = 168

    /// Approximate bottom-right shelf pill rect used as the morph anchor for minimize/restore.
    static func shelfAnchorRect(in canvasSize: CGSize, minimizedCount: Int = 1) -> CGRect {
        let safe = FloatingPaneGeometry.sanitizedCanvasSize(canvasSize)
        let cardH = FloatingPaneGeometry.shelfCardHeight
        let cardW = min(shelfGhostWidth, max(96, safe.width - 24))
        let verticalInset = max(4, ((FloatingPaneGeometry.shelfBandHeight - cardH) * 0.5).rounded())
        let indexOffset = CGFloat(min(max(0, minimizedCount - 1), 3)) * 10
        let x = max(12, safe.width - 12 - cardW - indexOffset)
        let y = max(0, safe.height - verticalInset - cardH)
        return CGRect(x: x, y: y, width: cardW, height: cardH)
    }

    /// Computes the initial CoreAnimation `CATransform3D` mapping `toRect` (the view's settled model frame)
    /// onto `fromRect` around `anchorPoint` without mutating `NSView.frame` or `bounds`.
    static func initialLayerTransform(
        from fromRect: CGRect,
        to toRect: CGRect,
        anchorPoint: CGPoint,
        superviewIsFlipped: Bool
    ) -> CATransform3D {
        guard toRect.width > 1, toRect.height > 1, fromRect.width > 1, fromRect.height > 1 else {
            return CATransform3DIdentity
        }
        let sx = min(max(fromRect.width / toRect.width, 0.08), 2.5)
        let sy = min(max(fromRect.height / toRect.height, 0.05), 2.5)

        let toAnchorX = toRect.minX + anchorPoint.x * toRect.width
        let fromAnchorX = fromRect.minX + anchorPoint.x * fromRect.width
        let tx = fromAnchorX - toAnchorX

        let ty: CGFloat
        if superviewIsFlipped {
            let toAnchorY = toRect.minY + anchorPoint.y * toRect.height
            let fromAnchorY = fromRect.minY + anchorPoint.y * fromRect.height
            ty = fromAnchorY - toAnchorY
        } else {
            let toAnchorY = toRect.maxY - anchorPoint.y * toRect.height
            let fromAnchorY = fromRect.maxY - anchorPoint.y * fromRect.height
            ty = toAnchorY - fromAnchorY
        }

        let scale = CATransform3DMakeScale(sx, sy, 1)
        let translate = CATransform3DMakeTranslation(tx, ty, 0)
        return CATransform3DConcat(scale, translate)
    }

    @MainActor
    static func applyOrCancelLayerMorph(
        on view: NSView,
        surfaceId: UUID,
        settledFrame: CGRect,
        transition: FloatingPaneTransition?,
        lastAppliedGeneration: inout UInt64,
        reduceMotion: Bool
    ) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }

        guard !reduceMotion,
              let transition,
              transition.surfaceId == surfaceId,
              transition.kind == .restoring || transition.kind == .modeMorph
        else {
            if layer.animation(forKey: layerAnimationKey) != nil {
                layer.removeAnimation(forKey: layerAnimationKey)
            }
            return
        }

        guard lastAppliedGeneration != transition.generation else { return }
        lastAppliedGeneration = transition.generation
        layer.removeAnimation(forKey: layerAnimationKey)

        guard settledFrame.width > 1, settledFrame.height > 1,
              abs(transition.fromRect.minX - settledFrame.minX) > 0.5
                || abs(transition.fromRect.minY - settledFrame.minY) > 0.5
                || abs(transition.fromRect.width - settledFrame.width) > 0.5
                || abs(transition.fromRect.height - settledFrame.height) > 0.5
        else {
            return
        }

        let startTransform = initialLayerTransform(
            from: transition.fromRect,
            to: settledFrame,
            anchorPoint: layer.anchorPoint,
            superviewIsFlipped: view.superview?.isFlipped ?? false
        )

        let transformAnim = CABasicAnimation(keyPath: "transform")
        transformAnim.fromValue = NSValue(caTransform3D: startTransform)
        transformAnim.toValue = NSValue(caTransform3D: CATransform3DIdentity)

        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = transition.kind == .restoring ? 0.38 : 0.88
        opacityAnim.toValue = 1.0

        let group = CAAnimationGroup()
        group.animations = [transformAnim, opacityAnim]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = true
        layer.add(group, forKey: layerAnimationKey)
    }
}

/// Non-interactive outgoing visual card animated toward the bottom-right shelf during `minimize`.
/// Uses app-only surface/header styling so the single live `SurfaceView` detaches cleanly once
/// without `CAMetalLayer` framebuffer readback or intermediate PTY resizes.
struct FloatingPaneTransitionGhostView: View {
    @Environment(\.colorScheme) private var colorScheme
    let transition: FloatingPaneTransition
    @State private var collapsedToShelf = false

    private typealias T = Tako.LivingTokens

    var body: some View {
        let currentRect = collapsedToShelf ? transition.toRect : transition.fromRect
        let cornerRadius: CGFloat = collapsedToShelf ? 15 : FloatingPaneGeometry.cornerRadius

        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color(nsColor: transition.statusColor))
                    .frame(width: 7, height: 7)
                Text(transition.title)
                    .font(Font(T.monoFont(size: 11, weight: .medium)))
                    .foregroundColor(Color(nsColor: T.textInactive))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: min(FloatingPaneGeometry.headerHeight, currentRect.height))

            Spacer(minLength: 0)
        }
        .frame(width: max(1, currentRect.width), height: max(1, currentRect.height))
        .background(
            Color(nsColor: transition.backgroundColor)
                .opacity(transition.backgroundOpacity)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    colorScheme == .light
                        ? Color.black.opacity(0.10)
                        : Color.white.opacity(0.10),
                    lineWidth: 1
                )
        )
        .opacity(collapsedToShelf ? 0.14 : 0.94)
        .position(x: currentRect.midX, y: currentRect.midY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            collapsedToShelf = false
            withAnimation(.easeIn(duration: FloatingCanvasMotion.duration)) {
                collapsedToShelf = true
            }
        }
        .onChange(of: transition.generation) { _, _ in
            collapsedToShelf = false
            withAnimation(.easeIn(duration: FloatingCanvasMotion.duration)) {
                collapsedToShelf = true
            }
        }
    }
}
