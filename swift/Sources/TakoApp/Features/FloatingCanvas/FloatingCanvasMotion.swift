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
    static let ghostAnimationKey = "takoFloatingPaneGhostMorph"
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

    /// Determines whether `+Y` in `layer.superlayer` moves downward on screen by Parity (XOR)
    /// of `CALayer.isGeometryFlipped` across the ancestor layer chain, falling back to `view.superview?.isFlipped`.
    static func effectiveSuperlayerYPointsDown(for layer: CALayer, fallbackView: NSView?) -> Bool {
        guard let superlayer = layer.superlayer else {
            return fallbackView?.superview?.isFlipped ?? false
        }
        var yPointsDown = false
        var current: CALayer? = superlayer
        while let ancestor = current {
            if ancestor.isGeometryFlipped {
                yPointsDown.toggle()
            }
            current = ancestor.superlayer
        }
        return yPointsDown
    }

    /// Computes the exact CoreAnimation `CATransform3D` mapping `toRect` (settled top-down canvas frame)
    /// onto `fromRect` around `anchorPoint` without ratio clamping or mutating `NSView.frame` / `bounds`.
    static func initialLayerTransform(
        from fromRect: CGRect,
        to toRect: CGRect,
        anchorPoint: CGPoint,
        superviewIsFlipped: Bool
    ) -> CATransform3D {
        guard toRect.width.isFinite, toRect.height.isFinite,
              fromRect.width.isFinite, fromRect.height.isFinite,
              toRect.width > 0, toRect.height > 0,
              fromRect.width > 0, fromRect.height > 0
        else {
            return CATransform3DIdentity
        }
        let sx = fromRect.width / toRect.width
        let sy = fromRect.height / toRect.height
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0 else {
            return CATransform3DIdentity
        }

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

    /// Pure verification helper mapping a normalized corner `(u, v)` (`0...1` in superlayer axes)
    /// of a view settled at top-down canvas `toRect` under `transform` back into top-down canvas coordinates.
    static func transformedCanvasCorner(
        u: CGFloat,
        v: CGFloat,
        settledCanvasRect toRect: CGRect,
        transform: CATransform3D,
        anchorPoint: CGPoint,
        superviewIsFlipped: Bool,
        canvasHeight: CGFloat = 1000
    ) -> CGPoint {
        let localRel = CGPoint(
            x: (u - anchorPoint.x) * toRect.width,
            y: (v - anchorPoint.y) * toRect.height
        )
        let transformedRelX = localRel.x * transform.m11 + localRel.y * transform.m21 + transform.m41
        let transformedRelY = localRel.x * transform.m12 + localRel.y * transform.m22 + transform.m42

        let posX = toRect.minX + anchorPoint.x * toRect.width
        let superX = posX + transformedRelX

        if superviewIsFlipped {
            let posY = toRect.minY + anchorPoint.y * toRect.height
            let superY = posY + transformedRelY
            return CGPoint(x: superX, y: superY)
        } else {
            let settledMinYUnflipped = canvasHeight - toRect.maxY
            let posY = settledMinYUnflipped + anchorPoint.y * toRect.height
            let superY = posY + transformedRelY
            return CGPoint(x: superX, y: canvasHeight - superY)
        }
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

        // Wait until the NSView is attached to its live window/superlayer and has non-zero bounds
        // so fresh restore mounts never evaluate superlayer flip or anchor offset prematurely.
        guard view.window != nil,
              view.superview != nil,
              view.bounds.width > 1,
              view.bounds.height > 1
        else {
            return
        }

        guard lastAppliedGeneration != transition.generation else { return }
        lastAppliedGeneration = transition.generation
        layer.removeAnimation(forKey: layerAnimationKey)
        layer.masksToBounds = false

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
            superviewIsFlipped: effectiveSuperlayerYPointsDown(for: layer, fallbackView: view)
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

/// Non-interactive AppKit outgoing ghost card mounted per `transition.generation` during `minimize`.
/// Each generation gets a distinct `NSView` instance via `.id(ghost.generation)` so rapid `minA -> minB`
/// immediately tears down `A` and starts `B` cleanly from `B.fromRect` without reusing collapsed state.
final class FloatingPaneGhostNSView: NSView {
    private(set) var transition: FloatingPaneTransition
    private(set) var lastAppliedGeneration: UInt64 = 0

    private let cardLayer = CALayer()
    private let dotLayer = CALayer()
    private let titleLayer = CATextLayer()

    var generation: UInt64 { transition.generation }
    var surfaceId: UUID { transition.surfaceId }

    override var isFlipped: Bool { true }

    init(transition: FloatingPaneTransition) {
        self.transition = transition
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        setAccessibilityElement(false)
        setupSublayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityHidden() -> Bool { true }
    override func accessibilityChildren() -> [Any]? { [] }

    private func setupSublayers() {
        guard let root = layer else { return }
        root.masksToBounds = false

        cardLayer.cornerCurve = .continuous
        cardLayer.cornerRadius = 15
        cardLayer.masksToBounds = true
        cardLayer.borderWidth = 1
        root.addSublayer(cardLayer)

        dotLayer.cornerRadius = 3.5
        cardLayer.addSublayer(dotLayer)

        titleLayer.fontSize = 11
        titleLayer.truncationMode = .end
        titleLayer.alignmentMode = .left
        titleLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        cardLayer.addSublayer(titleLayer)
    }

    func configure(with transition: FloatingPaneTransition) {
        self.transition = transition
        let bg = transition.backgroundColor.withAlphaComponent(CGFloat(transition.backgroundOpacity))
        cardLayer.backgroundColor = bg.cgColor
        cardLayer.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        dotLayer.backgroundColor = transition.statusColor.cgColor
        titleLayer.foregroundColor = Tako.LivingTokens.textInactive.cgColor
        titleLayer.font = Tako.LivingTokens.monoFont(size: 11, weight: .medium)
        titleLayer.string = transition.title
        needsLayout = true
        startGhostMorphIfReady()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        startGhostMorphIfReady()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor {
            titleLayer.contentsScale = scale
        }
        startGhostMorphIfReady()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardLayer.frame = bounds
        let headerH = min(FloatingPaneGeometry.headerHeight, bounds.height)
        let dotY = max(2, (headerH - 7) * 0.5)
        dotLayer.frame = CGRect(x: 12, y: dotY, width: 7, height: 7)
        let titleH: CGFloat = 14
        let titleY = max(1, (headerH - titleH) * 0.5)
        titleLayer.frame = CGRect(x: 26, y: titleY, width: max(0, bounds.width - 36), height: titleH)
        CATransaction.commit()
        startGhostMorphIfReady()
    }

    private func startGhostMorphIfReady() {
        guard let root = layer,
              window != nil,
              superview != nil,
              bounds.width > 1,
              bounds.height > 1,
              lastAppliedGeneration != transition.generation
        else { return }

        lastAppliedGeneration = transition.generation
        root.removeAnimation(forKey: FloatingCanvasMotion.ghostAnimationKey)
        root.opacity = 0.14

        let startTransform = FloatingCanvasMotion.initialLayerTransform(
            from: transition.fromRect,
            to: transition.toRect,
            anchorPoint: root.anchorPoint,
            superviewIsFlipped: FloatingCanvasMotion.effectiveSuperlayerYPointsDown(for: root, fallbackView: self)
        )

        let transformAnim = CABasicAnimation(keyPath: "transform")
        transformAnim.fromValue = NSValue(caTransform3D: startTransform)
        transformAnim.toValue = NSValue(caTransform3D: CATransform3DIdentity)

        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = 0.94
        opacityAnim.toValue = 0.14

        let group = CAAnimationGroup()
        group.animations = [transformAnim, opacityAnim]
        group.duration = FloatingCanvasMotion.duration
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        group.isRemovedOnCompletion = true
        root.add(group, forKey: FloatingCanvasMotion.ghostAnimationKey)
    }
}

struct FloatingPaneTransitionGhostView: NSViewRepresentable {
    let transition: FloatingPaneTransition

    func makeNSView(context: Context) -> FloatingPaneGhostNSView {
        let view = FloatingPaneGhostNSView(transition: transition)
        view.configure(with: transition)
        return view
    }

    func updateNSView(_ nsView: FloatingPaneGhostNSView, context: Context) {
        nsView.configure(with: transition)
    }
}
