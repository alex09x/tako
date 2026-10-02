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

    /// `send`: the text as a paste -- bracketed when the program asked for
    /// that, so a multi-line text arrives whole -- then Enter unless
    /// `enter` is false. `type`: the same without Enter.
    static func send(_ surface: Tako.SurfaceView, text: String, enter: Bool) throws {
        guard !surface.processExited else {
            throw ControlError(.notFound, "the pane's process has exited")
        }
        if !text.isEmpty {
            surface.writeToShell([UInt8](surface.core.encodePaste(text: text)))
        }
        if enter {
            surface.writeToShell([UInt8](surface.core.encodeKey(event: try keyEvent("enter"))))
        }
    }

    static func key(_ surface: Tako.SurfaceView, chord: String) throws {
        let event = try keyEvent(chord)
        guard !surface.processExited else {
            throw ControlError(.notFound, "the pane's process has exited")
        }
        let bytes = surface.core.encodeKey(event: event)
        guard !bytes.isEmpty else {
            throw ControlError(.invalid, "\"\(chord)\" sends nothing in this pane")
        }
        surface.writeToShell([UInt8](bytes))
    }

    /// Largest text returned, in bytes; cut at a character boundary.
    static let maxTextBytes = 4 << 20

    /// The pane's text: history and screen with soft wraps rejoined, its
    /// last `lines` lines when asked for. `truncated` when cut to fit.
    static func read(_ surface: Tako.SurfaceView, lines: Int?) -> [String: JSON] {
        var all = surface.bufferText
        // The screen's blank bottom rows are not text.
        while all.hasSuffix("\n") { all.removeLast() }
        var rows = all.split(separator: "\n", omittingEmptySubsequences: false)
        let totalLines = rows.count
        if let lines, lines >= 0, rows.count > lines {
            rows = Array(rows.suffix(lines))
        }
        var text = rows.joined(separator: "\n")
        var truncated = false
        if text.utf8.count > maxTextBytes {
            // Keep the end -- the newest output -- whole characters only.
            var cut = text.utf8.index(text.utf8.endIndex, offsetBy: -maxTextBytes)
            while cut < text.utf8.endIndex, !text.isValidIndex(cut) { cut = text.utf8.index(after: cut) }
            text = String(text[cut...])
            truncated = true
        }
        return [
            "text": .string(text),
            "lines": .number(Double(min(totalLines, lines ?? totalLines))),
            "totalLines": .number(Double(totalLines)),
            "truncated": .bool(truncated),
        ]
    }
}

private extension String {
    func isValidIndex(_ i: String.Index) -> Bool {
        i.samePosition(in: unicodeScalars) != nil
    }
}
