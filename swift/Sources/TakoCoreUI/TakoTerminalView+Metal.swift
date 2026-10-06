/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import CoreGraphics
import Foundation
import Metal
import QuartzCore
import simd

#if canImport(UIKit)
import UIKit

extension TakoTerminalView {
    func rebuildMetalRenderer() {
        releaseMetalResources()
        rendererBuildCount += 1
        metalContentScale = effectiveContentScale

        if let failure = makeMetalRenderer(scale: metalContentScale) {
            metalUnavailableReason = failure
            stopDisplayLink()
            return
        }
        metalUnavailableReason = nil
        startDisplayLink()
        setNeedsDisplay()
    }

    private func makeMetalRenderer(scale: CGFloat) -> String? {
        guard !Self.isMetalDisabledForTesting else { return "Metal disabled for testing" }
        guard let device = MTLCreateSystemDefaultDevice() else { return "no Metal device" }
        let resolvedLibrary = Self.metalLibraryProviderForTesting?(device)
            ?? MetalTerminalRenderer.defaultLibrary(device: device, bundle: Self.metalLibraryBundle)
        guard let library = resolvedLibrary else {
            return String(describing: MetalTerminalRendererError.defaultLibraryUnavailable)
        }

        let created: MetalTerminalRenderer
        do {
            created = try MetalTerminalRenderer(
                device: device,
                library: library,
                metrics: TerminalMetalCellMetrics(renderer.metrics, scale: scale),
                palette: Self.metalPalette(for: theme),
                colorSpace: theme.windowColorSpace == .displayP3 ? .displayP3 : .sRGB,
                presentationClock: presentationClock
            )
        } catch {
            return String(describing: error)
        }
        created.planner.cursorThickness = theme.cursorThickness
        created.planner.cellColorsAreDisplayP3 = theme.windowColorSpace == .displayP3

        let engine = core
        created.imageProvider = { [weak engine] imageId in
            engine?.graphicsImage(imageId: imageId)
        }
        created.imageMetadataProvider = { [weak engine] imageId in
            engine?.graphicsImageMetadata(imageId: imageId)
        }
        if !theme.customShaders.isEmpty {
            for error in created.loadCustomShaders(paths: theme.customShaders) {
                TakoLog.render.error(error)
            }
        }

        let metal = CAMetalLayer()
        created.configure(layer: metal)
        metal.isOpaque = theme.backgroundOpacity >= 1
        layer.insertSublayer(metal, at: 0)

        metalRenderer = created
        metalLayer = metal
        applyMetalLayerGeometry()
        return nil
    }

    private func releaseMetalResources() {
        metalLayer?.removeFromSuperlayer()
        metalLayer = nil
        metalRenderer = nil
        lastFrameStatistics = nil
    }

    public static func drawableSize(for size: CGSize, scale: CGFloat) -> CGSize {
        let scale = max(scale, 1)
        return CGSize(
            width: max((size.width * scale).rounded(.down), 1),
            height: max((size.height * scale).rounded(.down), 1)
        )
    }

    var effectiveContentScale: CGFloat {
        max(window?.screen.scale ?? contentScaleFactor, 1)
    }

    func applyMetalLayerGeometry() {
        guard let metal = metalLayer else { return }
        let size = Self.drawableSize(for: bounds.size, scale: metalContentScale)
        guard metal.frame != bounds
                || metal.contentsScale != metalContentScale
                || metal.drawableSize != size else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metal.frame = bounds
        metal.contentsScale = metalContentScale
        metal.drawableSize = size
        CATransaction.commit()
        setNeedsDisplay()
    }

