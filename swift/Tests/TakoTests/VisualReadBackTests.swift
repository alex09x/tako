/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation
import Testing
@testable import Tako

@MainActor
struct VisualReadBackTests {
    private let pngHeader: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    @Test func textStyledIncludesAnsiSgrCodes() {
        let core = TakoCore(cols: 40, rows: 6)
        // Feed colored and styled text
        core.feed(bytes: Data("\u{1b}[31mRedText\u{1b}[0m \u{1b}[1;32mBoldGreen\u{1b}[0m\r\n".utf8))

        // Unstyled read does not contain escape codes
        let plain = ControlInput.read(core, lines: 3, styled: false)
        guard case .string(let plainText)? = plain["text"] else {
            Issue.record("missing plain text")
            return
        }
        #expect(!plainText.contains("\u{1b}["))
        #expect(plainText.contains("RedText BoldGreen"))

        // Styled read contains ANSI SGR escape codes
        let styled = ControlInput.read(core, lines: 3, styled: true)
        guard case .string(let styledText)? = styled["text"] else {
            Issue.record("missing styled text")
            return
        }
        #expect(styledText.contains("\u{1b}["))
        #expect(styledText.contains("38;2;")) // 24-bit RGB foreground
        #expect(styledText.contains("RedText"))
        #expect(styledText.contains("BoldGreen"))
    }

    @Test func screenshotReturnsValidPngImage() throws {
        let oldMode = ControlCommands.mode
        ControlCommands.mode = .on
        defer { ControlCommands.mode = oldMode }

        let oldGlobal = SecureInput.shared.global
        SecureInput.shared.global = false
        defer { SecureInput.shared.global = oldGlobal }

        let app = Tako.App()
        let surface = Tako.SurfaceView(app, baseConfig: .init(), uuid: UUID())
        surface.currentProcess = nil
        let controller = TerminalController(app)
        let pane = ControlCommands.Pane(surface: surface, windowID: "w1", tabID: "t1", controller: controller)

        surface.core.feed(bytes: Data("\u{1b}[34mBlue terminal text\u{1b}[0m\r\n".utf8))

        // Direct capture
        let (pngData, width, height) = try ControlCommands.captureScreenshot(surface)
        #expect(width > 0)
        #expect(height > 0)
        #expect(pngData.count > pngHeader.count)
        #expect(Array(pngData.prefix(pngHeader.count)) == pngHeader)

        // Control command execution
        let grant = ControlGrantStore.shared.issueGrant(client: "visual-test", scopes: [.read])
        let req = ControlRequest(cmd: "screenshot", args: [:], from: nil, token: grant.token)
        let res = ControlCommands.handle(req, all: [pane])
        guard case .ok(let dict) = res else {
            Issue.record("screenshot command failed: \(res)")
            return
        }
        #expect(dict["format"]?.string == "png")
        guard let b64 = dict["data"]?.string else {
            Issue.record("missing base64 data")
            return
        }
        guard let data = Data(base64Encoded: b64) else {
            Issue.record("invalid base64 encoding")
            return
        }
        #expect(Array(data.prefix(pngHeader.count)) == pngHeader)
    }

