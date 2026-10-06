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

/// Everything that can go wrong while standing the renderer up. All of it is
/// thrown, never trapped: a host without a GPU, without the shader library or
/// without memory gets an error it can show.
public enum MetalTerminalRendererError: Error, Equatable {
    case defaultLibraryUnavailable
    case commandQueueUnavailable
    case missingShaderFunction(String)
    case pipelineCreationFailed(pass: String, message: String)
    case samplerCreationFailed
    case bufferAllocationFailed(length: Int)
}

/// Draws a terminal frame into a `CAMetalLayer` with Metal.
///
/// The device and the shader library are injected, so the same renderer
/// serves a macOS window, an iOS view, and an offscreen texture in a test.
/// Nothing here imports AppKit or UIKit.
public final class MetalTerminalRenderer {
    /// Backgrounds first, then selection and Kitty images; cursor geometry is
    /// below text/decorations so block cursors retain a legible cell glyph.
    public static let passOrder: [TerminalMetalRenderPass] = TerminalMetalRenderPass.orderedWithImages

    /// Triple buffering: the CPU may be assembling frame N+2's instances
    /// while the GPU still reads frame N's, so each frame in flight gets its
    /// own set of buffers and a semaphore keeps the CPU from lapping it.
    public static let framesInFlight = 3

    public let device: MTLDevice
    public let library: MTLLibrary
    public let planner: TerminalMetalFramePlanner
    public let colorPixelFormat: MTLPixelFormat
    /// Resolves a Kitty image id to the stored image the engine decoded.
    public var imageProvider: (UInt32) -> FfiStoredImage?
    /// Resolves an image's cheap identity and geometry without copying bytes.
    public var imageMetadataProvider: (UInt32) -> FfiGraphicsImageMetadata?

    /// Statistics for the most recently planned frame.
    public internal(set) var statistics = TerminalMetalFrameStatistics()
    /// How many MTLBuffers have been allocated over the renderer's life. It
    /// stops climbing once the buffers are big enough, which is the whole
    /// point of the ring.
    public var bufferAllocationCount: Int {
        backgroundRing.allocations + selectionRing.allocations
            + imageRing.allocations + glyphRing.allocations + colorGlyphRing.allocations
            + decorationRing.allocations + cursorRing.allocations
    }

    let commandQueue: MTLCommandQueue
    let backgroundPipeline: MTLRenderPipelineState
    let selectionPipeline: MTLRenderPipelineState
    let imagePipeline: MTLRenderPipelineState
    let glyphPipeline: MTLRenderPipelineState
    let colorGlyphPipeline: MTLRenderPipelineState
    let decorationPipeline: MTLRenderPipelineState
    let cursorPipeline: MTLRenderPipelineState
    let quadIndexBuffer: MTLBuffer
    let glyphSampler: MTLSamplerState
    let imageSampler: MTLSamplerState

    let backgroundRing: InstanceRing
    let selectionRing: InstanceRing
    let imageRing: InstanceRing
    let glyphRing: InstanceRing
    let colorGlyphRing: InstanceRing
    let decorationRing: InstanceRing
    let cursorRing: InstanceRing

    let inFlight = DispatchSemaphore(value: MetalTerminalRenderer.framesInFlight)
    var slot = 0

    let imageCache: MetalImageCache
    var atlasTextures: [MTLTexture?] = []
    var atlasTextureGenerations: [UInt64] = []
    public internal(set) var atlasUploadCount: Int = 0
    var resolvedImageTextures: [UInt32: MTLTexture] = [:]
    var resolvedImageMetadata: [UInt32: FfiGraphicsImageMetadata] = [:]
    var frameImageMetadata: [UInt32: FfiGraphicsImageMetadata] = [:]
    var frameImageIdsWithoutMetadata = Set<UInt32>()

    var atlasTexturesForTesting: [MTLTexture?] { atlasTextures }
    var nextDrawableProvider: (CAMetalLayer) -> CAMetalDrawable? = { $0.nextDrawable() }
    var committedFrameCaptureForTesting: ((FfiRenderFrame, [UInt8]) -> Void)?

    public internal(set) var customShaders: [TerminalCustomShader] = []
    public internal(set) var customShaderErrors: [String] = []
    var customShaderClock: () -> CFTimeInterval = { CACurrentMediaTime() }
    private(set) var customShaderUniforms = TerminalCustomShaderUniforms()
    var customShaderStartTime: CFTimeInterval = 0
    var customShaderLastFrameTime: CFTimeInterval?
    var customShaderTargets: [MTLTexture] = []

