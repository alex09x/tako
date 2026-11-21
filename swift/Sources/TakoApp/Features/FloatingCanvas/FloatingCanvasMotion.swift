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
        let inset = FloatingPaneGeometry.shelfInset
        let cardW = min(shelfGhostWidth, max(96, safe.width - 2 * inset))
        let indexOffset = CGFloat(min(max(0, minimizedCount - 1), 3)) * 10
        let x = max(inset, safe.width - inset - cardW - indexOffset)
        let y = max(0, safe.height - inset - cardH)
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

/// Non-interactive AppKit outgoing ghost card mounted at `transition.fromRect` per `transition.generation`.
/// Keeps 1:1 unstretched initial geometry (`10pt` continuous corners, `32pt` header, `7x7pt` dot, `11pt` mono title)
/// at `CATransform3DIdentity` and animates `Identity -> initialLayerTransform(from: toRect, to: fromRect)` + opacity.
final class FloatingPaneGhostNSView: NSView {
    private(set) var transition: FloatingPaneTransition
    private(set) var lastAppliedGeneration: UInt64 = 0

    private let dotView = NSView(frame: .zero)
    private let titleField = NSTextField(labelWithString: "")

    var generation: UInt64 { transition.generation }
    var surfaceId: UUID { transition.surfaceId }
    var cardCornerRadius: CGFloat { layer?.cornerRadius ?? 0 }
    var headerHeightUsed: CGFloat { min(FloatingPaneGeometry.headerHeight, bounds.height) }
    var dotFrame: CGRect { dotView.frame }
    var titleFontSize: CGFloat { titleField.font?.pointSize ?? 0 }
    var dotLayer: CALayer? { dotView.layer }

    override var isFlipped: Bool { true }

    init(transition: FloatingPaneTransition) {
        self.transition = transition
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        setAccessibilityElement(false)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityHidden() -> Bool { true }
    override func accessibilityChildren() -> [Any]? { [] }

    private func setupSubviews() {
        if let root = layer {
            root.cornerCurve = .continuous
            root.cornerRadius = FloatingPaneGeometry.cornerRadius
            root.masksToBounds = true
            root.borderWidth = 1
        }

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3.5
        dotView.setAccessibilityElement(false)
        addSubview(dotView)

        titleField.isBordered = false
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 1
        titleField.setAccessibilityElement(false)
        addSubview(titleField)
    }

    func configure(with transition: FloatingPaneTransition) {
        self.transition = transition
        if let root = layer {
            let bg = transition.backgroundColor.withAlphaComponent(CGFloat(transition.backgroundOpacity))
            root.backgroundColor = bg.cgColor
            root.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
            root.cornerRadius = FloatingPaneGeometry.cornerRadius
        }
        dotView.layer?.backgroundColor = transition.statusColor.cgColor
        titleField.textColor = Tako.LivingTokens.textInactive
        titleField.font = Tako.LivingTokens.monoFont(size: 11, weight: .medium)
        titleField.stringValue = transition.title
        needsLayout = true
        startGhostMorphIfReady()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        startGhostMorphIfReady()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            layer?.removeAnimation(forKey: FloatingCanvasMotion.ghostAnimationKey)
            return
        }
        startGhostMorphIfReady()
    }

    override func layout() {
        super.layout()
        let headerH = min(FloatingPaneGeometry.headerHeight, bounds.height)
        let dotY = max(2, (headerH - 7) * 0.5)
        dotView.frame = CGRect(x: 14, y: dotY, width: 7, height: 7)
        let fittingH = max(14, ceil(titleField.intrinsicContentSize.height))
        let titleY = max(1, (headerH - fittingH) * 0.5)
        titleField.frame = CGRect(x: 28, y: titleY, width: max(0, bounds.width - 42), height: fittingH)
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

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.transform = CATransform3DIdentity
        root.opacity = 0.0
        CATransaction.commit()

        let endTransform = FloatingCanvasMotion.initialLayerTransform(
            from: transition.toRect,
            to: transition.fromRect,
            anchorPoint: root.anchorPoint,
            superviewIsFlipped: FloatingCanvasMotion.effectiveSuperlayerYPointsDown(for: root, fallbackView: self)
        )

        let transformAnim = CABasicAnimation(keyPath: "transform")
        transformAnim.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        transformAnim.toValue = NSValue(caTransform3D: endTransform)

        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = 0.95
        opacityAnim.toValue = 0.0

        let group = CAAnimationGroup()
        group.animations = [transformAnim, opacityAnim]
        group.duration = FloatingCanvasMotion.duration
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
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
