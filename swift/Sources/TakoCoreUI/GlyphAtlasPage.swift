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

/// A single packed texture page. Grayscale and color pixels never share a page.
public final class GlyphAtlasPage: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let pixelFormat: GlyphAtlasPixelFormat
    public private(set) var generation: UInt64 = 0
    public var bytesPerRow: Int { width * pixelFormat.bytesPerPixel }
    /// Tightly packed pixel data in `pixelFormat`.
    public private(set) var data: Data

    private var currentX: Int
    private var currentY: Int
    private var currentShelfHeight: Int
    private let padding: Int

    public init(
        width: Int = 1024,
        height: Int = 1024,
        padding: Int = 1,
        pixelFormat: GlyphAtlasPixelFormat = .grayscale8
    ) {
        self.width = width
        self.height = height
        self.padding = padding
        self.pixelFormat = pixelFormat
        self.data = Data(repeating: 0, count: width * height * pixelFormat.bytesPerPixel)
        self.currentX = padding
        self.currentY = padding
        self.currentShelfHeight = 0
    }

    /// Attempts to allocate space for a mask of size `(maskWidth, maskHeight)` and copies `maskData` into the page buffer.
    /// Returns the pixel rectangle inside the page if successful, or `nil` if the page is full.
    public func pack(maskWidth: Int, maskHeight: Int, maskData: Data) -> CGRect? {
        guard maskWidth > 0, maskHeight > 0 else { return nil }
        let sourceBytesPerRow = maskWidth * pixelFormat.bytesPerPixel
        guard maskData.count >= sourceBytesPerRow * maskHeight else { return nil }

        if currentX + maskWidth + padding > width {
            currentX = padding
            currentY += currentShelfHeight + padding
            currentShelfHeight = 0
        }

        if currentY + maskHeight + padding > height {
            return nil
        }

        let allocX = currentX
        let allocY = currentY

        data.withUnsafeMutableBytes { (pageRawBuffer: UnsafeMutableRawBufferPointer) in
            guard let pagePtr = pageRawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            maskData.withUnsafeBytes { (maskRawBuffer: UnsafeRawBufferPointer) in
                guard let maskPtr = maskRawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for row in 0..<maskHeight {
                    let pageOffset = (allocY + row) * bytesPerRow + allocX * pixelFormat.bytesPerPixel
                    let maskOffset = row * sourceBytesPerRow
                    UnsafeMutableRawPointer(pagePtr + pageOffset).copyMemory(
                        from: maskPtr + maskOffset,
                        byteCount: sourceBytesPerRow
                    )
                }
            }
        }

        currentX += maskWidth + padding
        currentShelfHeight = max(currentShelfHeight, maskHeight)
        generation &+= 1

        return CGRect(x: CGFloat(allocX), y: CGFloat(allocY), width: CGFloat(maskWidth), height: CGFloat(maskHeight))
    }
}
