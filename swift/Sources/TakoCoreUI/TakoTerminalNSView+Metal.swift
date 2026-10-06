/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Metal
import QuartzCore

extension TakoTerminalNSView {
    /// One coherent read of what this surface has actually put on screen:
    /// sequence, presented time and interval, all from the same frame.
    public var presentationCadence: TerminalPresentationCadence { presentationClock.cadence }

    /// The renderer currently drawing this surface, so a test can prove the
    /// two share one clock rather than each keeping a private count.
    var metalRendererForTesting: MetalTerminalRenderer? { metalRenderer }

    // MARK: - Metal renderer lifecycle

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
        scheduleRedraw()
    }

    func makeMetalRenderer(scale: CGFloat) -> String? {
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
        if let viewLayer = layer {
            viewLayer.insertSublayer(metal, at: 0)
        }

        metalRenderer = created
        metalLayer = metal
        applyMetalLayerGeometry()
        return nil
    }

    func releaseMetalResources() {
        metalLayer?.removeFromSuperlayer()
        metalLayer = nil
        metalRenderer = nil
        lastFrameStatistics = nil
    }

    static func drawableSize(for size: CGSize, scale: CGFloat) -> CGSize {
        let scale = max(scale, 1)
        return CGSize(
            width: max((size.width * scale).rounded(.down), 1),
            height: max((size.height * scale).rounded(.down), 1)
        )
    }

    var effectiveContentScale: CGFloat {
        max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, 1)
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
        scheduleRedraw()
    }

    final class DisplayLinkProxy: NSObject {
        weak var owner: TakoTerminalNSView?

        @objc func tick() {
            MainActor.assumeIsolated { owner?.displayLinkFired() }
        }
    }
}
#endif
