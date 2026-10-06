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
import Metal
import XCTest
@testable import TakoCoreUI

extension MetalTerminalRendererTests {
    // MARK: - Kitty graphics

    func testPlacementGeometryAnchorsTheImageAtTheCellTopLeft() {
        let planner = planner()
        let stored = FfiStoredImage(format: .rgb, width: 24, height: 36, pixels: Data(repeating: 0x7f, count: 24 * 36 * 3))
        let stats = planner.plan(
            frame: frame(
                cols: 8,
                rows: 8,
                placements: [FfiGraphicsPlacement(imageId: 42, placementId: 1, row: 2, col: 3)]
            ),
            viewport: viewport,
            imageProvider: { $0 == 42 ? stored : nil }
        )

        XCTAssertEqual(stats.imageInstances, 1)
        XCTAssertEqual(stats.skippedPlacements, 0)
        let instance = planner.imageInstances[0]
        XCTAssertEqual(instance.destRect, SIMD4<Float>(30, 40, 24, 36))
        XCTAssertEqual(instance.uvRect, SIMD4<Float>(0, 0, 1, 1))
        XCTAssertEqual(instance.tint, SIMD4<Float>(1, 1, 1, 1))
        XCTAssertEqual(instance.imageId, 42)
    }

    func testMetadataProviderPlansImageWithoutFetchingStoredBytes() {
        let planner = planner()
        var byteFetches = 0
        var metadataFetches = 0
        let metadata = FfiGraphicsImageMetadata(format: .rgb, width: 24, height: 36, generation: 7)
        let stats = planner.plan(
            frame: frame(
                cols: 8,
                rows: 8,
                placements: [
                    FfiGraphicsPlacement(imageId: 42, placementId: 1, row: 2, col: 3),
                    FfiGraphicsPlacement(imageId: 42, placementId: 2, row: 4, col: 1),
                ]
            ),
            viewport: viewport,
            imageProvider: { _ in byteFetches += 1; return nil },
            imageMetadataProvider: { _ in metadataFetches += 1; return metadata }
        )

        XCTAssertEqual(stats.imageInstances, 2)
        XCTAssertEqual(byteFetches, 0)
        XCTAssertEqual(metadataFetches, 1, "one metadata lookup serves every placement of an image")
        XCTAssertEqual(planner.imageInstances[0].destRect, SIMD4<Float>(30, 40, 24, 36))
    }

    func testLegacyImageProviderRemainsPlanningFallback() {
        let planner = planner()
        var byteFetches = 0
        let stored = FfiStoredImage(format: .rgb, width: 24, height: 36, pixels: Data(repeating: 0x7f, count: 24 * 36 * 3))
        let stats = planner.plan(
            frame: frame(
                cols: 8,
                rows: 8,
                placements: [FfiGraphicsPlacement(imageId: 42, placementId: 1, row: 2, col: 3)]
            ),
            viewport: viewport,
            imageProvider: { _ in byteFetches += 1; return stored }
        )

        XCTAssertEqual(stats.imageInstances, 1)
        XCTAssertEqual(byteFetches, 1)
    }

    func testMalformedAndOffGridPlacementsAreSkippedSafely() {
        let planner = planner()
        let zeroSized = FfiStoredImage(format: .rgba, width: 0, height: 4, pixels: Data())
        let stats = planner.plan(
            frame: frame(
                cols: 4,
                rows: 4,
                placements: [
                    FfiGraphicsPlacement(imageId: 1, placementId: 1, row: 0, col: 0),   // no image
                    FfiGraphicsPlacement(imageId: 2, placementId: 2, row: 0, col: 0),   // zero-sized
                    FfiGraphicsPlacement(imageId: 3, placementId: 3, row: 99, col: 0),  // off grid
                ]
            ),
            viewport: viewport,
            imageProvider: { $0 == 2 ? zeroSized : nil }
        )

        XCTAssertEqual(stats.imageInstances, 0)
        XCTAssertEqual(stats.skippedPlacements, 3)
        XCTAssertTrue(stats.isRenderable, "bad images do not invalidate the frame")
    }

    // MARK: - Buffers