    func startDisplayLink() {
        guard displayLink == nil else { return }
        let proxy = DisplayLinkProxy()
        proxy.owner = self
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func scheduleRedraw() {
        redrawPending = true
        displayLink?.isPaused = false
    }

    func armPresentationRetry() {
        presentationRetryPending = true
        if window != nil { displayLink?.isPaused = false }
    }

    func displayLinkFired() {
        guard redrawPending || presentationRetryPending else {
            displayLink?.isPaused = true
            return
        }
        redrawNow()
    }

    public func redrawNow() {
        let wasRedrawPending = redrawPending
        redrawPending = false
        guard let metalRenderer, let metalLayer else { return clearPresentationRetry() }
        guard bounds.width >= 1, bounds.height >= 1 else { return clearPresentationRetry() }
        guard !core.isSynchronizedOutputActive() else {
            if wasRedrawPending || presentationRetryPending {
                redrawHeldBySynchronizedOutput = true
            }
            displayLink?.isPaused = true
            return
        }
        metalRenderer.planner.isFocused = isFirstResponder
        metalRenderer.planner.cursorBlinkPhaseOn = theme.cursorBlink ? blinkStateVisible : true
        let scale = Float(metalLayer.contentsScale)
        metalRenderer.planner.margins = TerminalMetalMargins(
            right: Float(max(0, bounds.width - CGFloat(cols) * renderer.metrics.cellWidth)) * scale,
            bottom: Float(max(0, bounds.height - CGFloat(rows) * renderer.metrics.cellHeight)) * scale,
            fill: TakoTerminalView.marginFill(theme.windowPaddingColor)
        )
        let stats = metalRenderer.render(frame: currentRenderFrame(), in: metalLayer)
        lastFrameStatistics = stats
        if stats.presentation.leavesStalePixels {
            unpresentedFrameCount += 1
            TakoLog.render.debug("frame not presented (\(String(describing: stats.presentation))) → retry")
            armPresentationRetry()
        } else {
            clearPresentationRetry()
        }
        if customShaderKeepsAnimating {
            scheduleRedraw()
        }
    }

    var customShaderKeepsAnimating: Bool {
        guard metalRenderer?.customShaders.isEmpty == false else { return false }
        return theme.customShaderAnimation.keepsAnimating(isFocused: isFirstResponder)
    }

    private func clearPresentationRetry() {
        unpresentedFrameCount = 0
        presentationRetryPending = false
    }

    func currentRenderFrame() -> FfiRenderFrame {
        frameFetchCount += 1
        return core.renderFrame()
    }

    final class DisplayLinkProxy: NSObject {
        weak var owner: TakoTerminalView?

        @objc func tick() {
            MainActor.assumeIsolated { owner?.displayLinkFired() }
        }
    }

    public static func metalPalette(
        for theme: TerminalTheme,
        encoding: TerminalMetalColorEncoding = .displayEncoded
    ) -> TerminalMetalPalette {
        TerminalMetalPalette(
            background: metalColor(theme.background, alpha: Float(theme.backgroundOpacity), encoding: encoding),
            foreground: metalColor(theme.foreground, encoding: encoding),
            selection: metalColor(theme.selectionBackground, encoding: encoding),
            cursor: metalColor(theme.cursorColor, alpha: Float(theme.cursorOpacity), encoding: encoding),
            selectionForeground: theme.selectionForeground.map { metalColor($0, encoding: encoding) },
            selectionInvertsColors: theme.selectionInvertFgBg
        )
    }

    public static func marginFill(_ color: TerminalTheme.WindowPaddingColor) -> TerminalMetalMargins.Fill {
        switch color {
        case .background: return .background
        case .extend: return .extend
        case .extendAlways: return .extendAlways
        }
    }

    public static func metalColor(
        _ color: CGColor,
        alpha: Float? = nil,
        encoding: TerminalMetalColorEncoding = .displayEncoded
    ) -> SIMD4<Float> {
        let converted = color.converted(to: srgbSpace, intent: .defaultIntent, options: nil) ?? color
        let parts = converted.components ?? []
        func byte(_ value: CGFloat) -> UInt8 {
            UInt8(clamping: Int((min(max(value, 0), 1) * 255).rounded()))
        }
        switch parts.count {
        case 0:
            return TerminalMetalColor.rgba(r: 0, g: 0, b: 0, alpha: alpha ?? 1, encoding: encoding)
        case 1, 2:
            let gray = byte(parts[0])
            let opacity = alpha ?? Float(parts.count == 2 ? parts[1] : 1)
            return TerminalMetalColor.rgba(r: gray, g: gray, b: gray, alpha: opacity, encoding: encoding)
        default:
            return TerminalMetalColor.rgba(
                r: byte(parts[0]),
                g: byte(parts[1]),
                b: byte(parts[2]),
                alpha: alpha ?? Float(parts.count >= 4 ? parts[3] : 1),
                encoding: encoding
            )
        }
    }
}
#endif
