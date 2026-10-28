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

/// Kitty's source rectangle and aspect-preserving destination, both with a
/// top-left origin. The two renderers use the same geometry.
struct TerminalImageLayout {
    let destination: CGRect
    let source: CGRect

    static func resolve(_ placement: FfiGraphicsPlacement, image: CGSize, cell: CGSize,
                        pixelsPerUnit: CGFloat = 1) -> TerminalImageLayout? {
        guard image.width > 0, image.height > 0, cell.width > 0, cell.height > 0, pixelsPerUnit > 0 else { return nil }
        let sourceX = CGFloat(placement.sourceX), sourceY = CGFloat(placement.sourceY)
        guard sourceX < image.width, sourceY < image.height else { return nil }
        let availableW = image.width - sourceX, availableH = image.height - sourceY
        let width = placement.sourceWidth == 0 ? availableW : min(availableW, CGFloat(placement.sourceWidth))
        let height = placement.sourceHeight == 0 ? availableH : min(availableH, CGFloat(placement.sourceHeight))
        guard width > 0, height > 0 else { return nil }
        var source = CGRect(x: sourceX, y: sourceY, width: width, height: height)
        let columns = CGFloat(placement.columns), rows = CGFloat(placement.rows)
        var drawWidth = width / pixelsPerUnit, drawHeight = height / pixelsPerUnit
        var insetX: CGFloat = 0, insetY: CGFloat = 0
        if columns > 0 && rows > 0 {
            let boxWidth = columns * cell.width, boxHeight = rows * cell.height
            let scale = min(boxWidth / width, boxHeight / height)
            drawWidth = width * scale
            drawHeight = height * scale
            insetX = (boxWidth - drawWidth) / 2
            insetY = (boxHeight - drawHeight) / 2
        } else if columns > 0 {
            drawWidth = columns * cell.width
            drawHeight = drawWidth * height / width
        } else if rows > 0 {
            drawHeight = rows * cell.height
            drawWidth = drawHeight * width / height
        }
        let originY = (CGFloat(placement.row) + CGFloat(placement.rowOffset)) * cell.height
        var destination = CGRect(x: CGFloat(placement.col) * cell.width + CGFloat(placement.offsetX) / pixelsPerUnit + insetX,
                                 y: originY + CGFloat(placement.offsetY) / pixelsPerUnit + insetY,
                                 width: drawWidth, height: drawHeight)
        if placement.clipTopRows > 0 || placement.clipBottomRows > 0 {
            let span = rows > 0 ? rows : ceil(max(0, destination.maxY - originY) / cell.height)
            let top = max(destination.minY, originY + CGFloat(placement.clipTopRows) * cell.height)
            let bottom = min(destination.maxY, originY + max(0, span - CGFloat(placement.clipBottomRows)) * cell.height)
            guard bottom > top, destination.height > 0 else { return nil }
            let startFraction = (top - destination.minY) / destination.height
            let endFraction = (bottom - destination.minY) / destination.height
            source.origin.y += source.height * startFraction
            source.size.height *= endFraction - startFraction
            destination.origin.y = top
            destination.size.height = bottom - top
        }
        return TerminalImageLayout(destination: destination, source: source)
    }
}
