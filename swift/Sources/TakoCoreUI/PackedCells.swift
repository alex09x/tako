import CoreGraphics
import Foundation

// Reading a frame's cells out of the engine.
//
// The engine hands the whole viewport over as one buffer of fixed records
// rather than as an array of records with named fields: crossing the FFI
// field by field costs about seven microseconds per cell, which on a full
// screen is most of a frame. See `viewport_packed` in src/ffi/mod.rs for the
// layout this mirrors.

public struct TerminalCell {
    public static let byteSize = 16

    public let ch: UInt32
    public let fgR: UInt8, fgG: UInt8, fgB: UInt8
    public let bgR: UInt8, bgG: UInt8, bgB: UInt8
    public let ulR: UInt8, ulG: UInt8, ulB: UInt8
    public let underlineStyle: UInt8
    private let bits: UInt16

    public var bold: Bool { bits & 1 << 0 != 0 }
    public var dim: Bool { bits & 1 << 1 != 0 }
    public var italic: Bool { bits & 1 << 2 != 0 }
    public var underline: Bool { bits & 1 << 3 != 0 }
    public var blink: Bool { bits & 1 << 4 != 0 }
    public var reverse: Bool { bits & 1 << 5 != 0 }
    public var hidden: Bool { bits & 1 << 6 != 0 }
    public var strikethrough: Bool { bits & 1 << 7 != 0 }
    public var overline: Bool { bits & 1 << 8 != 0 }
    /// The left half of a double-width pair: the glyph owns the next cell.
    public var wide: Bool { bits & 1 << 9 != 0 }
    /// The cell holds a multi-codepoint grapheme cluster; `ch` is its first
    /// scalar and the frame's `graphemes` carries the whole cluster.
    public var hasGrapheme: Bool { bits & 1 << 10 != 0 }
    public var unicodeScalar: UnicodeScalar? { UnicodeScalar(ch) }

    init(_ p: UnsafeRawBufferPointer, _ offset: Int) {
        ch = UInt32(p[offset]) | UInt32(p[offset + 1]) << 8
            | UInt32(p[offset + 2]) << 16 | UInt32(p[offset + 3]) << 24
        fgR = p[offset + 4]; fgG = p[offset + 5]; fgB = p[offset + 6]
        bgR = p[offset + 7]; bgG = p[offset + 8]; bgB = p[offset + 9]
        bits = UInt16(p[offset + 10]) | UInt16(p[offset + 11]) << 8
        underlineStyle = p[offset + 12]
        ulR = p[offset + 13]; ulG = p[offset + 14]; ulB = p[offset + 15]
    }

    /// The same shape as it arrives from the per-cell API, for callers that
    /// still use that -- the inspector, accessibility.
    public init(_ cell: FfiCell) {
        ch = cell.ch
        fgR = cell.fgR; fgG = cell.fgG; fgB = cell.fgB
        bgR = cell.bgR; bgG = cell.bgG; bgB = cell.bgB
        ulR = cell.ulR; ulG = cell.ulG; ulB = cell.ulB
        underlineStyle = cell.underlineStyle
        var b: UInt16 = 0
        if cell.bold { b |= 1 << 0 }
        if cell.dim { b |= 1 << 1 }
        if cell.italic { b |= 1 << 2 }
        if cell.underline { b |= 1 << 3 }
        if cell.blink { b |= 1 << 4 }
        if cell.reverse { b |= 1 << 5 }
        if cell.hidden { b |= 1 << 6 }
        if cell.strikethrough { b |= 1 << 7 }
        if cell.overline { b |= 1 << 8 }
        if cell.wide { b |= 1 << 9 }
        if cell.grapheme != nil { b |= 1 << 10 }
        bits = b
    }
}

/// One frame's cells, sliced by row without copying.
public struct TerminalFrame {
    private let data: Data
    public let cols: Int
    public let rows: Int

    /// The complete packed viewport retained by the renderer for exact
    /// advisory-damage verification. `Data` is copy-on-write, so this does
    /// not duplicate an immutable FFI payload.
    var packedData: Data { data }

    public enum Validation: Equatable, Sendable {
        case valid
        case invalidDimensions
        case arithmeticOverflow
        case truncatedPayload
    }

    public init(packed: Data, cols: Int, rows: Int) {
        self.data = packed
        self.cols = cols
        self.rows = rows
    }

    private func checkedMultiply(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        if result.overflow {
            return nil
        }
        return result.partialValue
    }

    private var bytesPerRow: Int? {
        guard cols >= 0 else {
            return nil
        }
        return checkedMultiply(cols, TerminalCell.byteSize)
    }

    /// Number of complete rows available from `data` without treating a short final row as valid.
    public var completeRows: Int {
        guard let bytesPerRow = bytesPerRow, bytesPerRow > 0, rows > 0 else {
            return 0
        }
        return min(rows, data.count / bytesPerRow)
    }

    public func validate() -> Validation {
        guard cols >= 0, rows >= 0 else {
            return .invalidDimensions
        }
        guard let bytesPerRow else {
            return .arithmeticOverflow
        }
        guard let expectedByteCount = checkedMultiply(bytesPerRow, rows) else {
            return .arithmeticOverflow
        }
        if data.count < expectedByteCount {
            return .truncatedPayload
        }
        return .valid
    }

    public var isValid: Bool {
        validate() == .valid
    }

    /// Returns the raw packed bytes for a single row within the frame.
    public func rowData(for row: Int) -> Data? {
        guard let bytesPerRow, bytesPerRow > 0,
              row >= 0, row < rows,
              let rowOffset = checkedMultiply(row, bytesPerRow),
              rowOffset + bytesPerRow <= data.count else {
            return nil
        }
        return data.subdata(in: rowOffset..<(rowOffset + bytesPerRow))
    }

