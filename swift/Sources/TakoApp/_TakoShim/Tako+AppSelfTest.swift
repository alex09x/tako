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
import CoreGraphics

extension Tako {
    /// The surface a self-test drives: the key window's, else the first
    /// window that has one. Not simply the first window -- another window
    /// (a panel, a test's leftover) may hold no terminal at all.
    @MainActor static func selfTestTarget() -> (NSWindow, SurfaceView)? {
        func find(_ view: NSView) -> SurfaceView? {
            if let surface = view as? SurfaceView { return surface }
            for sub in view.subviews {
                if let found = find(sub) { return found }
            }
            return nil
        }
        let candidates = [NSApp.keyWindow].compactMap { $0 } + NSApp.windows
        for window in candidates {
            if let surface = window.contentView.flatMap(find) { return (window, surface) }
        }
        return nil
    }

    /// Save the pixels the renderer committed for the window, and check that
    /// the grid is where the layout says: a red block in the first cells
    /// must start inside the padding, with the padding itself left alone.
    /// The PNG is for the eye as much as for the script.
    @MainActor static func runFrameSelfTest() {
        guard let (window, surface) = selfTestTarget() else { return }
        window.makeFirstResponder(surface)
        let reportPath = Tako.selfTestReportPath("tako-frametest.txt")
        guard let renderer = surface.metalRendererForTesting else {
            try? "FAIL no Metal renderer: \(surface.metalUnavailableReason ?? "unknown")\n"
                .write(toFile: reportPath, atomically: true, encoding: .utf8)
            return
        }
        // Clear, home, four cells of pure red -- truecolor, so no palette or
        // theme changes the shade -- then text.
        // The lines below it are for the eye: clusters, styles and colours.
        surface.feed(data: Data((
            "\u{1b}[2J\u{1b}[H\u{1b}[48;2;255;0;0m    \u{1b}[0m tako frame\r\n"
            + "clusters: \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} \u{1F1EF}\u{1F1F5} \u{2764}\u{FE0F} "
            + "\u{1F44D}\u{1F3FD} e\u{0301}\u{0302} \u{0928}\u{092E}\u{0938}\u{094D}\u{0924}\u{0947} "
            + "\u{05E9}\u{05C1}\u{05B8}\u{05DC}\u{05D5}\u{05B9}\u{05DD}\r\n"
            + "styles: \u{1b}[1mbold\u{1b}[0m \u{1b}[3mitalic\u{1b}[0m \u{1b}[4munderline\u{1b}[0m "
            + "\u{1b}[31mred\u{1b}[32m green\u{1b}[34m blue\u{1b}[0m \u{1b}[7mreverse\u{1b}[0m\r\n"
        ).utf8))
        let layout = surface.gridLayout
        let cell = CGSize(width: surface.cellWidth, height: surface.cellHeight)
        var captured = false
        renderer.committedFrameCaptureForTesting = { _, pixels in
            guard !captured, let drawable = surface.metalLayer?.drawableSize else { return }
            let width = Int(drawable.width), height = Int(drawable.height)
            // The first frame that has the red block; earlier ones may still
            // show the shell's prompt.
            guard let report = Self.frameCheck(
                pixels: pixels, width: width, height: height,
                scale: CGFloat(width) / max(surface.bounds.width, 1), layout: layout, cell: cell
            ) else { return }
            captured = true
            renderer.committedFrameCaptureForTesting = nil
            Self.writePNG(pixels, width: width, height: height, to: Tako.selfTestReportPath("tako-frame.png"))
            try? report.write(toFile: reportPath, atomically: true, encoding: .utf8)
        }
        surface.scheduleRedraw()
    }

    /// The frame self-test's verdict on a BGRA frame, or nil while the frame
    /// does not show the red block in its first cells yet.
    static func frameCheck(
        pixels: [UInt8], width: Int, height: Int, scale: CGFloat,
        layout: TerminalGridLayout, cell: CGSize
    ) -> String? {
        guard width > 0, height > 0, pixels.count >= width * height * 4 else { return nil }
        func rgb(_ x: CGFloat, _ y: CGFloat) -> (Int, Int, Int) {
            let px = min(max(Int(x * scale), 0), width - 1)
            let py = min(max(Int(y * scale), 0), height - 1)
            let i = (py * width + px) * 4
            return (Int(pixels[i + 2]), Int(pixels[i + 1]), Int(pixels[i]))
        }
        func red(_ c: (Int, Int, Int)) -> Bool { c.0 > 150 && c.1 < 100 && c.2 < 100 }
        let inCell = rgb(layout.left + cell.width * 1.5, layout.top + cell.height / 2)
        guard red(inCell) else { return nil }
        let inPadding = rgb(layout.left / 2, layout.top + cell.height / 2)
        let abovePadding = rgb(layout.left + cell.width * 1.5, layout.top / 2)
        var report = "grid at (\(layout.left), \(layout.top)) pt, cell \(cell.width)x\(cell.height), scale \(scale)\n"
        func line(_ name: String, _ ok: Bool, _ got: (Int, Int, Int)) {
            report += "\(ok ? "ok  " : "FAIL") \(name.padding(toLength: 30, withPad: " ", startingAt: 0)) rgb=\(got)\n"
        }
        line("first cells are red", true, inCell)
        line("left padding is not the cell", !red(inPadding), inPadding)
        line("top padding is not the cell", !red(abovePadding), abovePadding)
        return report
    }