    func testBufferSizingReusesUntilTheFrameOutgrowsTheBuffer() {
        // Nothing to upload: no allocation.
        XCTAssertNil(TerminalMetalBufferSizing.growth(existingLength: 0, requiredLength: 0))
        // First upload takes the minimum, not the exact size.
        XCTAssertEqual(TerminalMetalBufferSizing.growth(existingLength: 0, requiredLength: 96), 4096)
        // A steady-state frame reuses what it has.
        XCTAssertNil(TerminalMetalBufferSizing.growth(existingLength: 4096, requiredLength: 4096))
        XCTAssertNil(TerminalMetalBufferSizing.growth(existingLength: 8192, requiredLength: 100))
        // Growth doubles rather than tracking each frame's exact size.
        XCTAssertEqual(TerminalMetalBufferSizing.growth(existingLength: 4096, requiredLength: 4097), 8192)
        XCTAssertEqual(TerminalMetalBufferSizing.growth(existingLength: 4096, requiredLength: 20000), 32768)
        // Absurd requests fall back to the exact length instead of overflowing.
        XCTAssertEqual(
            TerminalMetalBufferSizing.growth(existingLength: 0, requiredLength: Int.max),
            Int.max
        )
    }

    func testFramesInFlightIsTripleBuffered() {
        XCTAssertEqual(MetalTerminalRenderer.framesInFlight, 3)
    }

    // MARK: - GPU