    static let quadIndices: [UInt16] = [0, 1, 2, 0, 2, 3]

    let presentationClock: TerminalPresentationClock

    public var presentationCadence: TerminalPresentationCadence {
        presentationClock.cadence
    }

    public init(
        device: MTLDevice,
        library: MTLLibrary,
        metrics: TerminalMetalCellMetrics,
        palette: TerminalMetalPalette? = nil,
        colorEncoding: TerminalMetalColorEncoding = .displayEncoded,
        colorSpace: TerminalMetalColorSpace = .sRGB,
        minimumContrast: Float = 1,
        colorPixelFormat: MTLPixelFormat = .bgra8Unorm,
        atlas: GlyphAtlas = GlyphAtlas(),
        presentationClock: TerminalPresentationClock = TerminalPresentationClock(),
        imageProvider: @escaping (UInt32) -> FfiStoredImage? = { _ in nil },
        imageMetadataProvider: @escaping (UInt32) -> FfiGraphicsImageMetadata? = { _ in nil }
    ) throws {
        self.presentationClock = presentationClock
        self.device = device
        self.library = library
        self.colorPixelFormat = colorPixelFormat
        self.imageProvider = imageProvider
        self.imageMetadataProvider = imageMetadataProvider
        self.planner = TerminalMetalFramePlanner(
            metrics: metrics,
            atlas: atlas,
            palette: palette,
            colorEncoding: colorEncoding,
            colorSpace: colorSpace,
            minimumContrast: minimumContrast
        )
        self.imageCache = MetalImageCache(device: device)

        guard let queue = device.makeCommandQueue() else {
            throw MetalTerminalRendererError.commandQueueUnavailable
        }
        queue.label = "TakoCoreUI.MetalTerminalRenderer"
        self.commandQueue = queue

        self.backgroundPipeline = try Self.makePipeline(
            device: device,
            library: library,
            pass: "background",
            vertex: "terminalBackgroundVertex",
            fragment: "terminalBackgroundFragment",
            pixelFormat: colorPixelFormat
        )
        self.selectionPipeline = try Self.makePipeline(
            device: device,
            library: library,
            pass: "selection",
            vertex: "terminalSelectionVertex",
            fragment: "terminalSelectionFragment",
            pixelFormat: colorPixelFormat
        )
        self.imagePipeline = try Self.makePipeline(
            device: device,
            library: library,
            pass: "kittyImage",
            vertex: "terminalImageVertex",
            fragment: "terminalImageFragment",
            pixelFormat: colorPixelFormat
        )
        self.glyphPipeline = try Self.makePipeline(
            device: device,
            library: library,
            pass: "grayscaleGlyph",
            vertex: "terminalGrayscaleGlyphVertex",
            fragment: "terminalGrayscaleGlyphFragment",
            pixelFormat: colorPixelFormat
        )
        self.colorGlyphPipeline = try Self.makePipeline(
            device: device,
            library: library,
            pass: "colorGlyph",
            vertex: "terminalGrayscaleGlyphVertex",
            fragment: "terminalColorGlyphFragment",
            pixelFormat: colorPixelFormat
        )
        self.decorationPipeline = try Self.makePipeline(
            device: device,
            library: library,
            pass: "decoration",
            vertex: "terminalDecorationVertex",
            fragment: "terminalDecorationFragment",
            pixelFormat: colorPixelFormat
        )
        self.cursorPipeline = try Self.makePipeline(
            device: device,
            library: library,
            pass: "cursor",
            vertex: "terminalCursorVertex",
            fragment: "terminalCursorFragment",
            pixelFormat: colorPixelFormat
        )

        let indexLength = MemoryLayout<UInt16>.stride * Self.quadIndices.count
        guard let indexBuffer = device.makeBuffer(
            bytes: Self.quadIndices,
            length: indexLength,
            options: .storageModeShared
        ) else {
            throw MetalTerminalRendererError.bufferAllocationFailed(length: indexLength)
        }
        indexBuffer.label = "TerminalQuadIndices"
        self.quadIndexBuffer = indexBuffer

        self.glyphSampler = try Self.makeSampler(device: device, filter: .nearest)
        self.imageSampler = try Self.makeSampler(device: device, filter: .linear)

        self.backgroundRing = InstanceRing(device: device, label: "TerminalBackground")
        self.selectionRing = InstanceRing(device: device, label: "TerminalSelection")
        self.imageRing = InstanceRing(device: device, label: "TerminalImage")
        self.glyphRing = InstanceRing(device: device, label: "TerminalGlyph")
        self.colorGlyphRing = InstanceRing(device: device, label: "TerminalColorGlyph")
        self.decorationRing = InstanceRing(device: device, label: "TerminalDecoration")
        self.cursorRing = InstanceRing(device: device, label: "TerminalCursor")
    }