    /// BGRA pixels, as the drawable holds them, to a PNG file.
    static func writePNG(_ pixels: [UInt8], width: Int, height: Int, to path: String) {
        let data = Data(pixels.prefix(width * height * 4)) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    @MainActor static func runScrollSelfTest() {
        guard let (window, surface) = selfTestTarget() else { return }
        window.makeFirstResponder(surface)

        // Somewhere to scroll to. Fed straight to the engine rather than
        // through the shell, so the test does not depend on what the shell
        // prints or how fast it does it.
        let history = (0..<400).map { "history line \($0)" }.joined(separator: "\r\n") + "\r\n"
        surface.feed(data: Data(history.utf8))

        /// One precise wheel event. `hasPreciseScrollingDeltas` cannot be set
        /// on an NSEvent directly; it follows from the CGEvent's units.
        func precise(_ points: Int32) -> NSEvent? {
            guard let cg = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 1, wheel1: points, wheel2: 0, wheel3: 0
            ) else { return nil }
            return NSEvent(cgEvent: cg)
        }

        var report = ""
        func line(_ label: String, _ got: CGFloat, _ want: CGFloat) {
            let ok = abs(got - want) < 0.001
            report += "\(ok ? "ok  " : "FAIL")  \(label.padding(toLength: 34, withPad: " ", startingAt: 0))"
                + " presented=\(String(format: "%.4f", got)) expected=\(String(format: "%.4f", want))\n"
        }

        // Three points make one row at this surface's scroll rate, so each
        // one has to show up as a third of a row -- not nothing, and not a
        // whole row. Nothing was the old behaviour; a whole row was the jerk.
        line("start", surface.presentedScrollRows, 0)
        for (i, want) in [(1, 1.0 / 3.0), (2, 2.0 / 3.0), (3, 1.0)] {
            guard let event = precise(1) else { report += "FAIL  could not build event\n"; break }
            surface.scrollWheel(with: event)
            line("after \(i) of 3 points up", surface.presentedScrollRows, CGFloat(want))
        }
        // On a whole row nothing is left translating: the engine is where the
        // eye is.
        line("engine agrees on the boundary", CGFloat(surface.viewportOffset), surface.presentedScrollRows)

        // And back down again, to the exact place it started.
        for _ in 0..<3 {
            if let event = precise(-1) { surface.scrollWheel(with: event) }
        }
        line("after reversing all the way", surface.presentedScrollRows, 0)

        let cadence = surface.presentationCadence
        report += "\nframes submitted=\(cadence.submitted) presented=\(cadence.sequence)\n"
        if cadence.submitted == 0 {
            report += "FAIL  nothing was ever handed to the display\n"
        }
        try? report.write(toFile: Tako.selfTestReportPath("tako-scrolltest.txt"), atomically: true, encoding: .utf8)
    }

