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

/// Typing into a pane and reading it back, for `takoctl send|type|key|text`.
@MainActor
enum ControlInput {
    /// A key chord as takoctl writes it: `enter`, `f5`, `ctrl+c`,
    /// `ctrl+shift+t`, `alt+left`. Modifiers are `ctrl`, `shift`, `alt`
    /// (also `option`) and `cmd` (also `super`); the key is a named key or
    /// one character.
    static func keyEvent(_ chord: String) throws -> FfiKeyEvent {
        let parts = chord.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.last, !name.isEmpty else {
            throw ControlError(.invalid, "no key in \"\(chord)\"")
        }
        var shift = false, alt = false, ctrl = false, superKey = false
        for mod in parts.dropLast() {
            switch mod {
            case "ctrl", "control": ctrl = true
            case "shift": shift = true
            case "alt", "option", "opt": alt = true
            case "cmd", "command", "super": superKey = true
            default: throw ControlError(.invalid, "unknown modifier \"\(mod)\" in \"\(chord)\"")
            }
        }
        let named: [String: FfiKey] = [
            "enter": .enter, "return": .enter, "tab": .tab, "backspace": .backspace,
            "escape": .escape, "esc": .escape, "space": .space,
            "up": .up, "down": .down, "left": .left, "right": .right,
            "home": .home, "end": .end, "pageup": .pageUp, "pagedown": .pageDown,
            "insert": .insert, "delete": .delete,
            "f1": .f1, "f2": .f2, "f3": .f3, "f4": .f4, "f5": .f5, "f6": .f6,
            "f7": .f7, "f8": .f8, "f9": .f9, "f10": .f10, "f11": .f11, "f12": .f12,
        ]
        let key: FfiKey
        var text = "", base = ""
        if let k = named[name] {
            key = k
        } else if name.count == 1, let c = name.first, c.isASCII, !c.isWhitespace {
            key = .character
            base = String(c)
            text = shift ? base.uppercased() : base
        } else {
            throw ControlError(.invalid, "unknown key \"\(name)\"")
        }
        return FfiKeyEvent(
            key: key, text: text, physicalText: base, unshiftedText: base,
            shift: shift, alt: alt, ctrl: ctrl, superKey: superKey,
            press: true, repeat: false, composing: false)
    }

    /// Text to send must be text: a NUL in it is refused, not truncated.
    static func text(_ args: [String: JSON], _ key: String = "text") throws -> String {
        guard let text = args[key]?.string else {
            throw ControlError(.invalid, "\"\(key)\" is missing or not a string")
        }
        guard !text.contains("\u{0}") else {
            throw ControlError(.invalid, "\"\(key)\" contains a NUL")
        }
        return text
    }

    /// The pane's current process, live: input for a pane whose process
    /// ended, or that is waiting on its session, is refused rather than
    /// dropped -- and never takes the keyboard's retry path.
    static func livePTY(_ surface: Tako.SurfaceView) throws -> PTY {
        guard let pty = surface.pty, pty.alive else {
            throw ControlError(.notFound, "the pane has no running process")
        }
        return pty
    }

    /// `send`: the text as a paste -- bracketed when the program asked for
    /// that, so a multi-line text arrives whole -- then Enter unless
    /// `enter` is false. `type`: the same without Enter. One item for the
    /// writer, so paste and Enter stay together and in order.
    static func send(_ surface: Tako.SurfaceView, text: String, enter: Bool) throws {
        let pty = try livePTY(surface)
        var bytes = text.isEmpty ? [] : [UInt8](surface.core.encodePaste(text: text))
        if enter {
            bytes += [UInt8](surface.core.encodeKey(event: try keyEvent("enter")))
        }
        try ControlWriter.writer(for: pty).enqueue(bytes)
    }

    static func key(_ surface: Tako.SurfaceView, chord: String) throws {
        let event = try keyEvent(chord)
        let pty = try livePTY(surface)
        let bytes = [UInt8](surface.core.encodeKey(event: event))
        guard !bytes.isEmpty else {
            throw ControlError(.invalid, "\"\(chord)\" sends nothing in this pane")
        }
        try ControlWriter.writer(for: pty).enqueue(bytes)
    }