    /// Whether a packed row is byte-for-byte identical to that row in a
    /// previous complete viewport or per-row cached packed data. This is
    /// deliberately exact: hashes could retain stale renderer instances on a collision.
    func rowMatches(_ previous: Data, row: Int) -> Bool {
        guard let bytesPerRow, bytesPerRow > 0,
              row >= 0, row < rows,
              let rowOffset = checkedMultiply(row, bytesPerRow),
              rowOffset + bytesPerRow <= data.count else {
            return false
        }
        if previous.count == bytesPerRow {
            return data.withUnsafeBytes { current in
                previous.withUnsafeBytes { cached in
                    guard let currentBase = current.baseAddress,
                          let cachedBase = cached.baseAddress else {
                        return false
                    }
                    return memcmp(currentBase.advanced(by: rowOffset), cachedBase, bytesPerRow) == 0
                }
            }
        }
        guard rowOffset + bytesPerRow <= previous.count else {
            return false
        }
        return data.withUnsafeBytes { current in
            previous.withUnsafeBytes { cached in
                guard let currentBase = current.baseAddress,
                      let cachedBase = cached.baseAddress else {
                    return false
                }
                return memcmp(currentBase.advanced(by: rowOffset), cachedBase.advanced(by: rowOffset), bytesPerRow) == 0
            }
        }
    }

    private func cellOffset(row: Int, col: Int) -> Int? {
        guard rows > 0, cols > 0 else {
            return nil
        }
        guard row >= 0, row < rows, col >= 0, col < cols else {
            return nil
        }
        guard let bytesPerRow else {
            return nil
        }
        let (rowOffset, rowOverflow) = row.multipliedReportingOverflow(by: bytesPerRow)
        if rowOverflow {
            return nil
        }
        let (colOffset, colOverflow) = col.multipliedReportingOverflow(by: TerminalCell.byteSize)
        if colOverflow {
            return nil
        }
        let (offset, offsetOverflow) = rowOffset.addingReportingOverflow(colOffset)
        if offsetOverflow {
            return nil
        }
        let (endOffset, endOverflow) = offset.addingReportingOverflow(TerminalCell.byteSize)
        guard !endOverflow, endOffset <= data.count else {
            return nil
        }
        return offset
    }

    public func row(_ index: Int) -> [TerminalCell] {
        guard index >= 0, index < rows, cols > 0 else {
            return []
        }
        guard let bytesPerRow else {
            return []
        }
        guard let rowOffset = checkedMultiply(index, bytesPerRow) else {
            return []
        }
        let start = rowOffset
        guard start + bytesPerRow <= data.count else {
            return []
        }
        return data.withUnsafeBytes { raw in
            (0..<cols).compactMap { col in
                guard let offset = cellOffset(row: index, col: col) else {
                    return nil
                }
                return TerminalCell(raw, offset)
            }
        }
    }

    /// Read one cell by 2D position without allocating per-row buffers.
    public func cell(atRow row: Int, column: Int) -> TerminalCell? {
        guard let offset = cellOffset(row: row, col: column) else {
            return nil
        }
        return data.withUnsafeBytes { TerminalCell($0, offset) }
    }

    /// Read one cell by linear index.
    public func cell(at index: Int) -> TerminalCell? {
        guard index >= 0 else {
            return nil
        }
        guard let totalCells = checkedMultiply(rows, cols), totalCells > 0 else {
            return nil
        }
        guard index < totalCells else {
            return nil
        }
        return cell(atRow: index / cols, column: index - (index / cols) * cols)
    }

    /// Iterates all complete rows and cells in row-major order.
    public func forEachCell(_ visit: (Int, Int, TerminalCell) -> Void) {
        forEachCell(inRows: 0..<rows, inColumns: 0..<cols, visit)
    }

    /// Iterates a bounded rectangle of rows and columns in row-major order.
    /// Invalid bounds are clipped to valid cell coordinates, and every read is
    /// validated against row, column, and byte offsets before decoding.
    public func forEachCell(
        inRows rowRange: Range<Int>,
        inColumns columnRange: Range<Int>,
        _ visit: (Int, Int, TerminalCell) -> Void
    ) {
        guard rows > 0, cols > 0 else {
            return
        }
        guard let bytesPerRow else {
            return
        }
        guard bytesPerRow > 0 else {
            return
        }
        guard checkedMultiply(rows, cols) != nil else {
            return
        }
        let rowLimit = min(completeRows, rows)
        let clampedRowStart = max(rowRange.lowerBound, 0)
        let clampedRowEnd = min(rowRange.upperBound, rowLimit)
        let clampedColumnStart = max(columnRange.lowerBound, 0)
        let clampedColumnEnd = min(columnRange.upperBound, cols)
        guard clampedRowStart < clampedRowEnd else {
            return
        }
        guard clampedColumnStart < clampedColumnEnd else {
            return
        }

        data.withUnsafeBytes { raw in
            for row in clampedRowStart..<clampedRowEnd {
                guard let rowOffset = checkedMultiply(row, bytesPerRow) else {
                    return
                }
                let (rowEnd, rowEndOverflow) = rowOffset.addingReportingOverflow(bytesPerRow)
                if rowEndOverflow || rowEnd > raw.count {
                    return
                }
                for col in clampedColumnStart..<clampedColumnEnd {
                    guard let colOffset = checkedMultiply(col, TerminalCell.byteSize) else {
                        return
                    }
                    let (cellOffset, cellOffsetOverflow) = rowOffset.addingReportingOverflow(colOffset)
                    if cellOffsetOverflow || cellOffset + TerminalCell.byteSize > raw.count {
                        return
                    }
                    visit(row, col, TerminalCell(raw, cellOffset))
                }
            }
        }
    }
}