    @MainActor static func runKeySelfTest() {
        guard let (window, surface) = selfTestTarget() else { return }

        // keyCode, characters, charactersIgnoringModifiers, flags, label
        let cases: [(UInt16, String, String, NSEvent.ModifierFlags, String)] = [
            (0, "a", "a", [], "a"),
            (0, "A", "a", [.shift], "shift+a"),
            (18, "1", "1", [], "1"),
            (18, "!", "1", [.shift], "shift+1"),
            (41, ";", ";", [], ";"),
            (41, ":", ";", [.shift], "shift+;"),
            // ctrl+c, and the same physical key on a Cyrillic layout. Key
            // code 8 is the `c` key whatever it prints, so both have to
            // encode as 0x03 -- the interrupt cannot depend on the layout.
            // The end-to-end check for this races the shell's own handling
            // of the signal against the keys typed after it; this does not.
            (8, "\u{0003}", "c", [.control], "ctrl+c"),
            (8, "\u{0441}", "\u{0441}", [.control], "ctrl+c cyrillic"),
            // Space: plain, twice in a row (the double-space full stop
            // substitution must not reach a terminal), with Shift, with
            // Control (NUL, the Emacs/tmux mark key) and with Option (which
            // macOS turns into a no-break space that shells cannot run).
            (49, " ", " ", [], "space"),
            (49, " ", " ", [], "space2"),
            (49, " ", " ", [.shift], "shift+spc"),
            (49, "\u{0000}", " ", [.control], "ctrl+spc"),
            (49, "\u{00A0}", " ", [.option], "opt+spc"),
        ]

        var report = ""
        for (code, chars, bare, flags, label) in cases {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: chars, charactersIgnoringModifiers: bare,
                isARepeat: false, keyCode: code)
            else {
                report += "\(label): could not build event\n"
                continue
            }
            let before = surface.selfTestBytes.count
            surface.selfTestCapturing = true
            surface.keyDown(with: event)
            surface.selfTestCapturing = false
            let produced = Array(surface.selfTestBytes[before...])
            report += "\(label.padding(toLength: 10, withPad: " ", startingAt: 0))"
                + " chars=\(chars) -> \(produced.map { String(format: "%02x", $0) }.joined(separator: " "))"
                + " (\(String(decoding: produced, as: UTF8.self)))\n"
        }
        try? report.write(toFile: Tako.selfTestReportPath("tako-keytest.txt"), atomically: true, encoding: .utf8)
    }

    /// Type into the real shell and report what came back on screen.
    ///
    /// The byte-level self-test proves what the encoder produced; this
    /// proves what the shell did with it, which is the thing that was
    /// actually broken.
    @MainActor static func runInputSelfTest() {
        guard let (window, surface) = selfTestTarget() else { return }
        // Whether someone could start typing without clicking first. Read
        // before this test takes focus itself, which would hide the answer.
        let focusedAtLaunch = window.firstResponder === surface
        window.makeFirstResponder(surface)

        // keyCode, characters, charactersIgnoringModifiers, flags
        let typing: [(UInt16, String, String, NSEvent.ModifierFlags)] = [
            (0, "a", "a", []), (1, "s", "s", []), (2, "d", "d", []),
            (49, " ", " ", []),
            (0, "A", "a", [.shift]), (1, "S", "s", [.shift]), (2, "D", "d", [.shift]),
            (49, " ", " ", []),
            (18, "1", "1", []), (18, "!", "1", [.shift]),
            (41, ":", ";", [.shift]),
            (49, " ", " ", []),
            // ctrl+u clears the line, which is only visible if ctrl works.
            (32, "u", "u", [.control]),
            // The Cyrillic ctrl+c check used to live here, typed after some
            // text so a failed interrupt left the text behind. It raced: the
            // shell's handling of the signal against the keys typed straight
            // after it, so a working terminal failed roughly one run in
            // three. runKeySelfTest asserts the same thing on the byte the
            // key produces, which nothing can race.
            (4, "h", "h", []), (14, "e", "e", []), (37, "l", "l", []),
            (37, "l", "l", []), (31, "o", "o", []),
            // Nothing after this clears the line, so this is what actually
            // survives to the final screen -- the earlier "asd ASD 1!:"
            // segment gets wiped by the ctrl+u right after it regardless of
            // whether its spaces worked, which isn't a real check.
            (49, " ", " ", []),
            (13, "w", "w", []), (31, "o", "o", []), (35, "r", "r", []),
            (37, "l", "l", []), (2, "d", "d", []),
        ]
        for (code, chars, bare, flags) in typing {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: chars, charactersIgnoringModifiers: bare,
                isARepeat: false, keyCode: code)
            else { continue }
            // Delivered the way a key press is, so a menu key equivalent or
            // another view that claims the key fails this test. Only a key
            // window receives keys from the application; a run started where
            // nothing activated the app has none, and goes to the window.
            if window.isKeyWindow {
                NSApplication.shared.sendEvent(event)
            } else {
                window.sendEvent(event)
            }
        }
        let route = window.isKeyWindow ? "application" : "window"

        // The shell echoes on its own schedule, so read the screen after it
        // has had a chance to.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                let rows = (0..<surface.rows).map { row in
                    String(String.UnicodeScalarView(
                        surface.core.viewportRow(row: UInt32(row))
                            .compactMap { UnicodeScalar($0.ch) }))
                    .replacingOccurrences(of: "\u{0}", with: " ")
                }
                let screen = rows.map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                let expected = "expected the last line to contain: hello world (space test)"
                let focus = "focused at launch: \(focusedAtLaunch ? "yes" : "no"), keys sent through the \(route)"
                try? "\(expected)\n\(focus)\n\n\(screen)\n"
                    .write(toFile: Tako.selfTestReportPath("tako-inputtest.txt"), atomically: true, encoding: .utf8)
            }
        }
    }
}