    /// Largest text returned, in bytes.
    static let maxTextBytes: UInt32 = 4 << 20
    /// Most lines one `text` reads.
    static let maxLines = 1_000_000

    /// `lines` from a request: a whole number from 0 to `maxLines`; absent
    /// means all of them, up to the limits.
    static func lines(_ args: [String: JSON]) throws -> Int {
        switch args["lines"] {
        case nil, .null?:
            return maxLines
        case .number(let n)?:
            guard n.isFinite, let lines = Int(exactly: n), (0...maxLines).contains(lines) else {
                throw ControlError(.invalid, "\"lines\" must be a whole number from 0 to \(maxLines)")
            }
            return lines
        default:
            throw ControlError(.invalid, "\"lines\" is not a number")
        }
    }

    private struct CellStyleKey: Hashable, Sendable {
        let fgR: UInt8
        let fgG: UInt8
        let fgB: UInt8
        let bgR: UInt8
        let bgG: UInt8
        let bgB: UInt8
        let bold: Bool
        let dim: Bool
        let italic: Bool
        let underline: Bool
        let blink: Bool
        let reverse: Bool
        let hidden: Bool
        let strikethrough: Bool
    }

    nonisolated private static func isBlankCell(_ cell: FfiCell) -> Bool {
        (cell.ch == 0 || cell.ch == 32) &&
        !cell.bold && !cell.dim && !cell.italic &&
        !cell.underline && !cell.blink && !cell.reverse &&
        !cell.hidden && !cell.strikethrough &&
        (cell.grapheme == nil || cell.grapheme!.isEmpty)
    }

    /// The pane's last lines, read off the main thread from the end of its
    /// history or viewport. When `styled` is true, cells are serialized with ANSI SGR escape codes.
    nonisolated static func read(_ core: TakoCore, lines: Int, styled: Bool = false) -> [String: JSON] {
        if !styled {
            let tail = core.textTail(maxLines: UInt32(lines), maxBytes: maxTextBytes)
            return [
                "text": .string(tail.text),
                "lines": .number(Double(tail.lines)),
                "truncated": .bool(tail.truncated),
                "more": .bool(tail.more),
            ]
        }

        let totalRows = Int(core.rows())
        var allFormattedRows: [String] = []
        for r in 0..<totalRows {
            let cells = core.viewportRow(row: UInt32(r))
            allFormattedRows.append(formatRowAnsi(cells))
        }

        var lastContentRow = totalRows - 1
        while lastContentRow > 0 && allFormattedRows[lastContentRow].isEmpty {
            lastContentRow -= 1
        }

        let endRow = allFormattedRows[lastContentRow].isEmpty ? 0 : lastContentRow + 1
        let startRow = max(0, endRow - lines)
        let resultLines = Array(allFormattedRows[startRow..<endRow])

        let text = resultLines.joined(separator: "\n")
        return [
            "text": .string(text),
            "lines": .number(Double(resultLines.count)),
            "truncated": .bool(false),
            "more": .bool(startRow > 0),
        ]
    }

