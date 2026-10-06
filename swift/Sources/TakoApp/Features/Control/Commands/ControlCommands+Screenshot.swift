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
import AppKit

extension ControlCommands {
    /// `takoctl screenshot`: capture rendered terminal pane screenshot as PNG (D2).
    static func screenshotCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let surface = try target(request, all)
        recordActivity(for: request, on: surface.id, action: "screenshot")
        guard !SecureInput.shared.isSecure(for: surface) && !surface.isSecureInput else {
            throw ControlError(.disabled, "secure-input panes cannot be read")
        }
        let (pngData, width, height) = try captureScreenshot(surface)
        let id = surface.id.uuidString.lowercased()
        return [
            "id": .string(id),
            "width": .number(Double(width)),
            "height": .number(Double(height)),
            "format": .string("png"),
            "data": .string(pngData.base64EncodedString()),
        ]
    }

    static func captureScreenshot(_ surface: Tako.SurfaceView) throws -> (data: Data, width: Int, height: Int) {
        let cols = max(1, Int(surface.core.cols()))
        let rows = max(1, Int(surface.core.rows()))
        let renderer = surface.renderer
        let size = renderer.pixelSize(cols: cols, rows: rows)
        let imgWidth = max(1, Int(size.width))
        let imgHeight = max(1, Int(size.height))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: imgWidth,
                  height: imgHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ControlError(.internalError, "failed to create bitmap context for screenshot")
        }

        let snapshot = surface.core.snapshot()
        let cursorRow = Int(snapshot.cursorRow)
        let cursorCol = Int(snapshot.cursorCol)
        let cursorVisible = snapshot.cursorVisible
        let cursorStyle = snapshot.cursorStyle

        var cachedRows: [[TerminalCell]] = []
        var graphemes: [FfiGrapheme] = []
        for r in 0..<rows {
            let ffiCells = surface.core.viewportRow(row: UInt32(r))
            var termCells: [TerminalCell] = []
            for (c, cell) in ffiCells.enumerated() {
                termCells.append(TerminalCell(cell))
                if let g = cell.grapheme, !g.isEmpty {
                    graphemes.append(FfiGrapheme(row: UInt32(r), col: UInt32(c), text: g))
                }
            }
            cachedRows.append(termCells)
        }

        renderer.draw(
            in: context,
            cols: cols,
            rows: rows,
            rowProvider: { row in
                guard row >= 0 && row < cachedRows.count else { return [] }
                return cachedRows[row]
            },
            graphemes: graphemes,
            cursorRow: cursorRow,
            cursorCol: cursorCol,
            cursorVisible: cursorVisible,
            cursorStyle: cursorStyle,
            selection: nil,
            skipBackgrounds: false
        )

        guard let cgImage = context.makeImage() else {
            throw ControlError(.internalError, "failed to create cgImage from bitmap context")
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw ControlError(.internalError, "failed to encode screenshot as PNG")
        }
        return (pngData, imgWidth, imgHeight)
    }
}
