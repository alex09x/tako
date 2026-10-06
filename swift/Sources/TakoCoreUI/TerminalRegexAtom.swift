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

struct RegexAtom {
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

    func canOverlap(with other: RegexAtom) -> Bool {
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
        case (.shorthand(let s), .charClass(let raw)), (.charClass(let raw), .shorthand(let s)):
            return charClassMatchesShorthand(raw: raw, shorthand: s)
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

    private func parseClassItems(_ content: Substring) -> (singles: Set<Character>, ranges: [(Character, Character)], shorthands: Set<Character>) {
        var singles = Set<Character>()
        var ranges = [(Character, Character)]()
        var shorthands = Set<Character>()

        var chars: [Character] = []
        var isEscaped: [Bool] = []

        var idx = content.startIndex
        while idx < content.endIndex {
            let c = content[idx]
            if c == "\\" {
                let next = content.index(after: idx)
                if next < content.endIndex {
                    let esc = content[next]
                    if "dDsSwW".contains(esc) {
                        shorthands.insert(esc)
                    } else {
                        chars.append(esc)
                        isEscaped.append(true)
                    }
                    idx = content.index(after: next)
                    continue
                }
            }
            chars.append(c)
            isEscaped.append(false)
            idx = content.index(after: idx)
        }

        var i = 0
        while i < chars.count {
            if i + 2 < chars.count && chars[i + 1] == "-" && !isEscaped[i + 1] {
                let start = chars[i]
                let end = chars[i + 2]
                if start <= end {
                    ranges.append((start, end))
                } else {
                    ranges.append((end, start))
                }
                i += 3
            } else {
                singles.insert(chars[i])
                i += 1
            }
        }

        return (singles, ranges, shorthands)
    }

    private func charClassContains(raw: String, char: Character) -> Bool {
        guard raw.count >= 2 else { return true }
        let inner = raw.dropFirst().dropLast()
        let isNegated = inner.hasPrefix("^")
        let content = isNegated ? inner.dropFirst() : inner

        let (singles, ranges, shorthands) = parseClassItems(content)
        var inClass = singles.contains(char) || ranges.contains(where: { $0.0 <= char && char <= $0.1 })
        if !inClass {
            for sh in shorthands {
                if shorthandMatches(sh, char: char) {
                    inClass = true
                    break
                }
            }
        }
        return isNegated ? !inClass : inClass
    }

    private func charClassMatchesShorthand(raw: String, shorthand: Character) -> Bool {
        guard raw.count >= 2 else { return true }
        let inner = raw.dropFirst().dropLast()
        let isNegated = inner.hasPrefix("^")
        let content = isNegated ? inner.dropFirst() : inner

        let (singles, ranges, shorthands) = parseClassItems(content)

        switch shorthand {
        case "s":
            if isNegated {
                if shorthands.contains("s") { return false }
                return true
            } else {
                if shorthands.contains("s") { return true }
                for ws: Character in [" ", "\t", "\r", "\n"] {
                    if singles.contains(ws) || ranges.contains(where: { $0.0 <= ws && ws <= $0.1 }) {
                        return true
                    }
                }
                return false
            }
        case "S":
            if isNegated {
                if shorthands.contains("S") { return false }
                return true
            } else {
                if shorthands.contains("S") || shorthands.contains("w") || shorthands.contains("d") { return true }
                if !singles.isEmpty || !ranges.isEmpty {
                    for c in singles {
                        if !c.isWhitespace { return true }
                    }
                    for r in ranges {
                        if !r.0.isWhitespace || !r.1.isWhitespace { return true }
                    }
                }
                return false
            }
        case "d":
            if isNegated {
                if shorthands.contains("d") || shorthands.contains("w") { return false }
                if ranges.contains(where: { $0.0 <= "0" && "9" <= $0.1 }) { return false }
                return true
            } else {
                if shorthands.contains("d") || shorthands.contains("w") { return true }
                for d: Character in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"] {
                    if singles.contains(d) || ranges.contains(where: { $0.0 <= d && d <= $0.1 }) {
                        return true
                    }
                }
                return false
            }
        case "D":
            if isNegated {
                if shorthands.contains("D") { return false }
                return true
            } else {
                if shorthands.contains("D") || shorthands.contains("s") { return true }
                for c in singles {
                    if !c.isNumber { return true }
                }
                for r in ranges {
                    if !r.0.isNumber || !r.1.isNumber { return true }
                }
                return false
            }
        case "w":
            if isNegated {
                if shorthands.contains("w") { return false }
                return true
            } else {
                if shorthands.contains("w") || shorthands.contains("d") { return true }
                for c in singles {
                    if c.isLetter || c.isNumber || c == "_" { return true }
                }
                for r in ranges {
                    if r.0 <= "z" && "a" <= r.1 { return true }
                    if r.0 <= "Z" && "A" <= r.1 { return true }
                    if r.0 <= "9" && "0" <= r.1 { return true }
                }
                return false
            }
        case "W":
            if isNegated {
                if shorthands.contains("W") { return false }
                return true
            } else {
                if shorthands.contains("W") || shorthands.contains("s") { return true }
                for c in singles {
                    if !(c.isLetter || c.isNumber || c == "_") { return true }
                }
                for r in ranges {
                    if !(r.0.isLetter && r.1.isLetter) && !(r.0.isNumber && r.1.isNumber) { return true }
                }
                return false
            }
        default:
            return true
        }
    }

    private func classesOverlap(_ r1: String, _ r2: String) -> Bool {
        guard r1.count >= 2, r2.count >= 2 else { return true }
        let inner1 = r1.dropFirst().dropLast()
        let inner2 = r2.dropFirst().dropLast()
        let neg1 = inner1.hasPrefix("^")
        let neg2 = inner2.hasPrefix("^")
        let content1 = neg1 ? inner1.dropFirst() : inner1
        let content2 = neg2 ? inner2.dropFirst() : inner2

        let (singles1, ranges1, sh1) = parseClassItems(content1)
        let (singles2, ranges2, sh2) = parseClassItems(content2)

        if !neg1 && !neg2 {
            if !singles1.isDisjoint(with: singles2) { return true }
            for r1 in ranges1 {
                for r2 in ranges2 {
                    if max(r1.0, r2.0) <= min(r1.1, r2.1) { return true }
                }
                for s in singles2 {
                    if r1.0 <= s && s <= r1.1 { return true }
                }
            }
            for r2 in ranges2 {
                for s in singles1 {
                    if r2.0 <= s && s <= r2.1 { return true }
                }
            }
            for s in sh1 {
                if charClassMatchesShorthand(raw: r2, shorthand: s) { return true }
            }
            for s in sh2 {
                if charClassMatchesShorthand(raw: r1, shorthand: s) { return true }
            }
            if sh1.isEmpty && sh2.isEmpty {
                return false
            }
        }
        if (r1.contains("0-9") && !r1.contains("^")) && (r2.contains("a-z") && !r2.contains("0-9") && !r2.contains("^")) {
            return false
        }
        return true
    }
}
