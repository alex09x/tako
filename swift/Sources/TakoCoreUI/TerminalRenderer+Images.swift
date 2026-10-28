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

extension TerminalRenderer {
    /// Draw Kitty Graphics placements over the grid.
    public func drawImages(
        _ placements: [FfiGraphicsPlacement],
        rows: Int,
        imageProvider: (UInt32) -> FfiStoredImage?,
        pixelsPerUnit: CGFloat = 1,
        in context: CGContext
    ) {
        for placement in placements {
            guard let stored = imageProvider(placement.imageId),
                  let image = Self.makeImage(stored),
                  let layout = TerminalImageLayout.resolve(placement,
                      image: CGSize(width: Int(stored.width), height: Int(stored.height)),
                      cell: CGSize(width: metrics.cellWidth, height: metrics.cellHeight), pixelsPerUnit: pixelsPerUnit),
                  let cropped = image.cropping(to: layout.source) else { continue }
            let dest = layout.destination
            let rect = CGRect(x: dest.minX, y: CGFloat(rows) * metrics.cellHeight - dest.maxY,
                              width: dest.width, height: dest.height)
            context.draw(cropped, in: rect)
        }
    }

    private static func makeImage(_ stored: FfiStoredImage) -> CGImage? {
        switch stored.format {
        case .png:
            guard let provider = CGDataProvider(data: Data(stored.pixels) as CFData) else {
                return nil
            }
            return CGImage(
                pngDataProviderSource: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        case .rgb, .rgba:
            let components = stored.format == .rgba ? 4 : 3
            let width = Int(stored.width)
            let height = Int(stored.height)
            guard width > 0, height > 0,
                  stored.pixels.count >= width * height * components,
                  let provider = CGDataProvider(data: Data(stored.pixels) as CFData) else {
                return nil
            }
            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8 * components,
                bytesPerRow: width * components,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: stored.format == .rgba
                    ? CGImageAlphaInfo.last.rawValue
                    : CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }
    }
}