    public convenience init(
        device: MTLDevice,
        metrics: TerminalMetalCellMetrics,
        bundle: Bundle? = nil,
        palette: TerminalMetalPalette? = nil,
        colorEncoding: TerminalMetalColorEncoding = .displayEncoded,
        colorSpace: TerminalMetalColorSpace = .sRGB,
        minimumContrast: Float = 1,
        colorPixelFormat: MTLPixelFormat = .bgra8Unorm,
        atlas: GlyphAtlas = GlyphAtlas(),
        imageProvider: @escaping (UInt32) -> FfiStoredImage? = { _ in nil },
        imageMetadataProvider: @escaping (UInt32) -> FfiGraphicsImageMetadata? = { _ in nil }
    ) throws {
        guard let library = Self.defaultLibrary(device: device, bundle: bundle) else {
            throw MetalTerminalRendererError.defaultLibraryUnavailable
        }
        try self.init(
            device: device,
            library: library,
            metrics: metrics,
            palette: palette,
            colorEncoding: colorEncoding,
            colorSpace: colorSpace,
            minimumContrast: minimumContrast,
            colorPixelFormat: colorPixelFormat,
            atlas: atlas,
            imageProvider: imageProvider,
            imageMetadataProvider: imageMetadataProvider
        )
    }

    public static func defaultLibrary(device: MTLDevice, bundle: Bundle? = nil) -> MTLLibrary? {
        if let bundle, let library = try? device.makeDefaultLibrary(bundle: bundle),
           library.functionNames.contains(requiredFunction) {
            return library
        }
        if let library = device.makeDefaultLibrary(),
           library.functionNames.contains(requiredFunction) {
            return library
        }
        if let bundle {
            return compiledFromShippedSource(device: device, bundle: bundle)
        }
        return nil
    }

    private static let requiredFunction = "terminalGrayscaleGlyphVertex"

    private static func compiledFromShippedSource(device: MTLDevice, bundle: Bundle) -> MTLLibrary? {
        guard let url = bundle.url(forResource: "TerminalShaders", withExtension: "metal"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return try? device.makeLibrary(source: source, options: nil)
    }

    public func configure(layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = colorPixelFormat
        switch planner.colorSpace {
        case .sRGB:
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        case .displayP3:
            layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        }
        layer.framebufferOnly = true
        layer.isOpaque = true
    }

    @discardableResult
    public func plan(
        frame: FfiRenderFrame,
        viewport: TerminalMetalViewport,
        overscanRows: Int = 0
    ) -> TerminalMetalFrameStatistics {
        frameImageMetadata.removeAll(keepingCapacity: true)
        frameImageIdsWithoutMetadata.removeAll(keepingCapacity: true)
        statistics = planner.plan(
            frame: frame,
            viewport: viewport,
            overscanRows: overscanRows,
            imageProvider: imageProvider,
            imageMetadataProvider: { [weak self] imageId in
                guard let self else { return nil }
                if let cached = self.frameImageMetadata[imageId] { return cached }
                if self.frameImageIdsWithoutMetadata.contains(imageId) {
                    return self.resolvedImageMetadata[imageId]
                }
                if let metadata = self.imageMetadataProvider(imageId) {
                    self.frameImageMetadata[imageId] = metadata
                    return metadata
                }
                self.frameImageIdsWithoutMetadata.insert(imageId)
                return self.resolvedImageMetadata[imageId]
            }
        )
        return statistics
    }

    public var clearColor: MTLClearColor {
        let color = TerminalMetalColor.premultiplied(planner.palette.background)
        return MTLClearColor(
            red: Double(color.x),
            green: Double(color.y),
            blue: Double(color.z),
            alpha: Double(color.w)
        )
    }

    public func invalidateImages(imageIds: Set<UInt32>? = nil) {
        guard let imageIds else {
            resolvedImageTextures.removeAll(keepingCapacity: true)
            resolvedImageMetadata.removeAll(keepingCapacity: true)
            return
        }
        for imageId in imageIds {
            resolvedImageTextures.removeValue(forKey: imageId)
            resolvedImageMetadata.removeValue(forKey: imageId)
        }
    }
}
