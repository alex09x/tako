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

/// Errors related to user-defined redaction patterns.
public enum RedactionPatternError: Error, LocalizedError, Equatable {
    case unsafePattern(String)
    case patternTooComplex(String)

    public var errorDescription: String? {
        switch self {
        case .unsafePattern(let reason):
            return "Unsafe redaction pattern: \(reason)"
        case .patternTooComplex(let reason):
            return "Redaction pattern too complex: \(reason)"
        }
    }
}

/// Manages user-defined regex redaction patterns for persisted session snapshots (G5).
/// Patterns match sensitive strings (e.g. API keys, bearer tokens) and replace them with `[REDACTED]` or cell masks.
public final class SessionSnapshotRedactor: @unchecked Sendable {
    public static let shared = SessionSnapshotRedactor()

    private let lock = NSLock()
    private var patternStrings: [String] = []
    private var compiledRegexes: [NSRegularExpression] = []

    public init() {}

    /// Validates whether a user-supplied regex pattern is safe from catastrophic backtracking (ReDoS).
    /// Uses proven safe-pattern grammar rejecting ambiguous adjacent repetitions, nested quantifiers,
    /// and branching explosions.
    public static func isPatternSafe(_ pattern: String) -> Bool {
        guard pattern.count <= 256 else { return false }
        let safety = TerminalRegexTrigger.isSafePattern(pattern)
        guard safety.isSafe else { return false }
        return true
    }

    /// All configured redaction pattern strings.
    public var patterns: [String] {
        lock.lock()
        defer { lock.unlock() }
        return patternStrings
    }

