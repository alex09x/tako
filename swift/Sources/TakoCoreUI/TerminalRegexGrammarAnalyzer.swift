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

extension TerminalRegexTrigger {
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

    static func analyzeGrammar(chars: [Character], range: Range<Int>) -> (isSafe: Bool, reason: String?) {
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

    private static func checkAtomSequence(_ atoms: [RegexAtom]) -> (isSafe: Bool, reason: String?) {
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
}