    /// Compiles the shipped shader source so the pipelines are built against
    /// the same functions and struct layouts the app ships.
    private func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // .../Tests/TakoCoreUITests
            .deletingLastPathComponent()  // .../Tests
            .deletingLastPathComponent()  // .../swift
            .appendingPathComponent("Sources/TakoCoreUI/Resources/TerminalShaders.metal")
        let source = try String(contentsOf: url, encoding: .utf8)
        return try device.makeLibrary(source: source, options: nil)
    }

    func testRendererBuildsEveryPipelineFromTheShippedShaders() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let renderer = try MetalTerminalRenderer(
            device: device,
            library: try makeLibrary(device: device),
            metrics: metrics()
        )

        XCTAssertEqual(renderer.statistics.totalInstances, 0)
        XCTAssertEqual(renderer.bufferAllocationCount, 0, "buffers are allocated on first use, not up front")
        XCTAssertEqual(renderer.clearColor.alpha, 1, accuracy: 1e-6)
    }

    func testConfigureLayerPublishesTheRenderersOutputColorSpace() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let renderer = try MetalTerminalRenderer(
            device: device,
            library: try makeLibrary(device: device),
            metrics: metrics(),
            colorSpace: .displayP3
        )
        let layer = CAMetalLayer()

        renderer.configure(layer: layer)

        XCTAssertTrue(layer.device === device)
        XCTAssertEqual(layer.pixelFormat, .bgra8Unorm)
        XCTAssertEqual(layer.colorspace?.name, CGColorSpace.displayP3)
    }

    func testAtlasTextureUploadsCopyOnWriteOnlyWhenPageGenerationChanges() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let renderer = try MetalTerminalRenderer(
            device: device,
            library: try makeLibrary(device: device),
            metrics: metrics()
        )
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 10, height: 20, mipmapped: false
        )
        textureDescriptor.usage = .renderTarget
        let target = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor))

        func render(_ scalar: UInt32) {
            var cell = CellSpec()
            cell.ch = scalar
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            _ = renderer.render(
                frame: frame(cols: 1, rows: 1, cells: [cell]),
                viewport: TerminalMetalViewport(drawableWidth: 10, drawableHeight: 20),
                descriptor: pass,
                waitUntilCompleted: true
            )
        }

        render(65)
        XCTAssertEqual(renderer.atlasUploadCount, 1)
        let original = try XCTUnwrap(renderer.atlasTexturesForTesting.first ?? nil)
        render(65)
        XCTAssertEqual(renderer.atlasUploadCount, 1)
        let reused = try XCTUnwrap(renderer.atlasTexturesForTesting.first ?? nil)
        XCTAssertEqual(ObjectIdentifier(original as AnyObject), ObjectIdentifier(reused as AnyObject))
        render(66)
        XCTAssertEqual(renderer.atlasUploadCount, 2)
        let replacement = try XCTUnwrap(renderer.atlasTexturesForTesting.first ?? nil)
        XCTAssertNotEqual(ObjectIdentifier(original as AnyObject), ObjectIdentifier(replacement as AnyObject))
    }

    func testImageMetadataGatesByteFetchesAcrossGenerationsAndRecreation() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        var metadata = FfiGraphicsImageMetadata(format: .rgb, width: 2, height: 2, generation: 1)
        let stored = FfiStoredImage(format: .rgb, width: 2, height: 2, pixels: Data(repeating: 0x40, count: 12))
        var byteFetches = 0
        var metadataFetches = 0
        let renderer = try MetalTerminalRenderer(
            device: device,
            library: try makeLibrary(device: device),
            metrics: metrics(),
            imageProvider: { _ in byteFetches += 1; return stored },
            imageMetadataProvider: { _ in metadataFetches += 1; return metadata }
        )
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 10, height: 20, mipmapped: false
        )
        textureDescriptor.usage = .renderTarget
        let target = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor))
        let placement = FfiGraphicsPlacement(imageId: 7, placementId: 1, row: 0, col: 0)

        func render(_ placements: [FfiGraphicsPlacement]) {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            _ = renderer.render(
                frame: frame(cols: 1, rows: 1, placements: placements),
                viewport: TerminalMetalViewport(drawableWidth: 10, drawableHeight: 20),
                descriptor: pass,
                waitUntilCompleted: true
            )
        }

        render([placement])
        XCTAssertEqual(byteFetches, 1)
        XCTAssertEqual(metadataFetches, 1)
        render([placement])
        XCTAssertEqual(byteFetches, 1, "stable generation must not re-fetch bytes")
        XCTAssertEqual(metadataFetches, 2, "metadata crosses FFI once per live id and frame")

        metadata.generation = 2
        render([placement])
        XCTAssertEqual(byteFetches, 2, "a changed generation must refresh the same id")
        XCTAssertEqual(metadataFetches, 3)

        render([])
        metadata.generation = 3
        render([placement])
        XCTAssertEqual(byteFetches, 3, "a purged id must fetch when recreated")
        XCTAssertEqual(metadataFetches, 4)
    }

    func testOffscreenRenderDrawsCellBackgroundsAndReusesBuffers() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        try XCTSkipUnless(device.hasUnifiedMemory, "readback path needs shared storage")
        let renderer = try MetalTerminalRenderer(
            device: device,
            library: try makeLibrary(device: device),
            metrics: metrics()
        )

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 20,
            height: 40,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

        var cells = Array(repeating: CellSpec(), count: 4)
        cells[0].bg = (0, 0, 255)
        let renderFrame = frame(cols: 2, rows: 2, cells: cells, cursorVisible: true, cursorRow: 1, cursorCol: 1)
        let renderViewport = TerminalMetalViewport(drawableWidth: 20, drawableHeight: 40)

        func renderOnce() -> TerminalMetalFrameStatistics {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = renderer.clearColor
            return renderer.render(
                frame: renderFrame,
                viewport: renderViewport,
                descriptor: pass,
                drawable: nil,
                waitUntilCompleted: true
            )
        }

        let stats = renderOnce()
        XCTAssertTrue(stats.isRenderable)
        XCTAssertEqual(stats.backgroundInstances, 1)
        XCTAssertEqual(stats.cursorInstances, 1)

        var pixel = [UInt8](repeating: 0, count: 4)
        target.getBytes(
            &pixel,
            bytesPerRow: 4,
            from: MTLRegionMake2D(5, 5, 1, 1),
            mipmapLevel: 0
        )
        // BGRA: the top-left cell's blue background, opaque.
        XCTAssertEqual(pixel[0], 255)
        XCTAssertEqual(pixel[1], 0)
        XCTAssertEqual(pixel[2], 0)
        XCTAssertEqual(pixel[3], 255)

        // The cursor cell is the ember cursor color, not the clear color.
        var cursorPixel = [UInt8](repeating: 0, count: 4)
        target.getBytes(
            &cursorPixel,
            bytesPerRow: 4,
            from: MTLRegionMake2D(15, 30, 1, 1),
            mipmapLevel: 0
        )
        XCTAssertEqual(cursorPixel[2], 0xf4)
        XCTAssertEqual(cursorPixel[1], 0x58)
        XCTAssertEqual(cursorPixel[0], 0x1c)

        // Three more frames fill the ring; a fourth must reuse, not allocate.
        for _ in 0..<3 { _ = renderOnce() }
        let allocations = renderer.bufferAllocationCount
        XCTAssertGreaterThan(allocations, 0)
        for _ in 0..<4 { _ = renderOnce() }
        XCTAssertEqual(renderer.bufferAllocationCount, allocations, "instance buffers must be reused")
    }


}