    /// Whether any redaction patterns are currently registered.
    public var hasPatterns: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !compiledRegexes.isEmpty
    }

    /// Adds a user-defined redaction pattern with complexity and safety validation.
    @discardableResult
    public func addPattern(_ pattern: String) throws -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        guard Self.isPatternSafe(trimmed) else {
            throw RedactionPatternError.unsafePattern("Pattern contains nested quantifiers, ambiguous repeated atoms, or dangerous repetitions prone to catastrophic backtracking")
        }

        let regex = try NSRegularExpression(pattern: trimmed, options: [])
        lock.lock()
        defer { lock.unlock() }
        if !patternStrings.contains(trimmed) {
            patternStrings.append(trimmed)
            compiledRegexes.append(regex)
            return true
        }
        return false
    }

    /// Sets the list of user-defined redaction patterns, rejecting any unsafe patterns.
    public func setPatterns(_ patterns: [String]) {
        lock.lock()
        defer { lock.unlock() }
        var validStrings: [String] = []
        var validRegexes: [NSRegularExpression] = []
        for p in patterns {
            let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, Self.isPatternSafe(trimmed) else { continue }
            if let regex = try? NSRegularExpression(pattern: trimmed, options: []) {
                if !validStrings.contains(trimmed) {
                    validStrings.append(trimmed)
                    validRegexes.append(regex)
                }
            }
        }
        self.patternStrings = validStrings
        self.compiledRegexes = validRegexes
    }

    /// Clears all redaction patterns.
    public func clearPatterns() {
        lock.lock()
        defer { lock.unlock() }
        patternStrings.removeAll()
        compiledRegexes.removeAll()
    }

    /// Redacts all matches in a text string, replacing them with `[REDACTED]`.
    /// Bounded by a deadline and line chunking to prevent terminal output from hanging session export.
    /// Fails closed on timeout by replacing the unprocessed remainder with `[REDACTED]`.
    public func redact(_ text: String, timeout: TimeInterval = 0.5) -> String {
        lock.lock()
        let regexes = compiledRegexes
        lock.unlock()

        guard !regexes.isEmpty, !text.isEmpty else { return text }

        if timeout <= 0 {
            return "[REDACTED]"
        }

        let deadline = Date().addingTimeInterval(timeout)

        // Process line-by-line to bound regex matching work and avoid monolithic reallocations
        let lines = text.components(separatedBy: "\n")
        var redactedLines: [String] = []
        redactedLines.reserveCapacity(lines.count)

        var timedOut = false
        for line in lines {
            if timedOut || Date() >= deadline {
                redactedLines.append("[REDACTED]")
                timedOut = true
                break
            }

            let (redactedLine, lineTimedOut) = redactLine(line, regexes: regexes, deadline: deadline)
            redactedLines.append(redactedLine)
            if lineTimedOut {
                timedOut = true
                break
            }
        }
        return redactedLines.joined(separator: "\n")
    }

    /// Redacts a single line of text with overlapping chunk carry windows and fail-closed deadline checking.
    private func redactLine(
        _ line: String,
        regexes: [NSRegularExpression],
        deadline: Date
    ) -> (result: String, timedOut: Bool) {
        if Date() >= deadline {
            return ("[REDACTED]", true)
        }

        let chunkSize = 4096
        let carryWindow = 2048

        // If line is within a single chunk, redact directly
        if line.count <= chunkSize {
            var modified = line
            for regex in regexes {
                if Date() >= deadline {
                    return ("[REDACTED]", true)
                }
                let range = NSRange(modified.startIndex..<modified.endIndex, in: modified)
                modified = regex.stringByReplacingMatches(
                    in: modified,
                    options: [],
                    range: range,
                    withTemplate: "[REDACTED]"
                )
            }
            return (modified, false)
        }

        // Long line: process in overlapping chunks with a carry window
        var chunkedLine = ""
        var currentIdx = line.startIndex

        while currentIdx < line.endIndex {
            if Date() >= deadline {
                chunkedLine.append("[REDACTED]")
                return (chunkedLine, true)
            }

            let maxWindowEnd = line.index(currentIdx, offsetBy: chunkSize + carryWindow, limitedBy: line.endIndex) ?? line.endIndex
            let isLastChunk = (maxWindowEnd == line.endIndex)
            let windowStr = String(line[currentIdx..<maxWindowEnd])

            if isLastChunk {
                var modifiedChunk = windowStr
                for regex in regexes {
                    if Date() >= deadline {
                        chunkedLine.append("[REDACTED]")
                        return (chunkedLine, true)
                    }
                    let range = NSRange(modifiedChunk.startIndex..<modifiedChunk.endIndex, in: modifiedChunk)
                    modifiedChunk = regex.stringByReplacingMatches(
                        in: modifiedChunk,
                        options: [],
                        range: range,
                        withTemplate: "[REDACTED]"
                    )
                }
                chunkedLine.append(modifiedChunk)
                break
            }

            let boundaryOffset = min(chunkSize, windowStr.count)
            let boundaryIndex = windowStr.index(windowStr.startIndex, offsetBy: boundaryOffset)

            // Find all matches in current window across all regexes
            var matchRanges: [Range<String.Index>] = []
            for regex in regexes {
                if Date() >= deadline {
                    chunkedLine.append("[REDACTED]")
                    return (chunkedLine, true)
                }
                let nsRange = NSRange(windowStr.startIndex..<windowStr.endIndex, in: windowStr)
                let matches = regex.matches(in: windowStr, options: [], range: nsRange)
                for match in matches {
                    if let range = Range(match.range, in: windowStr) {
                        matchRanges.append(range)
                    }
                }
            }

            // Adjust cut point backwards if any match straddles the boundary
            var cutIndex = boundaryIndex
            var changed = true
            while changed {
                changed = false
                for range in matchRanges {
                    if range.lowerBound < cutIndex && range.upperBound > cutIndex {
                        cutIndex = range.lowerBound
                        changed = true
                    }
                }
            }

            var advanceIndex = cutIndex
            if cutIndex == windowStr.startIndex {
                // If a match or chain starts at window start and crosses boundary, expand cutIndex to include it
                let maxEnd = matchRanges.filter { $0.lowerBound < boundaryIndex }.map(\.upperBound).max() ?? boundaryIndex
                cutIndex = maxEnd
                advanceIndex = maxEnd
            }

            let chunkToEmit = String(windowStr[..<cutIndex])
            var modifiedChunk = chunkToEmit
            for regex in regexes {
                if Date() >= deadline {
                    chunkedLine.append("[REDACTED]")
                    return (chunkedLine, true)
                }
                let range = NSRange(modifiedChunk.startIndex..<modifiedChunk.endIndex, in: modifiedChunk)
                modifiedChunk = regex.stringByReplacingMatches(
                    in: modifiedChunk,
                    options: [],
                    range: range,
                    withTemplate: "[REDACTED]"
                )
            }
            chunkedLine.append(modifiedChunk)

            let distance = windowStr.distance(from: windowStr.startIndex, to: advanceIndex)
            guard distance > 0 else {
                chunkedLine.append("[REDACTED]")
                return (chunkedLine, true)
            }
            currentIdx = line.index(currentIdx, offsetBy: distance, limitedBy: line.endIndex) ?? line.endIndex
        }

        return (chunkedLine, false)
    }

    /// Redacts matching sensitive patterns in binary checkpoint data.
    /// Parses decoded cell text from terminal grids and re-encodes the checkpoint with valid structure and CRC32.
    public func redact(checkpoint: Data) -> Data {
        lock.lock()
        let regexes = compiledRegexes
        lock.unlock()

        guard !regexes.isEmpty, checkpoint.count >= 20 else { return checkpoint }

        // Check TKCK magic
        guard checkpoint.prefix(4) == Data("TKCK".utf8) else {
            return checkpoint
        }

        let version = checkpoint.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }
        let flags = checkpoint.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self) }
        let payload = checkpoint.subdata(in: 20..<checkpoint.count)

        var engine = CheckpointRedactionEngine(input: payload, version: version, regexes: regexes)
        guard let newPayload = engine.redactPayload() else {
            return fallbackRedactBytes(checkpoint: checkpoint, regexes: regexes)
        }

        var result = Data("TKCK".utf8)
        var verLE = version.littleEndian
        withUnsafeBytes(of: &verLE) { result.append(contentsOf: $0) }
        var flagsLE = flags.littleEndian
        withUnsafeBytes(of: &flagsLE) { result.append(contentsOf: $0) }
        var payloadLenLE = UInt32(newPayload.count).littleEndian
        withUnsafeBytes(of: &payloadLenLE) { result.append(contentsOf: $0) }

        let newCRC = Self.computeCRC32(data: [UInt8](newPayload))
        var crcLE = newCRC.littleEndian
        withUnsafeBytes(of: &crcLE) { result.append(contentsOf: $0) }

        result.append(newPayload)
        return result
    }

    /// Computes standard IEEE 802.3 CRC32 checksum.
    public static func computeCRC32(data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let lookupIndex = UInt8((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ crcTable[Int(lookupIndex)]
        }
        return crc ^ 0xFFFFFFFF
    }

    private static let crcTable: [UInt32] = {
        (0...255).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                if (c & 1) != 0 {
                    c = 0xEDB88320 ^ (c >> 1)
                } else {
                    c = c >> 1
                }
            }
            return c
        }
    }()

    private func fallbackRedactBytes(checkpoint: Data, regexes: [NSRegularExpression]) -> Data {
        var mutable = checkpoint
        let payloadStart = 20
        guard mutable.count > payloadStart else { return checkpoint }
        let payloadData = mutable.subdata(in: payloadStart..<mutable.count)
        guard let latin1String = String(data: payloadData, encoding: .isoLatin1) else {
            return checkpoint
        }
        var didModify = false
        var modifiedPayload = [UInt8](payloadData)
        for regex in regexes {
            let nsRange = NSRange(location: 0, length: latin1String.utf16.count)
            let matches = regex.matches(in: latin1String, options: [], range: nsRange)
            for match in matches {
                guard let range = Range(match.range, in: latin1String) else { continue }
                let startOffset = latin1String.utf8.distance(from: latin1String.startIndex, to: range.lowerBound)
                let matchLen = latin1String.utf8.distance(from: range.lowerBound, to: range.upperBound)
                guard startOffset >= 0, startOffset + matchLen <= modifiedPayload.count else { continue }
                for i in 0..<matchLen {
                    modifiedPayload[startOffset + i] = 0x2A
                }
                didModify = true
            }
        }
        if didModify {
            mutable.replaceSubrange(payloadStart..<mutable.count, with: modifiedPayload)
            let newCRC = Self.computeCRC32(data: modifiedPayload)
            var crcLE = newCRC.littleEndian
            withUnsafeBytes(of: &crcLE) { mutable.replaceSubrange(16..<20, with: $0) }
        }
        return mutable
    }
}