    /// Formats a single row of cells into a string containing ANSI SGR styling codes.
    nonisolated static func formatRowAnsi(_ cells: [FfiCell]) -> String {
        var lastCol = cells.count - 1
        while lastCol >= 0 && isBlankCell(cells[lastCol]) {
            lastCol -= 1
        }
        if lastCol < 0 {
            return ""
        }
        let activeCells = cells[0...lastCol]

        var out = ""
        var currentStyle: CellStyleKey? = nil

        for cell in activeCells {
            // Wide spacer tail (covered by wide glyph)
            if cell.ch == 0 && !cell.wide && cell.grapheme == nil {
                continue
            }

            let style = CellStyleKey(
                fgR: cell.fgR, fgG: cell.fgG, fgB: cell.fgB,
                bgR: cell.bgR, bgG: cell.bgG, bgB: cell.bgB,
                bold: cell.bold, dim: cell.dim, italic: cell.italic,
                underline: cell.underline, blink: cell.blink,
                reverse: cell.reverse, hidden: cell.hidden,
                strikethrough: cell.strikethrough
            )

            let chStr: String
            if let g = cell.grapheme, !g.isEmpty {
                chStr = g
            } else if let scalar = UnicodeScalar(cell.ch) {
                chStr = String(scalar)
            } else {
                chStr = " "
            }

            if style != currentStyle {
                var sgrParts: [String] = ["0"] // always reset first
                if style.bold { sgrParts.append("1") }
                if style.dim { sgrParts.append("2") }
                if style.italic { sgrParts.append("3") }
                if style.underline { sgrParts.append("4") }
                if style.blink { sgrParts.append("5") }
                if style.reverse { sgrParts.append("7") }
                if style.hidden { sgrParts.append("8") }
                if style.strikethrough { sgrParts.append("9") }
                sgrParts.append("38;2;\(style.fgR);\(style.fgG);\(style.fgB)")
                sgrParts.append("48;2;\(style.bgR);\(style.bgG);\(style.bgB)")

                out += "\u{1b}[\(sgrParts.joined(separator: ";"))m"
                currentStyle = style
            }

            out += chStr
        }

        if currentStyle != nil {
            out += "\u{1b}[0m"
        }

        return out
    }
}

/// Input for one pane's process, written off the main thread in order.
///
/// An item -- one send, one key -- is admitted whole or refused (`busy`)
/// when the bytes still waiting would pass the cap; a program that stops
/// reading blocks this writer's own queue, never the app. Partial writes and
/// interruptions are carried on; a write error (the process is gone) drops
/// what is left.
final class ControlWriter: @unchecked Sendable {
    static let maxPending = 1 << 20

    private let fd: Int32
    private let queue = DispatchQueue(label: "tako.control.input")
    private let lock = NSLock()
    private var pending = 0   // under lock

    /// Its own duplicate of the pty's master: the pane closing its master
    /// can never leave this writing to a number that now names another file.
    private init?(master: Int32) {
        let own = dup(master)
        guard own >= 0 else { return nil }
        _ = fcntl(own, F_SETFD, FD_CLOEXEC)
        fd = own
    }

    /// For tests: a writer on a descriptor of their own (duplicated).
    static func onDescriptor(_ fd: Int32) -> ControlWriter? { ControlWriter(master: fd) }

    deinit { close(fd) }

    private struct Entry {
        weak var pty: PTY?
        let writer: ControlWriter
    }
    @MainActor private static var writers: [ObjectIdentifier: Entry] = [:]

    /// One writer per process, made the first time it is needed; writers of
    /// processes that have ended are let go.
    @MainActor static func writer(for pty: PTY) throws -> ControlWriter {
        writers = writers.filter { $0.value.pty?.alive == true }
        let key = ObjectIdentifier(pty)
        if let entry = writers[key], entry.pty === pty { return entry.writer }
        guard let made = ControlWriter(master: pty.master) else {
            throw ControlError(.internalError, "cannot write to the pane: \(errno)")
        }
        writers[key] = Entry(pty: pty, writer: made)
        return made
    }

    func enqueue(_ bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        let admitted = lock.withLock {
            guard pending + bytes.count <= Self.maxPending else { return false }
            pending += bytes.count
            return true
        }
        guard admitted else {
            throw ControlError(.busy, "the pane's program is not taking input; \(Self.maxPending) bytes already wait")
        }
        queue.async { [self] in
            var offset = 0
            while offset < bytes.count {
                let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
                if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { break }
            }
            lock.withLock { pending -= bytes.count }
        }
    }

    var pendingBytes: Int { lock.withLock { pending } }
}

private extension String {
    func isValidIndex(_ i: String.Index) -> Bool {
        i.samePosition(in: unicodeScalars) != nil
    }
}
