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

/// Manages user-defined regex redaction patterns for persisted session snapshots (G5).
/// Patterns match sensitive strings (e.g. API keys, bearer tokens) and replace them with `[REDACTED]`.
public final class SessionSnapshotRedactor: @unchecked Sendable {
    public static let shared = SessionSnapshotRedactor()

    private let lock = NSLock()
    private var patternStrings: [String] = []
    private var compiledRegexes: [NSRegularExpression] = []

    public init() {}

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

    /// Adds a user-defined redaction pattern.
    @discardableResult
    public func addPattern(_ pattern: String) throws -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

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

    /// Sets the list of user-defined redaction patterns.
    public func setPatterns(_ patterns: [String]) {
        lock.lock()
        defer { lock.unlock() }
        var validStrings: [String] = []
        var validRegexes: [NSRegularExpression] = []
        for p in patterns {
            let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
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

        var result = text
        for regex in regexes {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: "[REDACTED]"
            )
        }
        return result
    }

    /// Redacts matching sensitive patterns in binary checkpoint data while preserving byte structure and updating CRC32.
    public func redact(checkpoint: Data) -> Data {
        lock.lock()
        let regexes = compiledRegexes
        lock.unlock()

        guard !regexes.isEmpty, checkpoint.count >= 20 else { return checkpoint }

        // Check TKCK magic
        guard checkpoint.prefix(4) == Data("TKCK".utf8) else {
            return checkpoint
        }

        var mutable = checkpoint
        let payloadStart = 20
        let payloadLength = mutable.count - payloadStart
        guard payloadLength > 0 else { return checkpoint }

        // Extract payload as Latin-1 string to allow byte-for-byte in-place character matching
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

                // Overwrite matched bytes in-place with '*' (ASCII 0x2A) preserving length
                for i in 0..<matchLen {
                    modifiedPayload[startOffset + i] = 0x2A
                }
                didModify = true
            }
        }

        if didModify {
            mutable.replaceSubrange(payloadStart..<mutable.count, with: modifiedPayload)
            // Recompute IEEE 802.3 CRC32 of payload bytes and write to bytes 16..<20
            let newCRC = Self.computeCRC32(data: modifiedPayload)
            var littleEndianCRC = newCRC.littleEndian
            withUnsafeBytes(of: &littleEndianCRC) { crcBytes in
                mutable.replaceSubrange(16..<20, with: crcBytes)
            }
        }

        return mutable
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
}