// MARK: - Binary Checkpoint Structured Redaction Engine

private struct CheckpointRedactionEngine {
    let input: Data
    let version: UInt32
    let regexes: [NSRegularExpression]
    var offset: Int = 0
    var out = Data()

    struct DecodedCell {
        var char: UInt32
        var content: Data
        var isDefault: Bool
    }

    mutating func readUInt8() -> UInt8? {
        guard offset < input.count else { return nil }
        let v = input[offset]
        offset += 1
        return v
    }

    mutating func readUInt16() -> UInt16? {
        guard offset + 2 <= input.count else { return nil }
        let v = input.subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: UInt16.self) }
        offset += 2
        return UInt16(littleEndian: v)
    }

    mutating func readUInt32() -> UInt32? {
        guard offset + 4 <= input.count else { return nil }
        let v = input.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self) }
        offset += 4
        return UInt32(littleEndian: v)
    }

    mutating func readUInt64() -> UInt64? {
        guard offset + 8 <= input.count else { return nil }
        let v = input.subdata(in: offset..<offset+8).withUnsafeBytes { $0.load(as: UInt64.self) }
        offset += 8
        return UInt64(littleEndian: v)
    }

    mutating func readBool() -> Bool? {
        guard let b = readUInt8() else { return nil }
        return b != 0
    }

    mutating func readBytes(_ count: Int) -> Data? {
        guard offset + count <= input.count else { return nil }
        let d = input.subdata(in: offset..<offset+count)
        offset += count
        return d
    }

    mutating func copyBytes(_ count: Int) -> Bool {
        guard let d = readBytes(count) else { return false }
        out.append(d)
        return true
    }

    mutating func copyUInt8() -> Bool {
        guard let v = readUInt8() else { return false }
        out.append(v)
        return true
    }

    mutating func copyUInt32() -> Bool {
        guard let d = readBytes(4) else { return false }
        out.append(d)
        return true
    }

    mutating func copyUInt64() -> Bool {
        guard let d = readBytes(8) else { return false }
        out.append(d)
        return true
    }

    mutating func copyBool() -> Bool {
        copyUInt8()
    }

    mutating func readColor() -> (tag: UInt8, bytes: Data)? {
        guard let tag = readUInt8() else { return nil }
        switch tag {
        case 0:
            return (0, Data([0]))
        case 1:
            guard let n = readUInt8() else { return nil }
            return (1, Data([1, n]))
        case 2:
            guard let rgb = readBytes(3) else { return nil }
            var d = Data([2])
            d.append(rgb)
            return (2, d)
        default:
            return nil
        }
    }

    mutating func copyUInt16() -> Bool {
        guard let d = readBytes(2) else { return false }
        out.append(d)
        return true
    }

    mutating func copyColor() -> Bool {
        guard let c = readColor() else { return false }
        out.append(c.bytes)
        return true
    }

    mutating func copyLengthPrefixedBytes() -> Bool {
        guard let len = readUInt32() else { return false }
        var lenLE = len.littleEndian
        withUnsafeBytes(of: &lenLE) { out.append(contentsOf: $0) }
        return copyBytes(Int(len))
    }

    mutating func redactLengthPrefixedString() -> Bool {
        guard let len = readUInt32() else { return false }
        let l = Int(len)
        guard let strBytes = readBytes(l) else { return false }
        let str = String(data: strBytes, encoding: .utf8) ?? ""
        let redacted = redactText(str)
        let utf8Bytes = Data(redacted.utf8)
        var newLen = UInt32(utf8Bytes.count).littleEndian
        withUnsafeBytes(of: &newLen) { out.append(contentsOf: $0) }
        out.append(utf8Bytes)
        return true
    }

    mutating func redactOptionalString() -> Bool {
        guard let present = readBool() else { return false }
        out.append(present ? 0x01 : 0x00)
        if present {
            return redactLengthPrefixedString()
        }
        return true
    }

    mutating func copyOptionalUInt64() -> Bool {
        guard let present = readBool() else { return false }
        out.append(present ? 0x01 : 0x00)
        return copyUInt64()
    }

    func redactText(_ str: String) -> String {
        guard !regexes.isEmpty, !str.isEmpty else { return str }
        var modified = str
        for regex in regexes {
            let range = NSRange(modified.startIndex..<modified.endIndex, in: modified)
            modified = regex.stringByReplacingMatches(
                in: modified,
                options: [],
                range: range,
                withTemplate: "[REDACTED]"
            )
        }
        return modified
    }

    mutating func readSingleCell() -> DecodedCell? {
        guard let cp = readUInt32() else { return nil }
        var content = Data()
        guard let fg = readColor() else { return nil }
        content.append(fg.bytes)
        guard let bg = readColor() else { return nil }
        content.append(bg.bytes)
        guard let attrs = readBytes(2) else { return nil }
        content.append(attrs)
        guard let flags = readUInt8() else { return nil }
        content.append(flags)
        guard let uStyle = readUInt8() else { return nil }
        content.append(uStyle)
        if (flags & (1 << 3)) != 0 {
            guard let uColor = readColor() else { return nil }
            content.append(uColor.bytes)
        }
        if (flags & (1 << 4)) != 0 {
            guard let hLink = readBytes(4) else { return nil }
            content.append(hLink)
        }
        return DecodedCell(char: cp, content: content, isDefault: false)
    }

    mutating func readCells(expectedLen: Int) -> [DecodedCell]? {
        var cells: [DecodedCell] = []
        cells.reserveCapacity(expectedLen)
        while cells.count < expectedLen {
            guard let op = readUInt8() else { return nil }
            switch op {
            case 0x00:
                cells.append(DecodedCell(char: 32, content: Data([0, 0, 0, 0, 0, 0]), isDefault: true))
            case 0x01:
                guard let count = readUInt16() else { return nil }
                let c = Int(count)
                guard c > 0, cells.count + c <= expectedLen else { return nil }
                for _ in 0..<c {
                    cells.append(DecodedCell(char: 32, content: Data([0, 0, 0, 0, 0, 0]), isDefault: true))
                }
            case 0x02:
                guard let cell = readSingleCell() else { return nil }
                cells.append(cell)
            case 0x03:
                guard let count = readUInt16() else { return nil }
                let c = Int(count)
                guard c > 0, cells.count + c <= expectedLen else { return nil }
                guard let cell = readSingleCell() else { return nil }
                for _ in 0..<c {
                    cells.append(cell)
                }
            default:
                return nil
            }
        }
        guard cells.count == expectedLen else { return nil }
        return cells
    }

    func writeCells(_ cells: [DecodedCell], into buffer: inout Data) {
        var idx = 0
        while idx < cells.count {
            let cell = cells[idx]
            if cell.isDefault {
                let start = idx
                while idx < cells.count && cells[idx].isDefault && (idx - start) < 65535 {
                    idx += 1
                }
                let count = idx - start
                if count == 1 {
                    buffer.append(0x00)
                } else {
                    buffer.append(0x01)
                    var c = UInt16(count).littleEndian
                    withUnsafeBytes(of: &c) { buffer.append(contentsOf: $0) }
                }
            } else {
                let start = idx
                while idx < cells.count && !cells[idx].isDefault && cells[idx].char == cell.char && cells[idx].content == cell.content && (idx - start) < 65535 {
                    idx += 1
                }
                let count = idx - start
                if count == 1 {
                    buffer.append(0x02)
                    var cp = cell.char.littleEndian
                    withUnsafeBytes(of: &cp) { buffer.append(contentsOf: $0) }
                    buffer.append(cell.content)
                } else {
                    buffer.append(0x03)
                    var c = UInt16(count).littleEndian
                    withUnsafeBytes(of: &c) { buffer.append(contentsOf: $0) }
                    var cp = cell.char.littleEndian
                    withUnsafeBytes(of: &cp) { buffer.append(contentsOf: $0) }
                    buffer.append(cell.content)
                }
            }
        }
    }

    func redactRow(_ cells: inout [DecodedCell]) {
        guard !cells.isEmpty else { return }
        let scalars = cells.map { UnicodeScalar($0.char) ?? UnicodeScalar(32)! }
        let line = String(String.UnicodeScalarView(scalars))
        guard !line.isEmpty else { return }

        for regex in regexes {
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            let matches = regex.matches(in: line, options: [], range: nsRange)
            for match in matches {
                guard let strRange = Range(match.range, in: line) else { continue }
                let startIdx = line.distance(from: line.startIndex, to: strRange.lowerBound)
                let endIdx = line.distance(from: line.startIndex, to: strRange.upperBound)
                guard startIdx >= 0, endIdx <= cells.count, startIdx < endIdx else { continue }
                for i in startIdx..<endIdx {
                    cells[i].char = 42 // ASCII '*' (0x2A)
                    if cells[i].isDefault {
                        cells[i].isDefault = false
                        cells[i].content = Data([0, 0, 0, 0, 0, 0])
                    }
                }
            }
        }
    }

    mutating func redactPayload() -> Data? {
        // 1. Dimensions and leading geometry
        guard let cols = readUInt32(), let rows = readUInt32() else { return nil }
        var colsLE = cols.littleEndian
        withUnsafeBytes(of: &colsLE) { out.append(contentsOf: $0) }
        var rowsLE = rows.littleEndian
        withUnsafeBytes(of: &rowsLE) { out.append(contentsOf: $0) }

        guard copyUInt8() else { return nil } // active buffer
        guard copyUInt32() else { return nil } // scroll_top
        guard copyUInt32() else { return nil } // scroll_bottom
        guard copyUInt32() else { return nil } // scroll_left
        guard copyUInt32() else { return nil } // scroll_right
        guard copyUInt32() else { return nil } // viewport_offset
        guard copyBool() else { return nil }   // pending_wrap

        // 2. Primary Grid
        guard copyUInt32() else { return nil } // prim_cap
        guard copyUInt64() else { return nil } // prim_evicted
        guard let primSbLen = readUInt32() else { return nil }
        var primSbLenLE = primSbLen.littleEndian
        withUnsafeBytes(of: &primSbLenLE) { out.append(contentsOf: $0) }

        for _ in 0..<primSbLen {
            guard copyBool() else { return nil } // wrapped
            if version >= 5 {
                guard copyUInt8() else { return nil } // semantic
            }
            guard let cellsLen = readUInt32() else { return nil }
            var cellsLenLE = cellsLen.littleEndian
            withUnsafeBytes(of: &cellsLenLE) { out.append(contentsOf: $0) }
            guard var cells = readCells(expectedLen: Int(cellsLen)) else { return nil }
            redactRow(&cells)
            writeCells(cells, into: &out)
        }

        for _ in 0..<rows {
            guard copyBool() else { return nil } // wrapped
            guard copyUInt8() else { return nil } // semantic
            guard var cells = readCells(expectedLen: Int(cols)) else { return nil }
            redactRow(&cells)
            writeCells(cells, into: &out)
        }

        // 3. Alternate Grid
        guard copyUInt32() else { return nil } // alt_cap
        guard copyUInt64() else { return nil } // alt_evicted
        guard let altSbLen = readUInt32() else { return nil }
        var altSbLenLE = altSbLen.littleEndian
        withUnsafeBytes(of: &altSbLenLE) { out.append(contentsOf: $0) }

        for _ in 0..<altSbLen {
            guard copyBool() else { return nil } // wrapped
            if version >= 5 {
                guard copyUInt8() else { return nil } // semantic
            }
            guard let cellsLen = readUInt32() else { return nil }
            var cellsLenLE = cellsLen.littleEndian
            withUnsafeBytes(of: &cellsLenLE) { out.append(contentsOf: $0) }
            guard var cells = readCells(expectedLen: Int(cellsLen)) else { return nil }
            redactRow(&cells)
            writeCells(cells, into: &out)
        }

        for _ in 0..<rows {
            guard copyBool() else { return nil } // wrapped
            guard copyUInt8() else { return nil } // semantic
            guard var cells = readCells(expectedLen: Int(cols)) else { return nil }
            redactRow(&cells)
            writeCells(cells, into: &out)
        }

        // 4. Cursor
        guard copyUInt32() else { return nil } // row
        guard copyUInt32() else { return nil } // col
        guard copyColor() else { return nil }  // fg
        guard copyColor() else { return nil }  // bg
        guard copyUInt16() else { return nil } // attrs
        guard copyUInt8() else { return nil }  // underline_style
        guard copyColor() else { return nil }  // underline_color
        guard copyBool() else { return nil }   // cursor_visible
        guard copyUInt8() else { return nil }  // shape
        guard copyBool() else { return nil }   // blinking

        // 5. Saved Cursor
        guard let hasSaved = readBool() else { return nil }
        out.append(hasSaved ? 0x01 : 0x00)
        if hasSaved {
            guard copyUInt32() else { return nil } // s_row
            guard copyUInt32() else { return nil } // s_col
            guard copyColor() else { return nil }  // s_fg
            guard copyColor() else { return nil }  // s_bg
            guard copyUInt16() else { return nil } // s_attrs
            guard copyUInt8() else { return nil }  // s_g0
            guard copyUInt8() else { return nil }  // s_g1
            guard copyBool() else { return nil }   // s_shift_out
            guard copyBool() else { return nil }   // s_origin_mode
            guard copyBool() else { return nil }   // s_pending_wrap
            guard copyUInt8() else { return nil }  // s_prot
            guard copyUInt8() else { return nil }  // s_gr_slot
        }

        // 6. Tab Stops
        guard let tabCols = readUInt32() else { return nil }
        var tabColsLE = tabCols.littleEndian
        withUnsafeBytes(of: &tabColsLE) { out.append(contentsOf: $0) }
        let bitsetLen = (Int(tabCols) + 7) / 8
        guard copyBytes(bitsetLen) else { return nil }

        // 7. Modes
        guard copyUInt32() else { return nil } // mode_flags
        guard copyUInt8() else { return nil }  // mouse_tracking

        // 8. Parser State
        guard copyUInt8() else { return nil }  // state
        guard let interLen = readUInt8() else { return nil }
        out.append(interLen)
        guard copyBytes(Int(interLen)) else { return nil }
        guard let paramsLen = readUInt8() else { return nil }
        out.append(paramsLen)
        guard copyBytes(Int(paramsLen) * 2) else { return nil }
        guard copyUInt32() else { return nil } // params_sep
        guard copyBool() else { return nil }   // ignore
        guard copyLengthPrefixedBytes() else { return nil } // osc_raw
        guard copyLengthPrefixedBytes() else { return nil } // apc_raw
        guard copyUInt8() else { return nil }  // utf8_need
        guard copyUInt32() else { return nil } // utf8_cp

        // 9. DCS
        guard copyUInt8() else { return nil } // dcs_kind
        guard copyLengthPrefixedBytes() else { return nil } // dcs_buf

        // 10. Charsets & Shift
        guard copyUInt8() else { return nil } // g0
        guard copyUInt8() else { return nil } // g1
        guard copyUInt8() else { return nil } // g2
        guard copyUInt8() else { return nil } // g3
        guard copyBool() else { return nil }  // shift_out
        guard copyUInt8() else { return nil } // gr_slot
        guard let hasSingleShift = readBool() else { return nil }
        out.append(hasSingleShift ? 0x01 : 0x00)
        if hasSingleShift {
            guard copyUInt8() else { return nil }
        }

        // 11. Hyperlinks
        guard let hCount = readUInt32() else { return nil }
        var hCountLE = hCount.littleEndian
        withUnsafeBytes(of: &hCountLE) { out.append(contentsOf: $0) }
        for _ in 0..<hCount {
            guard redactLengthPrefixedString() else { return nil }
        }
        guard let hIdCount = readUInt32() else { return nil }
        var hIdCountLE = hIdCount.littleEndian
        withUnsafeBytes(of: &hIdCountLE) { out.append(contentsOf: $0) }
        for _ in 0..<hIdCount {
            guard redactLengthPrefixedString() else { return nil } // URL key
            guard copyUInt32() else { return nil }                 // ID value
        }
        guard let hasCurHlink = readBool() else { return nil }
        out.append(hasCurHlink ? 0x01 : 0x00)
        if hasCurHlink {
            guard copyUInt32() else { return nil }
        }

        // 12. Title & Title Stack
        guard redactLengthPrefixedString() else { return nil } // title
        guard let tsCount = readUInt32() else { return nil }
        var tsCountLE = tsCount.littleEndian
        withUnsafeBytes(of: &tsCountLE) { out.append(contentsOf: $0) }
        for _ in 0..<tsCount {
            guard redactLengthPrefixedString() else { return nil }
        }

        // 13. Palette
        guard copyBytes(768) else { return nil } // 256 * 3 colors
        guard let hasDefFg = readBool() else { return nil }
        out.append(hasDefFg ? 0x01 : 0x00)
        if hasDefFg { guard copyBytes(3) else { return nil } }
        guard let hasDefBg = readBool() else { return nil }
        out.append(hasDefBg ? 0x01 : 0x00)
        if hasDefBg { guard copyBytes(3) else { return nil } }
        guard let hasCurCol = readBool() else { return nil }
        out.append(hasCurCol ? 0x01 : 0x00)
        if hasCurCol { guard copyBytes(3) else { return nil } }

        // 14. Kitty Keyboard
        guard let kkCount = readUInt8() else { return nil }
        out.append(kkCount)
        guard copyBytes(Int(kkCount)) else { return nil }

        // 15. Graphics Placements
        guard let pCount = readUInt32() else { return nil }
        var pCountLE = pCount.littleEndian
        withUnsafeBytes(of: &pCountLE) { out.append(contentsOf: $0) }
        guard copyBytes(Int(pCount) * 16) else { return nil } // image_id, placement_id, row, col

        // 16. Graphics Images & Pending Transfers
        guard copyUInt32() else { return nil } // next_image_id
        guard copyUInt64() else { return nil } // next_image_generation
        guard let imagesCount = readUInt32() else { return nil }
        var imgCountLE = imagesCount.littleEndian
        withUnsafeBytes(of: &imgCountLE) { out.append(contentsOf: $0) }
        for _ in 0..<imagesCount {
            guard copyUInt32() else { return nil } // id
            guard copyUInt8() else { return nil }  // format
            guard copyUInt32() else { return nil } // width
            guard copyUInt32() else { return nil } // height
            guard copyUInt64() else { return nil } // generation
            guard copyLengthPrefixedBytes() else { return nil } // pixels
        }

        guard let pendingCount = readUInt32() else { return nil }
        var penCountLE = pendingCount.littleEndian
        withUnsafeBytes(of: &penCountLE) { out.append(contentsOf: $0) }
        for _ in 0..<pendingCount {
            guard let keyTag = readUInt8() else { return nil }
            out.append(keyTag)
            if keyTag == 1 {
                guard copyUInt32() else { return nil } // image id
            }
            guard copyUInt8() else { return nil } // format
            guard copyUInt32() else { return nil } // width
            guard copyUInt32() else { return nil } // height
            guard copyLengthPrefixedBytes() else { return nil } // data
        }

        // 17. Remaining State
        guard let hasLastPrinted = readBool() else { return nil }
        out.append(hasLastPrinted ? 0x01 : 0x00)
        if hasLastPrinted { guard copyUInt32() else { return nil } }
        guard copyUInt8() else { return nil }  // protected_mode
        guard redactLengthPrefixedString() else { return nil } // answerback
        guard redactLengthPrefixedString() else { return nil } // xtversion
        guard copyUInt32() else { return nil } // width_px
        guard copyUInt32() else { return nil } // height_px
        guard copyUInt8() else { return nil }  // dark_scheme
        guard copyUInt8() else { return nil }  // semantic_content
        guard copyUInt16() else { return nil } // checksum_ext

        // 18. Version 1 selection
        if version == 1 {
            guard let hasSel = readBool() else { return nil }
            out.append(hasSel ? 0x01 : 0x00)
            if hasSel { guard copyBytes(17) else { return nil } }
        }

        // 19. Version >= 3 Host Config & Clusters
        if version >= 3 {
            // Host config
            guard copyBytes(768) else { return nil } // base colors (256 * 3)
            guard copyBytes(32) else { return nil }  // overridden bitmask (32 bytes)
            for _ in 0..<3 { // base_fg, base_bg, base_cursor
                guard let hasBase = readBool() else { return nil }
                out.append(hasBase ? 0x01 : 0x00)
                if hasBase { guard copyBytes(3) else { return nil } }
            }
            guard copyBool() else { return nil } // fg_overridden
            guard copyBool() else { return nil } // bg_overridden
            guard copyBool() else { return nil } // cursor_overridden
            guard copyUInt8() else { return nil } // default_cursor_style shape
            guard copyBool() else { return nil }  // default_cursor_style blinking
            guard copyBool() else { return nil }  // cursor_style_overridden

            // Clusters (Primary)
            guard let primClustersCount = readUInt32() else { return nil }
            var pcCountLE = primClustersCount.littleEndian
            withUnsafeBytes(of: &pcCountLE) { out.append(contentsOf: $0) }
            for _ in 0..<primClustersCount {
                guard copyUInt32() else { return nil } // line
                guard copyUInt32() else { return nil } // col
                guard redactLengthPrefixedString() else { return nil } // extra
                guard copyBool() else { return nil }   // wide
            }

            // Clusters (Alternate)
            guard let altClustersCount = readUInt32() else { return nil }
            var acCountLE = altClustersCount.littleEndian
            withUnsafeBytes(of: &acCountLE) { out.append(contentsOf: $0) }
            for _ in 0..<altClustersCount {
                guard copyUInt32() else { return nil } // line
                guard copyUInt32() else { return nil } // col
                guard redactLengthPrefixedString() else { return nil } // extra
                guard copyBool() else { return nil }   // wide
            }

            // Version >= 4 Commands
            if version >= 4 {
                guard let runCount = readUInt32() else { return nil }
                var rcLE = runCount.littleEndian
                withUnsafeBytes(of: &rcLE) { out.append(contentsOf: $0) }
                guard copyBytes(Int(runCount) * 13) else { return nil } // tag(1) + id(8) + n(4) = 13 bytes

                guard copyOptionalUInt64() else { return nil } // pen
                guard copyOptionalUInt64() else { return nil } // next_id
                guard copyOptionalUInt64() else { return nil } // running

                guard let recCount = readUInt32() else { return nil }
                var recCountLE = recCount.littleEndian
                withUnsafeBytes(of: &recCountLE) { out.append(contentsOf: $0) }
                for _ in 0..<recCount {
                    guard copyUInt64() else { return nil } // id
                    guard copyUInt8() else { return nil }  // status
                    guard copyUInt32() else { return nil } // code
                    guard redactOptionalString() else { return nil } // cwd
                    guard redactOptionalString() else { return nil } // input!
                    guard copyBool() else { return nil }   // input_truncated
                    guard copyOptionalUInt64() else { return nil } // started_at_ms
                    if version >= 6 {
                        guard copyOptionalUInt64() else { return nil } // prompt_line
                    }
                }

                guard redactOptionalString() else { return nil } // last_cwd
                guard copyOptionalUInt64() else { return nil }   // input_start line
                guard copyUInt32() else { return nil }           // input_start col
                if version >= 6 {
                    guard copyOptionalUInt64() else { return nil } // last_prompt_line
                }
            }
        }

        // Must consume entire payload
        guard offset == input.count else { return nil }
        return out
    }
}