    @Test func secureInputRefusesTextAndScreenshot() async {
        let oldMode = ControlCommands.mode
        ControlCommands.mode = .on
        defer { ControlCommands.mode = oldMode }

        let app = Tako.App()
        let surface = Tako.SurfaceView(app, baseConfig: .init(), uuid: UUID())
        let controller = TerminalController(app)
        let pane = ControlCommands.Pane(surface: surface, windowID: "w1", tabID: "t1", controller: controller)

        surface.isSecureInputMode = true
        defer { surface.isSecureInputMode = false }
        #expect(surface.isSecureInput)

        let grant = ControlGrantStore.shared.issueGrant(client: "visual-test", scopes: [.read])

        // 1. Screenshot refusal
        let reqScreenshot = ControlRequest(cmd: "screenshot", args: [:], from: nil, token: grant.token)
        let resScreenshot = ControlCommands.handle(reqScreenshot, all: [pane])
        guard case .failure(let errScreenshot) = resScreenshot else {
            Issue.record("screenshot should be refused for secure-input pane")
            return
        }
        #expect(errScreenshot.code == .disabled)
        #expect(errScreenshot.message.contains("secure-input panes cannot be read"))

        // 2. Text read refusal
        let reqText = ControlRequest(cmd: "text", args: ["styled": .bool(true)], from: nil, token: grant.token)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ControlCommands.handle(reqText, all: [pane]) { resText in
                guard case .failure(let errText) = resText else {
                    Issue.record("text read should be refused for secure-input pane")
                    continuation.resume()
                    return
                }
                #expect(errText.code == .disabled)
                #expect(errText.message.contains("secure-input panes cannot be read"))
                continuation.resume()
            }
        }
    }

    @Test func tuiRenderedLookAssertion() throws {
        let app = Tako.App()
        let surface = Tako.SurfaceView(app, baseConfig: .init(), uuid: UUID())

        // Simulated TUI header and status bar
        surface.core.feed(bytes: Data("\u{1b}[7m [TUI Header: Main Menu] \u{1b}[0m\r\n\u{1b}[32mStatus: Running\u{1b}[0m\r\n".utf8))

        // Assert on the rendered look of a TUI through styled text
        let readResult = ControlInput.read(surface.core, lines: 4, styled: true)
        guard case .string(let text)? = readResult["text"] else {
            Issue.record("missing text")
            return
        }
        #expect(text.contains("[TUI Header: Main Menu]"))
        #expect(text.contains("Status: Running"))
        // Reverse attribute in header
        #expect(text.contains(";7;"))
        // Green color in status
        #expect(text.contains("38;2;"))

        // Assert on screenshot output
        let (png, w, h) = try ControlCommands.captureScreenshot(surface)
        #expect(w > 0 && h > 0)
        #expect(Array(png.prefix(pngHeader.count)) == pngHeader)

        // Decode returned PNG and assert non-blank rendered pixels
        guard let rep = NSBitmapImageRep(data: png) else {
            Issue.record("Failed to decode PNG image data")
            return
        }
        #expect(rep.pixelsWide == w)
        #expect(rep.pixelsHigh == h)

        // 1. Positive assertion: verify stable expected pixel regions in the returned capture.
        // Row 0 has reverse video attribute ("\u{1b}[7m"), which renders foreground text color
        // as background across the cell width.
        let cellHeight = max(1, h / 24)
        var hasExpectedHeaderHighlight = false
        for testY in stride(from: 2, to: h - 2, by: max(1, cellHeight / 2)) {
            for x in stride(from: 10, to: min(w - 10, 150), by: 10) {
                if let color = rep.colorAt(x: x, y: testY) {
                    let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3.0
                    if brightness > 0.3 {
                        hasExpectedHeaderHighlight = true
                        break
                    }
                }
            }
            if hasExpectedHeaderHighlight { break }
        }
        #expect(hasExpectedHeaderHighlight, "Expected bright highlighted reverse-video header pixels")

        // 2. Negative control: an empty surface without reverse header must NOT contain bright highlight in row 0
        let emptySurface = Tako.SurfaceView(app, baseConfig: .init(), uuid: UUID())
        let (emptyPng, ew, eh) = try ControlCommands.captureScreenshot(emptySurface)
        guard let emptyRep = NSBitmapImageRep(data: emptyPng) else {
            Issue.record("Failed to decode empty PNG image data")
            return
        }
        let emptyCellHeight = max(1, eh / 24)
        let emptySampleY = emptyCellHeight / 2
        var hasHighlightInNegativeControl = false
        for x in stride(from: 10, to: min(ew - 10, 150), by: 5) {
            if let color = emptyRep.colorAt(x: x, y: emptySampleY) {
                let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3.0
                if brightness > 0.4 {
                    hasHighlightInNegativeControl = true
                    break
                }
            }
        }
        #expect(!hasHighlightInNegativeControl, "Negative control failed: unstyled surface unexpectedly contained highlight pixels in row 0")
    }
}

