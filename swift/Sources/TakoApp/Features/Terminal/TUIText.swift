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

/// Text for a terminal-style card: lines of styled runs, wrapped to a width
/// in cells.
enum TUIText {
    struct Run: Equatable {
        enum Kind { case plain, bold, heading, bullet, code, link, muted }
        var text: String
        var kind: Kind
    }

    struct Line: Equatable {
        var indent = 0
        var runs: [Run]
        var width: Int { indent + runs.reduce(0) { $0 + $1.text.count } }
    }

    /// `text`, wrapped at word boundaries.
    static func plain(_ text: String, width: Int) -> [Line] {
        text.components(separatedBy: "\n").flatMap { wrap([Run(text: $0, kind: .plain)], width: width) }
    }

    /// Release notes in the Markdown GitHub keeps: `##` headings, `-`
    /// bullets, `**bold**`, `` `code` `` and `[links](url)`. At most
    /// `maxLines`, then a line saying where the rest is.
    static func markdown(_ text: String, width: Int, maxLines: Int) -> [Line] {
        var lines: [Line] = []
        for raw in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if let last = lines.last, !last.runs.isEmpty { lines.append(Line(runs: [])) }
            } else if line.hasPrefix("#") {
                let heading = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                lines.append(Line(runs: [Run(text: heading, kind: .heading)]))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let body = wrap(inline(String(line.dropFirst(2))), width: width - 2)
                for (index, wrapped) in body.enumerated() {
                    lines.append(index == 0
                        ? Line(runs: [Run(text: "• ", kind: .bullet)] + wrapped.runs)
                        : Line(indent: 2, runs: wrapped.runs))
                }
            } else {
                lines += wrap(inline(line), width: width)
            }
        }
        while lines.last?.runs.isEmpty == true { lines.removeLast() }
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines - 1))
            lines.append(Line(runs: [Run(text: "… the full notes are on GitHub", kind: .muted)]))
        }
        return lines
    }

    /// One line of Markdown into runs.
    static func inline(_ text: String) -> [Run] {
        var runs: [Run] = []
        var rest = Substring(text)
        func plain(_ s: Substring) { if !s.isEmpty { runs.append(Run(text: String(s), kind: .plain)) } }
        while !rest.isEmpty {
            if rest.hasPrefix("**"), let end = rest.dropFirst(2).range(of: "**") {
                runs.append(Run(text: String(rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound]), kind: .bold))
                rest = rest[end.upperBound...]
            } else if rest.hasPrefix("`"), let end = rest.dropFirst().firstIndex(of: "`") {
                runs.append(Run(text: String(rest[rest.index(after: rest.startIndex)..<end]), kind: .code))
                rest = rest[rest.index(after: end)...]
            } else if rest.hasPrefix("["), let close = rest.range(of: "]("),
                      let end = rest[close.upperBound...].firstIndex(of: ")") {
                runs.append(Run(text: String(rest[rest.index(after: rest.startIndex)..<close.lowerBound]), kind: .link))
                rest = rest[rest.index(after: end)...]
            } else {
                let next = rest.dropFirst().firstIndex { "*`[".contains($0) } ?? rest.endIndex
                plain(rest[rest.startIndex..<next])
                rest = rest[next...]
            }
        }
        // Neighbouring plain runs are one run.
        return runs.reduce(into: []) { merged, run in
            if run.kind == .plain, merged.last?.kind == .plain { merged[merged.count - 1].text += run.text } else { merged.append(run) }
        }
    }

    /// Runs wrapped at spaces to `width` cells; a word longer than a line is
    /// split across lines.
    static func wrap(_ runs: [Run], width: Int) -> [Line] {
        var lines: [Line] = []
        var current: [Run] = []
        var used = 0
        func push(_ text: String, _ kind: Run.Kind) {
            if let last = current.last, last.kind == kind { current[current.count - 1].text += text } else { current.append(Run(text: text, kind: kind)) }
            used += text.count
        }
        for run in runs {
            // Words with the space before them, so a line never starts with one.
            var words = run.text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            if words.isEmpty { words = [""] }
            for (index, word) in words.enumerated() {
                let lead = index > 0 ? " " : ""
                if used > 0, used + lead.count + word.count > width {
                    lines.append(Line(runs: current))
                    current = []
                    used = 0
                } else if used > 0 || !lead.isEmpty {
                    push(lead, run.kind)
                }
                // A word longer than a line goes on in width-sized pieces,
                // each on a line of its own: nothing is dropped.
                var rest = Substring(word)
                while rest.count > max(width - used, 1) {
                    let room = max(width - used, 1)
                    push(String(rest.prefix(room)), run.kind)
                    rest = rest.dropFirst(room)
                    lines.append(Line(runs: current))
                    current = []
                    used = 0
                }
                push(String(rest), run.kind)
            }
        }
        lines.append(Line(runs: current))
        return lines
    }
}
