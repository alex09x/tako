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

extension Session {
    static let demoPrompt = "\u{1b}[1;38;2;244;88;28m❯\u{1b}[0m "

    /// Seed the demo session with something to look at.
    func seedDemo() {
        demoLine.removeAll(keepingCapacity: true)
        demoEscapeState = 0
        demoLastByteWasCarriageReturn = false
        let banner = """
        \u{1b}[1;38;2;244;88;28m❯\u{1b}[0m tail -f api.log\r
        \u{1b}[38;2;138;127;118m12:41:02\u{1b}[0m GET  /health    \u{1b}[38;2;123;216;143m200\u{1b}[0m   3ms\r
        \u{1b}[38;2;138;127;118m12:41:09\u{1b}[0m POST /v1/sync   \u{1b}[38;2;123;216;143m200\u{1b}[0m  41ms\r
        \u{1b}[38;2;138;127;118m12:41:11\u{1b}[0m GET  /v1/user   \u{1b}[38;2;240;198;116m304\u{1b}[0m   2ms\r
        \u{1b}[38;2;138;127;118m12:41:15\u{1b}[0m POST /v1/push   \u{1b}[38;2;213;78;83m500\u{1b}[0m  88ms\r
        \u{1b}[38;2;138;127;118minteractive demo · type help\u{1b}[0m\r
        \u{1b}[1;38;2;244;88;28m❯\u{1b}[0m 
        """
        receive(Data(banner.replacingOccurrences(of: "\n", with: "\r\n").utf8))
    }

    /// A terminal emulator consumes output; it does not interpret a command
    /// line. SSH supplies a real shell on the far end, while the in-process
    /// demo supplies this deliberately small peer. It provides canonical
    /// input echo, Return, Backspace and Ctrl+C semantics without pretending
    /// that iOS can run arbitrary local programs.
    func handleDemoInput(_ data: Data) {
        for byte in data {
            if consumeDemoEscapeByte(byte) {
                demoLastByteWasCarriageReturn = false
                continue
            }

            switch byte {
            case 0x0D: // Return from the software or hardware keyboard.
                finishDemoLine()
                demoLastByteWasCarriageReturn = true

            case 0x0A: // Accept pasted LF, but do not run CRLF twice.
                if !demoLastByteWasCarriageReturn {
                    finishDemoLine()
                }
                demoLastByteWasCarriageReturn = false

            case 0x08, 0x7F: // Backspace / DEL.
                eraseDemoCharacter()
                demoLastByteWasCarriageReturn = false

            case 0x03: // Ctrl+C: cancel the current line and show a prompt.
                demoLine.removeAll(keepingCapacity: true)
                receive(Data("^C\r\n\(Self.demoPrompt)".utf8))
                demoLastByteWasCarriageReturn = false

            case 0x0C: // Ctrl+L: clear while preserving the current line.
                let line = String(data: demoLine, encoding: .utf8) ?? ""
                receive(Data("\u{1b}[2J\u{1b}[H\(Self.demoPrompt)\(line)".utf8))
                demoLastByteWasCarriageReturn = false

            case 0x09: // A visible, editable tab in lieu of shell completion.
                let spaces = Data("    ".utf8)
                demoLine.append(spaces)
                receive(spaces)
                demoLastByteWasCarriageReturn = false

            case 0x20...0xFF:
                demoLine.append(byte)
                receive(Data([byte]))
                demoLastByteWasCarriageReturn = false

            default:
                // Other control bytes have no useful demo-side meaning.
                demoLastByteWasCarriageReturn = false
            }
        }
    }

    /// Consume a terminal escape sequence sent by the extra key row. Arrow
    /// keys do not edit this tiny line discipline yet, but they must not leak
    /// their CSI bytes into the next command either.
    private func consumeDemoEscapeByte(_ byte: UInt8) -> Bool {
        switch demoEscapeState {
        case 0:
            if byte == 0x1B {
                demoEscapeState = 1
                return true
            }
            return false
        case 1:
            if byte == 0x5B || byte == 0x4F { // CSI or SS3.
                demoEscapeState = 2
                return true
            }
            demoEscapeState = 0
            return true
        default:
            if (0x40...0x7E).contains(byte) {
                demoEscapeState = 0
            }
            return true
        }
    }

    private func eraseDemoCharacter() {
        guard !demoLine.isEmpty else { return }
        if let line = String(data: demoLine, encoding: .utf8), !line.isEmpty {
            demoLine = Data(line.dropLast().utf8)
        } else {
            // Keep malformed/incomplete input recoverable one byte at a time.
            demoLine.removeLast()
        }
        receive(Data("\u{08} \u{08}".utf8))
    }

    private func finishDemoLine() {
        let line = String(data: demoLine, encoding: .utf8) ?? ""
        demoLine.removeAll(keepingCapacity: true)
        receive(Data("\r\n".utf8))

        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = trimmed.split(whereSeparator: \Character.isWhitespace).first.map(String.init) ?? ""
        let arguments = trimmed.dropFirst(command.count).trimmingCharacters(in: .whitespaces)

        switch command {
        case "":
            break
        case "ls":
            receive(Data("README.md  \u{1b}[38;2;123;216;143mSources/\u{1b}[0m  Tests/  examples/\r\n".utf8))
        case "pwd":
            receive(Data("/demo\r\n".utf8))
        case "echo":
            receive(Data("\(arguments)\r\n".utf8))
        case "help":
            receive(Data("demo commands: ls, pwd, echo, clear, help\r\n".utf8))
        case "clear":
            receive(Data("\u{1b}[2J\u{1b}[H".utf8))
        default:
            receive(Data("tako-demo: command not found: \(command)\r\n".utf8))
        }

        receive(Data(Self.demoPrompt.utf8))
    }
}
