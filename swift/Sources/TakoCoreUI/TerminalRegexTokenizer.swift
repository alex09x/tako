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
    static func hasTopLevelAlternation(chars: [Character], range: Range<Int>) -> Bool {
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

    static func getTopLevelBranches(chars: [Character], range: Range<Int>) -> [Range<Int>] {
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

    static func isAlternationNullable(chars: [Character], range: Range<Int>) -> Bool {
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

    static func tokenizeSequence(chars: [Character], range: Range<Int>) -> (atoms: [RegexAtom], error: String?) {
        var atoms: [RegexAtom] = []
        var p = range.lowerBound

        while p < range.upperBound {
            let c = chars[p]

            if c == "^" || c == "$" {
                atoms.append(RegexAtom(kind: .anchor, raw: String(c)))
                p += 1
                continue
            }

            if c == "\\" {
                if p + 1 < range.upperBound {
                    let escChar = chars[p + 1]
                    if escChar == "b" || escChar == "B" {
                        atoms.append(RegexAtom(kind: .anchor, raw: String(chars[p...p + 1])))
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
                    atoms.append(RegexAtom(kind: .literal(c), raw: String(c)))
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
                        atoms.append(RegexAtom(kind: .alternation(rawGroup), raw: rawGroup, isBranching: true, isNullable: true))
                    } else if !hasPipe {
                        let innerSub = tokenizeSequence(chars: chars, range: actualInnerStart..<innerEnd)
                        if let err = innerSub.error {
                            return ([], err)
                        }
                        atoms.append(contentsOf: innerSub.atoms)
                    } else {
                        let rawGroup = String(chars[p..<closeP])
                        let isNull = isAlternationNullable(chars: chars, range: actualInnerStart..<innerEnd)
                        atoms.append(RegexAtom(kind: .alternation(rawGroup), raw: rawGroup, isBranching: true, isNullable: isNull))
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

    static func parseQuantifiedAtom(
        chars: [Character],
        nextP: Int,
        range: Range<Int>,
        kind: RegexAtom.Kind,
        raw: String
    ) -> (atom: RegexAtom, nextP: Int) {
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

        return (RegexAtom(kind: kind, raw: raw + qStr, isBranching: isBranching, isNullable: isNullable), p)
    }
}
