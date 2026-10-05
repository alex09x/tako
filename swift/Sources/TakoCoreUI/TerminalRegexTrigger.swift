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
#if canImport(AppKit)
import AppKit

/// User-defined passive regex trigger rule for output text highlighting or notifications (E7).
/// Strictly passive: never injects keystrokes, commands, or automated input into the terminal.
public struct TerminalRegexTrigger: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let pattern: String
    public let regex: NSRegularExpression?
    public let action: Action
    public let colorName: String?
    public let color: NSColor?
    public let style: HighlightStyle
    public let notificationTitle: String?
    public let onlyUnfocused: Bool
    public let isDynamic: Bool

    public enum Action: String, Codable, Sendable, CaseIterable {
        case highlight
        case notify
        case both

        public var highlights: Bool { self == .highlight || self == .both }
        public var notifies: Bool { self == .notify || self == .both }
    }

    public enum HighlightStyle: String, Codable, Sendable, CaseIterable {
        case background
        case underline
        case box
        case bold
    }

    /// Validates whether a regex pattern is safe from catastrophic backtracking (ReDoS).
    /// Rejects nested quantifiers (e.g. (a+)+, (a*)*), quantified groups, consecutive quantifiers,
    /// ambiguous overlapping repetitions (e.g. ^a*a*a*a*a*a*a*b$, a*a*, .*.*, \w+\w+), and patterns over 512 chars.
    public static func isSafePattern(_ pattern: String) -> (isSafe: Bool, reason: String?) {
        guard pattern.count <= 512 else {
            return (false, "pattern exceeds maximum allowed length of 512 characters")
        }

        let chars = Array(pattern)
        var i = 0

        // 1. Check for quantified parenthesized groups and consecutive quantifiers
        var depth = 0
        var escaped = false

        while i < chars.count {
            let c = chars[i]
            if escaped {
                escaped = false
                i += 1
                continue
            }
            if c == "\\" {
                escaped = true
                i += 1
                continue
            }

            if c == "(" {
                depth += 1
            } else if c == ")" {
                if depth > 0 {
                    depth -= 1
                    var nextIndex = i + 1
                    while nextIndex < chars.count && chars[nextIndex].isWhitespace {
                        nextIndex += 1
                    }
                    if nextIndex < chars.count {
                        let nextChar = chars[nextIndex]
                        if nextChar == "+" || nextChar == "*" || nextChar == "{" {
                            return (false, "pathological regex: quantified group ')\(nextChar)' causes exponential backtracking")
                        }
                    }
                }
            } else if c == "+" || c == "*" || c == "{" {
                var nextIndex = i + 1
                while nextIndex < chars.count && chars[nextIndex].isWhitespace {
                    nextIndex += 1
                }
                if nextIndex < chars.count {
                    let nextChar = chars[nextIndex]
                    if nextChar == "+" || nextChar == "*" || nextChar == "{" {
                        return (false, "pathological regex: consecutive quantifiers '\(c)\(nextChar)'")
                    }
                }
            }
            i += 1
        }

        // 2. Tokenize and analyze full grammar, recursively unpacking non-quantified groups
        return analyzeGrammar(chars: chars, range: 0..<chars.count)
    }

    private struct Atom {
        enum Kind {
            case literal(Character)
            case dot
            case shorthand(Character) // d, D, s, S, w, W
            case charClass(String)
            case anchor
            case alternation(String)
            case barrier
        }
        let kind: Kind
        let raw: String
        var isBranching: Bool = false
        var isNullable: Bool = false

        func canOverlap(with other: Atom) -> Bool {
            switch (self.kind, other.kind) {
            case (.anchor, _), (_, .anchor):
                return false
            case (.barrier, _), (_, .barrier):
                return false
            case (.dot, _), (_, .dot):
                return true
            case (.literal(let c1), .literal(let c2)):
                return c1 == c2
            case (.literal(let c), .shorthand(let s)), (.shorthand(let s), .literal(let c)):
                return shorthandMatches(s, char: c)
            case (.shorthand(let s1), .shorthand(let s2)):
                return shorthandsOverlap(s1, s2)
            case (.literal(let c), .charClass(let raw)), (.charClass(let raw), .literal(let c)):
                return charClassContains(raw: raw, char: c)
            case (.charClass(let r1), .charClass(let r2)):
                if r1 == r2 { return true }
                return classesOverlap(r1, r2)
            case (.alternation(let r1), .alternation(let r2)):
                return alternationsOverlap(r1, r2)
            case (.alternation(let r), .literal(let c)), (.literal(let c), .alternation(let r)):
                return alternationContains(r, char: c)
            case (.alternation, .dot), (.dot, .alternation):
                return true
            case (.alternation(let r), .shorthand(let s)), (.shorthand(let s), .alternation(let r)):
                return alternationMatchesShorthand(r, shorthand: s)
            case (.alternation, _), (_, .alternation):
                return true
            default:
                return true
            }
        }

        private func alternationsOverlap(_ r1: String, _ r2: String) -> Bool {
            let b1 = extractBranches(r1)
            let b2 = extractBranches(r2)
            for x in b1 {
                for y in b2 {
                    if let c1 = x.first, let c2 = y.first, c1 == c2 {
                        return true
                    }
                    if x.contains(where: { y.contains($0) }) {
                        return true
                    }
                }
            }
            return false
        }

        private func alternationContains(_ r: String, char: Character) -> Bool {
            let branches = extractBranches(r)
            for b in branches {
                if b.contains(char) { return true }
            }
            return false
        }

        private func alternationMatchesShorthand(_ r: String, shorthand: Character) -> Bool {
            let branches = extractBranches(r)
            for b in branches {
                for c in b {
                    if shorthandMatches(shorthand, char: c) { return true }
                }
            }
            return false
        }

        private func extractBranches(_ r: String) -> [String] {
            var s = r
            while s.hasSuffix("?") {
                s.removeLast()
            }
            if s.hasPrefix("(?:") {
                s.removeFirst(3)
            } else if s.hasPrefix("(") {
                s.removeFirst(1)
            }
            if s.hasSuffix(")") {
                s.removeLast(1)
            }
            var branches: [String] = []
            var current = ""
            var depth = 0
            var inClass = false
            var escaped = false
            for ch in s {
                if escaped {
                    current.append(ch)
                    escaped = false
                    continue
                }
                if ch == "\\" {
                    current.append(ch)
                    escaped = true
                    continue
                }
                if ch == "[" && !inClass {
                    inClass = true
                    current.append(ch)
                    continue
                }
                if ch == "]" && inClass {
                    inClass = false
                    current.append(ch)
                    continue
                }
                if !inClass {
                    if ch == "(" {
                        depth += 1
                    } else if ch == ")" {
                        if depth > 0 { depth -= 1 }
                    } else if ch == "|" && depth == 0 {
                        branches.append(current)
                        current = ""
                        continue
                    }
                }
                current.append(ch)
            }
            branches.append(current)
            return branches
        }

        private func shorthandMatches(_ s: Character, char: Character) -> Bool {
            switch s {
            case "d": return char.isNumber
            case "D": return !char.isNumber
            case "s": return char.isWhitespace
            case "S": return !char.isWhitespace
            case "w": return char.isLetter || char.isNumber || char == "_"
            case "W": return !(char.isLetter || char.isNumber || char == "_")
            default: return true
            }
        }

        private func shorthandsOverlap(_ s1: Character, _ s2: Character) -> Bool {
            if s1 == s2 { return true }
            if (s1 == "d" && s2 == "D") || (s1 == "D" && s2 == "d") { return false }
            if (s1 == "s" && s2 == "S") || (s1 == "S" && s2 == "s") { return false }
            if (s1 == "w" && s2 == "W") || (s1 == "W" && s2 == "w") { return false }
            if (s1 == "d" && s2 == "s") || (s1 == "s" && s2 == "d") { return false }
            if (s1 == "w" && s2 == "s") || (s1 == "s" && s2 == "w") { return false }
            return true
        }

        private func charClassContains(raw: String, char: Character) -> Bool {
            guard raw.count >= 2 else { return true }
            let inner = raw.dropFirst().dropLast()
            let isNegated = inner.hasPrefix("^")
            let content = isNegated ? inner.dropFirst() : inner
            var matched = false

            var idx = content.startIndex
            while idx < content.endIndex {
                let c = content[idx]
                let next = content.index(after: idx)
                if next < content.endIndex && content[next] == "-" {
                    let afterHyphen = content.index(after: next)
                    if afterHyphen < content.endIndex {
                        let endChar = content[afterHyphen]
                        if c <= char && char <= endChar {
                            matched = true
                            break
                        }
                        idx = content.index(after: afterHyphen)
                        continue
                    }
                }
                if c == char {
                    matched = true
                    break
                }
                idx = content.index(after: idx)
            }

            return isNegated ? !matched : matched
        }

        private func classesOverlap(_ r1: String, _ r2: String) -> Bool {
            if (r1.contains("0-9") && !r1.contains("^")) && (r2.contains("a-z") && !r2.contains("0-9") && !r2.contains("^")) {
                return false
            }
            return true
        }
    }

    private static func analyzeGrammar(chars: [Character], range: Range<Int>) -> (isSafe: Bool, reason: String?) {
        // Check for top-level '|' alternations within this range
        var branches: [Range<Int>] = []
        var branchStart = range.lowerBound
        var depth = 0
        var esc = false
        var p = range.lowerBound

        while p < range.upperBound {
            let c = chars[p]
            if esc {
                esc = false
            } else if c == "\\" {
                esc = true
            } else if c == "(" {
                depth += 1
            } else if c == ")" {
                if depth > 0 { depth -= 1 }
            } else if c == "[" {
                p += 1
                while p < range.upperBound && chars[p] != "]" {
                    if chars[p] == "\\" { p += 1 }
                    p += 1
                }
            } else if c == "|" && depth == 0 {
                branches.append(branchStart..<p)
                branchStart = p + 1
            }
            p += 1
        }

        if !branches.isEmpty {
            branches.append(branchStart..<range.upperBound)
            for branch in branches {
                let res = analyzeGrammar(chars: chars, range: branch)
                if !res.isSafe { return res }
            }
            return (true, nil)
        }

        let tokenResult = tokenizeSequence(chars: chars, range: range)
        if let err = tokenResult.error {
            return (false, err)
        }
        return checkAtomSequence(tokenResult.atoms)
    }

    private static func hasTopLevelAlternation(chars: [Character], range: Range<Int>) -> Bool {
        var depth = 0
        var esc = false
        var p = range.lowerBound
        while p < range.upperBound {
            let c = chars[p]
            if esc {
                esc = false
            } else if c == "\\" {
                esc = true
            } else if c == "(" {
                depth += 1
            } else if c == ")" {
                if depth > 0 { depth -= 1 }
            } else if c == "[" {
                p += 1
                while p < range.upperBound && chars[p] != "]" {
                    if chars[p] == "\\" { p += 1 }
                    p += 1
                }
            } else if c == "|" && depth == 0 {
                return true
            }
            p += 1
        }
        return false
    }

    private static func getTopLevelBranches(chars: [Character], range: Range<Int>) -> [Range<Int>] {
        var branches: [Range<Int>] = []
        var branchStart = range.lowerBound
        var depth = 0
        var p = range.lowerBound
        while p < range.upperBound {
            let c = chars[p]
            if c == "\\" {
                p += 2
                continue
            }
            if c == "(" {
                depth += 1
            } else if c == ")" {
                if depth > 0 { depth -= 1 }
            } else if c == "[" {
                p += 1
                while p < range.upperBound && chars[p] != "]" {
                    if chars[p] == "\\" { p += 1 }
                    p += 1
                }
            } else if c == "|" && depth == 0 {
                branches.append(branchStart..<p)
                branchStart = p + 1
            }
            p += 1
        }
        branches.append(branchStart..<range.upperBound)
        return branches
    }

    private static func isAlternationNullable(chars: [Character], range: Range<Int>) -> Bool {
        let branchRanges = getTopLevelBranches(chars: chars, range: range)
        for br in branchRanges {
            if br.isEmpty {
                return true
            }
            let sub = tokenizeSequence(chars: chars, range: br)
            if sub.error == nil && sub.atoms.allSatisfy({ $0.isNullable }) {
                return true
            }
        }
        return false
    }

    private static func tokenizeSequence(chars: [Character], range: Range<Int>) -> (atoms: [Atom], error: String?) {
        var atoms: [Atom] = []
        var p = range.lowerBound

        while p < range.upperBound {
            let c = chars[p]

            if c == "^" || c == "$" {
                atoms.append(Atom(kind: .anchor, raw: String(c)))
                p += 1
                continue
            }

            if c == "\\" {
                if p + 1 < range.upperBound {
                    let escChar = chars[p + 1]
                    if escChar == "b" || escChar == "B" {
                        atoms.append(Atom(kind: .anchor, raw: String(chars[p...p + 1])))
                    } else if "dDsSwW".contains(escChar) {
                        let (atom, nextP) = parseQuantifiedAtom(chars: chars, nextP: p + 2, range: range, kind: .shorthand(escChar), raw: String(chars[p...p + 1]))
                        atoms.append(atom)
                        p = nextP
                        continue
                    } else {
                        let (atom, nextP) = parseQuantifiedAtom(chars: chars, nextP: p + 2, range: range, kind: .literal(escChar), raw: String(chars[p...p + 1]))
                        atoms.append(atom)
                        p = nextP
                        continue
                    }
                    p += 2
                    continue
                } else {
                    atoms.append(Atom(kind: .literal(c), raw: String(c)))
                    p += 1
                    continue
                }
            }

            if c == "[" {
                var closeP = p + 1
                if closeP < range.upperBound && chars[closeP] == "^" { closeP += 1 }
                if closeP < range.upperBound && chars[closeP] == "]" { closeP += 1 }
                while closeP < range.upperBound && chars[closeP] != "]" {
                    if chars[closeP] == "\\" { closeP += 1 }
                    closeP += 1
                }
                let end = min(closeP + 1, range.upperBound)
                let rawClass = String(chars[p..<end])
                let (atom, nextP) = parseQuantifiedAtom(chars: chars, nextP: end, range: range, kind: .charClass(rawClass), raw: rawClass)
                atoms.append(atom)
                p = nextP
                continue
            }

            if c == "(" {
                var grpDepth = 1
                var closeP = p + 1
                var grpEsc = false
                while closeP < range.upperBound && grpDepth > 0 {
                    let gc = chars[closeP]
                    if grpEsc {
                        grpEsc = false
                    } else if gc == "\\" {
                        grpEsc = true
                    } else if gc == "(" {
                        grpDepth += 1
                    } else if gc == ")" {
                        grpDepth -= 1
                    }
                    closeP += 1
                }

                var isQuantifiedWithQuestion = false
                var endP = closeP
                if endP < range.upperBound && chars[endP] == "?" {
                    isQuantifiedWithQuestion = true
                    endP += 1
                    if endP < range.upperBound && chars[endP] == "?" {
                        endP += 1
                    }
                }
                if endP < range.upperBound && (chars[endP] == "+" || chars[endP] == "*" || chars[endP] == "{") {
                    return ([], "pathological regex: quantified group ')\(chars[endP])' causes exponential backtracking")
                }

                let innerStart = p + 1
                let innerEnd = closeP - 1
                if innerStart <= innerEnd {
                    var actualInnerStart = innerStart
                    if actualInnerStart + 1 <= innerEnd && chars[actualInnerStart] == "?" && chars[actualInnerStart + 1] == ":" {
                        actualInnerStart += 2
                    }

                    // Recursively validate inner group grammar
                    let innerRes = analyzeGrammar(chars: chars, range: actualInnerStart..<innerEnd)
                    if !innerRes.isSafe {
                        return ([], innerRes.reason)
                    }

                    let hasPipe = hasTopLevelAlternation(chars: chars, range: actualInnerStart..<innerEnd)
                    if isQuantifiedWithQuestion {
                        let innerSub = tokenizeSequence(chars: chars, range: actualInnerStart..<innerEnd)
                        if let err = innerSub.error {
                            return ([], err)
                        }
                        if innerSub.atoms.contains(where: { $0.isBranching }) {
                            return ([], "pathological regex: nested branching in optional group")
                        }
                        let rawGroup = String(chars[p..<endP])
                        atoms.append(Atom(kind: .alternation(rawGroup), raw: rawGroup, isBranching: true, isNullable: true))
                    } else if !hasPipe {
                        let innerSub = tokenizeSequence(chars: chars, range: actualInnerStart..<innerEnd)
                        if let err = innerSub.error {
                            return ([], err)
                        }
                        atoms.append(contentsOf: innerSub.atoms)
                    } else {
                        let rawGroup = String(chars[p..<closeP])
                        let isNull = isAlternationNullable(chars: chars, range: actualInnerStart..<innerEnd)
                        atoms.append(Atom(kind: .alternation(rawGroup), raw: rawGroup, isBranching: true, isNullable: isNull))
                    }
                }

                p = endP
                continue
            }

            if c == "." {
                let (atom, nextP) = parseQuantifiedAtom(chars: chars, nextP: p + 1, range: range, kind: .dot, raw: ".")
                atoms.append(atom)
                p = nextP
                continue
            }

            let (atom, nextP) = parseQuantifiedAtom(chars: chars, nextP: p + 1, range: range, kind: .literal(c), raw: String(c))
            atoms.append(atom)
            p = nextP
        }

        return (atoms, nil)
    }

    private static func parseQuantifiedAtom(
        chars: [Character],
        nextP: Int,
        range: Range<Int>,
        kind: Atom.Kind,
        raw: String
    ) -> (atom: Atom, nextP: Int) {
        var p = nextP
        var isBranching = false
        var isNullable = false
        var qStr = ""

        if p < range.upperBound {
            let qc = chars[p]
            if qc == "*" {
                isBranching = true
                isNullable = true
                qStr = "*"
                p += 1
            } else if qc == "+" {
                isBranching = true
                isNullable = false
                qStr = "+"
                p += 1
            } else if qc == "?" {
                isBranching = true
                isNullable = true
                qStr = "?"
                p += 1
            } else if qc == "{" {
                var braceEnd = p + 1
                while braceEnd < range.upperBound && chars[braceEnd] != "}" {
                    braceEnd += 1
                }
                if braceEnd < range.upperBound {
                    let inner = String(chars[(p + 1)..<braceEnd])
                    qStr = String(chars[p...braceEnd])
                    p = braceEnd + 1
                    isBranching = true
                    if inner.contains(",") {
                        let parts = inner.split(separator: ",", omittingEmptySubsequences: false)
                        if let first = parts.first, let minVal = Int(first.trimmingCharacters(in: .whitespaces)), minVal == 0 {
                            isNullable = true
                        }
                    }
                }
            }

            if p < range.upperBound && chars[p] == "?" {
                p += 1
            }
        }

        return (Atom(kind: kind, raw: raw + qStr, isBranching: isBranching, isNullable: isNullable), p)
    }

    private static func checkAtomSequence(_ atoms: [Atom]) -> (isSafe: Bool, reason: String?) {
        var branchingCount = 0
        for atom in atoms where atom.isBranching {
            branchingCount += 1
        }
        if branchingCount > 6 {
            return (false, "pattern exceeds maximum allowed branching constructs (6)")
        }

        for i in 0..<atoms.count {
            let atom1 = atoms[i]
            guard atom1.isBranching else { continue }

            for j in (i + 1)..<atoms.count {
                let atom2 = atoms[j]
                if atom2.isBranching {
                    if atom1.canOverlap(with: atom2) {
                        return (false, "pathological regex: ambiguous overlapping branching atoms '\(atom1.raw)' and '\(atom2.raw)'")
                    }
                    if !atom2.isNullable {
                        break
                    }
                } else {
                    if !atom2.isNullable && !atom1.canOverlap(with: atom2) {
                        break
                    }
                }
            }
        }

        return (true, nil)
    }

    public init?(
        id: UUID = UUID(),
        pattern: String,
        action: Action = .highlight,
        colorName: String? = nil,
        color: NSColor? = nil,
        style: HighlightStyle = .background,
        notificationTitle: String? = nil,
        onlyUnfocused: Bool = true,
        isDynamic: Bool = false
    ) {
        guard Self.isSafePattern(pattern).isSafe,
              let compiled = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        self.id = id
        self.pattern = pattern
        self.regex = compiled
        self.action = action
        self.colorName = colorName
        let resolved = color ?? colorName.flatMap(Self.resolveColor(named:))
        self.color = resolved ?? .systemYellow
        self.style = style
        self.notificationTitle = notificationTitle
        self.onlyUnfocused = onlyUnfocused
        self.isDynamic = isDynamic
    }

    public static func == (lhs: TerminalRegexTrigger, rhs: TerminalRegexTrigger) -> Bool {
        lhs.id == rhs.id &&
        lhs.pattern == rhs.pattern &&
        lhs.action == rhs.action &&
        lhs.colorName == rhs.colorName &&
        lhs.style == rhs.style &&
        lhs.notificationTitle == rhs.notificationTitle &&
        lhs.onlyUnfocused == rhs.onlyUnfocused &&
        lhs.isDynamic == rhs.isDynamic
    }

    /// Resolves a color name or hex code to an NSColor.
    public static func resolveColor(named name: String) -> NSColor? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch clean {
        case "red": return .systemRed
        case "green": return .systemGreen
        case "blue": return .systemBlue
        case "yellow": return .systemYellow
        case "orange": return .systemOrange
        case "purple": return .systemPurple
        case "magenta", "pink": return .systemPink
        case "cyan", "teal": return .systemTeal
        case "white": return .white
        case "gray", "grey": return .systemGray
        default:
            if let cg = TerminalTheme.parseColor(clean) {
                return NSColor(cgColor: cg)
            }
            return nil
        }
    }

    /// Parses a configuration line into a TerminalRegexTrigger.
    /// Supported formats:
    /// 1. `<pattern> = <action>[:<color>[:<style>[:<title>]]]`
    /// 2. `<pattern>` (defaults to highlight:yellow:background)
    public static func parse(line: String) -> TerminalRegexTrigger? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        let pattern: String
        let specPart: String?

        if let eqIndex = trimmed.firstIndex(of: "=") {
            pattern = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            specPart = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            pattern = trimmed
            specPart = nil
        }

        guard !pattern.isEmpty else { return nil }

        var action: Action = .highlight
        var colorName: String? = "yellow"
        var style: HighlightStyle = .background
        var title: String? = nil

        if let spec = specPart, !spec.isEmpty {
            let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            if let first = parts.first, !first.isEmpty {
                action = Action(rawValue: first.lowercased()) ?? .highlight
            }
            if parts.count > 1, !parts[1].isEmpty {
                colorName = parts[1]
            }
            if parts.count > 2, !parts[2].isEmpty {
                style = HighlightStyle(rawValue: parts[2].lowercased()) ?? .background
            }
            if parts.count > 3, !parts[3].isEmpty {
                title = parts[3]
            }
        }

        return TerminalRegexTrigger(
            pattern: pattern,
            action: action,
            colorName: colorName,
            style: style,
            notificationTitle: title,
            onlyUnfocused: true,
            isDynamic: false
        )
    }
}

public extension Notification.Name {
    static let passiveTriggersDidChange = Notification.Name("passiveTriggersDidChange")
}
#endif
