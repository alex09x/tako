import Metal
import XCTest
@testable import TakoCoreUI

/// What sub-cell scrolling actually looks like, in pixels.
///
/// The accumulator tests prove the arithmetic and the core tests prove the
/// extra row is the right one. This proves the two meet: that a fractional
/// offset moves the whole grid by exactly that many pixels, and that the
/// strip it opens at the bottom is filled with the next line rather than
/// left blank or filled with a repeat of the last visible one.
final class MetalSubCellTranslationPixelTests: XCTestCase {
    private static let cellWidth = 8
    private static let cellHeight = 16
    private static let cols = 4
    private static let rows = 4

    /// A distinct, flat background per row, so a row's identity is readable
    /// from any single pixel in it.
    private static let rowColors: [(UInt8, UInt8, UInt8)] = [
        (200, 0, 0), (0, 200, 0), (0, 0, 200), (200, 200, 0),
        // The overscan row: the line below the viewport.
        (0, 200, 200),
    ]

    private func device() throws -> MTLDevice {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        try XCTSkipUnless(device.hasUnifiedMemory, "reading a texture back needs shared storage")
        return device
    }

    private func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakoCoreUI/Resources/TerminalShaders.metal")
        return try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
    }

    /// One packed cell: a space on the given background, in the wire layout
    /// `TerminalCell` reads -- char, fg and bg as three bytes each, then the
    /// attribute bits, underline style and underline colour.
    private func packedCell(
        bg: (UInt8, UInt8, UInt8),
        char: UInt32 = 32,
        fg: (UInt8, UInt8, UInt8) = (255, 255, 255)
    ) -> [UInt8] {
        var bytes: [UInt8] = [
            UInt8(truncatingIfNeeded: char),
            UInt8(truncatingIfNeeded: char >> 8),
            UInt8(truncatingIfNeeded: char >> 16),
            UInt8(truncatingIfNeeded: char >> 24),
        ]
        bytes.append(contentsOf: [fg.0, fg.1, fg.2])
        bytes.append(contentsOf: [bg.0, bg.1, bg.2])
        bytes.append(contentsOf: [0, 0])
        bytes.append(0)
        bytes.append(contentsOf: [255, 255, 255])
        precondition(bytes.count == TerminalCell.byteSize)
        return bytes
    }

    /// `rowCount` rows of flat colour, in the packed wire layout.
    private func packedRows(_ rowCount: Int) -> Data {
        var bytes = [UInt8]()
        for row in 0..<rowCount {
            for _ in 0..<Self.cols {
                bytes.append(contentsOf: packedCell(bg: Self.rowColors[row]))
            }
        }
        return Data(bytes)
    }

    /// The same rows, but with a glyph in every cell.
    ///
    /// Flat backgrounds alone cannot tell a translated frame from one whose
    /// backgrounds merely moved, so anything claiming to prove that the whole
    /// frame moves has to put real ink on the screen first.
    private func packedInkedRows(_ rowCount: Int) -> Data {
        var bytes = [UInt8]()
        for row in 0..<rowCount {
            for col in 0..<Self.cols {
                // Distinct characters, so a row cannot pass by being confused
                // with its neighbour.
                let char = UInt32(65 + (row * Self.cols + col) % 26)
                bytes.append(contentsOf: packedCell(
                    bg: Self.rowColors[row],
                    char: char,
                    fg: (255, 255, 255)))
            }
        }
        return Data(bytes)
    }

    private func frame(
        rowsPacked: Int,
        inked: Bool = false,
        cursorVisible: Bool = false,
        selection: FfiSelectionRange? = nil
    ) -> FfiRenderFrame {
        FfiRenderFrame(
            snapshot: FfiSnapshot(
                cols: UInt32(Self.cols),
                rows: UInt32(Self.rows),
                cursorRow: 1,
                cursorCol: 1,
                cursorVisible: cursorVisible,
                cursorStyle: FfiCursorStyle(shape: .block, blinking: false),
                title: "translation",
                modes: FfiTerminalModes(
                    autowrap: true,
                    originMode: false,
                    cursorKeyAppMode: false,
                    mouseTracking: .off,
                    mouseUtf8: false,
                    mouseSgr: false,
                    focusEvents: false,
                    bracketedPaste: false
                ),
                viewportOffset: 1,
                scrollbackLen: 32,
                damagedRows: Array(0..<UInt32(Self.rows)),
                selection: selection,
                graphicsPlacements: []
            ),
            packedCells: inked ? packedInkedRows(rowsPacked) : packedRows(rowsPacked),
            epoch: 0
        )
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]
        /// (r, g, b) at a pixel; the texture is BGRA.
        func at(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            let i = (y * width + x) * 4
            return (bytes[i + 2], bytes[i + 1], bytes[i])
        }
    }

    private func render(
        _ frame: FfiRenderFrame,
        device: MTLDevice,
        verticalPixelOffset: Float,
        overscanRows: Int
    ) throws -> Pixels {
        let renderer = try MetalTerminalRenderer(
            device: device,
            library: try makeLibrary(device: device),
            metrics: TerminalMetalCellMetrics(
                font: CTFontCreateWithName("Menlo" as CFString, 12, nil),
                cellWidth: CGFloat(Self.cellWidth),
                cellHeight: CGFloat(Self.cellHeight),
                ascent: 15,
                scale: 1
            )
        )
        let width = Self.cols * Self.cellWidth
        let height = Self.rows * Self.cellHeight

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = renderer.clearColor

        let stats = renderer.render(
            frame: frame,
            viewport: TerminalMetalViewport(
                drawableWidth: Float(width),
                drawableHeight: Float(height),
                backingScale: 1,
                verticalPixelOffset: verticalPixelOffset
            ),
            descriptor: pass,
            waitUntilCompleted: true,
            overscanRows: overscanRows
        )
        XCTAssertTrue(stats.isRenderable, "the frame was rejected before it reached the GPU")

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            target.getBytes(
                raw.baseAddress!,
                bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0)
        }
        return Pixels(width: width, height: height, bytes: bytes)
    }

    /// The base: no translation, no overscan. Each row is its own colour, in
    /// its own place. This is the path iOS uses and it must stay exactly here.
    func testWithNoTranslationEachRowIsWhereItAlwaysWas() throws {
        let pixels = try render(
            frame(rowsPacked: Self.rows), device: try device(),
            verticalPixelOffset: 0, overscanRows: 0)
        for row in 0..<Self.rows {
            let y = row * Self.cellHeight + Self.cellHeight / 2
            XCTAssertEqual(
                pixels.at(x: 4, y: y).0, Self.rowColors[row].0, "row \(row) red")
            XCTAssertEqual(
                pixels.at(x: 4, y: y).1, Self.rowColors[row].1, "row \(row) green")
            XCTAssertEqual(
                pixels.at(x: 4, y: y).2, Self.rowColors[row].2, "row \(row) blue")
        }
    }

    /// Half a cell up: every row's boundary has moved by exactly that, and
    /// the strip that opened at the bottom is the next line -- not blank, not
    /// a repeat of the last visible row.
    func testAHalfCellTranslationMovesEveryRowAndFillsTheStripBelow() throws {
        let half = Float(Self.cellHeight) / 2
        let pixels = try render(
            frame(rowsPacked: Self.rows + 1), device: try device(),
            verticalPixelOffset: -half, overscanRows: 1)

        // Every viewport row sits half a cell higher than it did.
        for row in 0..<Self.rows {
            let y = row * Self.cellHeight + Self.cellHeight / 2 - Int(half)
            guard y >= 0 else { continue }
            let got = pixels.at(x: 4, y: y)
            XCTAssertEqual(
                [got.0, got.1, got.2],
                [Self.rowColors[row].0, Self.rowColors[row].1, Self.rowColors[row].2],
                "row \(row) did not move up by half a cell")
        }

        // The bottom strip is the overscan row, drawn where the translation
        // uncovered it.
        let stripY = pixels.height - Int(half) / 2 - 1
        let strip = pixels.at(x: 4, y: stripY)
        let expected = Self.rowColors[Self.rows]
        XCTAssertEqual(
            [strip.0, strip.1, strip.2], [expected.0, expected.1, expected.2],
            "the strip the translation opened is not the line below the viewport")
        XCTAssertNotEqual(
            [strip.0, strip.1, strip.2],
            [Self.rowColors[Self.rows - 1].0,
             Self.rowColors[Self.rows - 1].1,
             Self.rowColors[Self.rows - 1].2],
            "the strip repeats the last visible row instead of showing the next one")
    }

    /// Without the extra row, that same strip is empty -- which is the defect
    /// this change exists to remove. Rendering the fix's offset against the
    /// base's payload reproduces it deterministically.
    func testWithoutOverscanTheSameTranslationLeavesTheStripBlank() throws {
        let half = Float(Self.cellHeight) / 2
        let pixels = try render(
            frame(rowsPacked: Self.rows), device: try device(),
            verticalPixelOffset: -half, overscanRows: 0)

        let stripY = pixels.height - Int(half) / 2 - 1
        let strip = pixels.at(x: 4, y: stripY)
        let lastRow = Self.rowColors[Self.rows - 1]
        XCTAssertNotEqual(
            [strip.0, strip.1, strip.2], [lastRow.0, lastRow.1, lastRow.2],
            "the last row must not have been stretched into the exposed strip")
    }

    /// Every pass moves, not just backgrounds.
    ///
    /// The frame carries glyphs, a visible cursor and a selection, and the
    /// whole rendered image is compared against itself shifted by a whole
    /// number of pixels. Any pass that failed to apply the translation would
    /// leave its pixels behind and break the equality -- there is nowhere for
    /// a missed pass to hide, because nothing is being sampled selectively.
    ///
    /// An earlier version of this test packed spaces everywhere and sampled
    /// flat row backgrounds, so it could only ever prove that a background
    /// had moved. The non-vacuity assertion below is what keeps that from
    /// happening again.
    func testEveryPassMovesTogetherNotJustBackgrounds() throws {
        let shift = 4  // whole pixels, so no filtering difference can creep in
        let selection = FfiSelectionRange(
            startRow: 2, startCol: 0, endRow: 2, endCol: UInt32(Self.cols - 1), mode: .linear)
        let device = try self.device()

        func draw(offset: Float) throws -> Pixels {
            try render(
                frame(rowsPacked: Self.rows + 1, inked: true,
                      cursorVisible: true, selection: selection),
                device: device, verticalPixelOffset: offset, overscanRows: 1)
        }

        let base = try draw(offset: 0)
        let moved = try draw(offset: -Float(shift))

        // The frame must actually contain something other than flat row
        // backgrounds, or the comparison below proves nothing at all.
        var inked = 0
        for row in 0..<Self.rows {
            let bg = Self.rowColors[row]
            for y in (row * Self.cellHeight)..<((row + 1) * Self.cellHeight) {
                for x in 0..<base.width where base.at(x: x, y: y) != bg {
                    inked += 1
                }
            }
        }
        XCTAssertGreaterThan(inked, 200,
                             "the frame is flat background: a shift proof over it is vacuous")

        // Every pixel of the moved frame is the base frame `shift` lower.
        var compared = 0
        for y in 0..<(base.height - shift) {
            for x in 0..<base.width {
                let expected = base.at(x: x, y: y + shift)
                let actual = moved.at(x: x, y: y)
                if expected != actual {
                    XCTFail("pixel (\(x), \(y)) did not move with the frame: "
                            + "expected \(expected), got \(actual)")
                    return
                }
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 0)
    }

    /// A Kitty placement on the row the translation exposes is drawn in the
    /// strip, rather than dropped and popped in on the row boundary.
    func testAnImagePlacedOnTheOverscanRowIsPlannedIntoTheStrip() throws {
        let placement = FfiGraphicsPlacement(
            imageId: 1, placementId: 1, row: UInt32(Self.rows), col: 0)
        var withImage = frame(rowsPacked: Self.rows + 1)
        withImage = FfiRenderFrame(
            snapshot: FfiSnapshot(
                cols: withImage.snapshot.cols,
                rows: withImage.snapshot.rows,
                cursorRow: withImage.snapshot.cursorRow,
                cursorCol: withImage.snapshot.cursorCol,
                cursorVisible: withImage.snapshot.cursorVisible,
                cursorStyle: withImage.snapshot.cursorStyle,
                title: withImage.snapshot.title,
                modes: withImage.snapshot.modes,
                viewportOffset: withImage.snapshot.viewportOffset,
                scrollbackLen: withImage.snapshot.scrollbackLen,
                damagedRows: withImage.snapshot.damagedRows,
                selection: withImage.snapshot.selection,
                graphicsPlacements: [placement]
            ),
            packedCells: withImage.packedCells,
            epoch: withImage.epoch
        )

        let planner = TerminalMetalFramePlanner(
            metrics: TerminalMetalCellMetrics(
                font: CTFontCreateWithName("Menlo" as CFString, 12, nil),
                cellWidth: CGFloat(Self.cellWidth),
                cellHeight: CGFloat(Self.cellHeight),
                ascent: 15,
                scale: 1))
        let viewport = TerminalMetalViewport(
            drawableWidth: Float(Self.cols * Self.cellWidth),
            drawableHeight: Float(Self.rows * Self.cellHeight))

        // Bounded at the viewport, this placement is out of range and dropped.
        let withoutStrip = planner.plan(
            frame: withImage, viewport: viewport, overscanRows: 0,
            imageProvider: { _ in nil },
            imageMetadataProvider: { _ in Self.imageMetadata })
        // Bounded at the drawn rows, it belongs to the strip.
        let withStrip = planner.plan(
            frame: withImage, viewport: viewport, overscanRows: 1,
            imageProvider: { _ in nil },
            imageMetadataProvider: { _ in Self.imageMetadata })

        XCTAssertEqual(withoutStrip.imageInstances, 0,
                       "a placement past the drawn rows must not be planned")
        XCTAssertEqual(withStrip.imageInstances, 1,
                       "the image on the exposed row was dropped out of the strip")
    }

    private static let imageMetadata = FfiGraphicsImageMetadata(
        format: .rgba, width: 8, height: 16, generation: 1)
}
