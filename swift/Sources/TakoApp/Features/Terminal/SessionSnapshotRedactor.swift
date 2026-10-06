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
        return TerminalRegexTrigger.isSafePattern(pattern).isSafe
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

            var windowEnd = line.index(currentIdx, offsetBy: chunkSize + carryWindow, limitedBy: line.endIndex) ?? line.endIndex
            var windowStr = String(line[currentIdx..<windowEnd])
            let maxExpandedWindow = 32768

            // If a match reaches the end of a non-terminal window, expand window to establish match completion.
            // If match completion cannot be established within the expansion limit, fail closed rather than
            // advancing past a partial match and leaking its tail.
            while windowEnd < line.endIndex {
                if Date() >= deadline {
                    chunkedLine.append("[REDACTED]")
                    return (chunkedLine, true)
                }

                var matchReachesEnd = false
                for regex in regexes {
                    let nsRange = NSRange(windowStr.startIndex..<windowStr.endIndex, in: windowStr)
                    let matches = regex.matches(in: windowStr, options: [], range: nsRange)
                    for match in matches {
                        if let range = Range(match.range, in: windowStr), range.upperBound == windowStr.endIndex {
                            matchReachesEnd = true
                            break
                        }
                    }
                    if matchReachesEnd { break }
                }

                if !matchReachesEnd {
                    // Match completion is established: no match touches the window end boundary
                    break
                }

                // If window already reached the max expansion limit, stop expanding
                let currentLen = windowStr.count
                if currentLen >= maxExpandedWindow {
                    break
                }

                // Expand window to find completion of the match
                let expandDistance = min(4096, maxExpandedWindow - currentLen)
                guard expandDistance > 0 else { break }
                let nextEnd = line.index(windowEnd, offsetBy: expandDistance, limitedBy: line.endIndex) ?? line.endIndex
                guard nextEnd > windowEnd else { break }
                windowEnd = nextEnd
                windowStr = String(line[currentIdx..<windowEnd])
            }

            // If the window is still truncated (not end of line) and a match still touches windowStr.endIndex,
            // we cannot establish match completion without exceeding expansion bounds.
            // Fail closed immediately so we never advance past a truncated match or leak its tail.
            if windowEnd < line.endIndex {
                var stillReachesEnd = false
                for regex in regexes {
                    let nsRange = NSRange(windowStr.startIndex..<windowStr.endIndex, in: windowStr)
                    let matches = regex.matches(in: windowStr, options: [], range: nsRange)
                    if matches.contains(where: { Range($0.range, in: windowStr)?.upperBound == windowStr.endIndex }) {
                        stillReachesEnd = true
                        break
                    }
                }
                if stillReachesEnd {
                    chunkedLine.append("[REDACTED]")
                    return (chunkedLine, true)
                }
            }

            let isLastChunk = (windowEnd == line.endIndex)

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
        var crcLE = Self.computeCRC32(data: [UInt8](newPayload)).littleEndian
        withUnsafeBytes(of: &crcLE) { result.append(contentsOf: $0) }
        result.append(newPayload)
        return result
    }

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
            var crcLE = Self.computeCRC32(data: modifiedPayload).littleEndian
            withUnsafeBytes(of: &crcLE) { mutable.replaceSubrange(16..<20, with: $0) }
        }
        return mutable
    }
}
