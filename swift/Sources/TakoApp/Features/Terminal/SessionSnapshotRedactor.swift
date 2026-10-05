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
    public static func isPatternSafe(_ pattern: String) -> Bool {
        guard pattern.count <= 256 else { return false }
        // Check for nested quantifiers: parentheses containing repetition followed by another repetition operator
        // Examples: (a+)+, (.*)*, ([0-9]+)+, ((a+)?)+
        let nestedQuantifiers = #"\([^\)]*[\+\*\{][^\)]*\)[\+\*\{]"#
        if pattern.range(of: nestedQuantifiers, options: .regularExpression) != nil {
            return false
        }
        // Check for multiple unanchored wildcards
        let multipleWildcards = #"\.\*.*\.\*|\.\+.*\.\+"#
        if pattern.range(of: multipleWildcards, options: .regularExpression) != nil {
            return false
        }
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
            throw RedactionPatternError.unsafePattern("Pattern contains nested quantifiers or dangerous repetitions prone to catastrophic backtracking")
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
    public func redact(_ text: String) -> String {
        lock.lock()
        let regexes = compiledRegexes
        lock.unlock()

        guard !regexes.isEmpty, !text.isEmpty else { return text }

        // Process line-by-line to bound regex matching work and avoid monolithic reallocations
        let lines = text.components(separatedBy: "\n")
        let redactedLines = lines.map { line -> String in
            var modified = line
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
        return redactedLines.joined(separator: "\n")
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

        // 4. Remaining payload: Cursor, Modes, Parser, Hyperlinks, Title, Graphics, Commands
        // Copy the remaining bytes, applying byte-level text redaction if any regex matches in trailing strings
        guard offset <= input.count else { return nil }
        var tailData = input.subdata(in: offset..<input.count)
        if let tailString = String(data: tailData, encoding: .isoLatin1) {
            var modifiedTail = [UInt8](tailData)
            var didModifyTail = false
            for regex in regexes {
                let nsRange = NSRange(location: 0, length: tailString.utf16.count)
                let matches = regex.matches(in: tailString, options: [], range: nsRange)
                for match in matches {
                    guard let range = Range(match.range, in: tailString) else { continue }
                    let startOffset = tailString.utf8.distance(from: tailString.startIndex, to: range.lowerBound)
                    let matchLen = tailString.utf8.distance(from: range.lowerBound, to: range.upperBound)
                    guard startOffset >= 0, startOffset + matchLen <= modifiedTail.count else { continue }
                    for i in 0..<matchLen {
                        modifiedTail[startOffset + i] = 0x2A
                    }
                    didModifyTail = true
                }
            }
            if didModifyTail {
                tailData = Data(modifiedTail)
            }
        }
        out.append(tailData)
        return out
    }
}
