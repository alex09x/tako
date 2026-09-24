import AppKit
import Combine
import CoreGraphics
import CoreText
import Darwin
import Foundation
import ImageIO
import TakoKit
import Metal
import OSLog
import QuartzCore
import SwiftUI
import UserNotifications
import simd

// The C surface lives in TakoKit; this file only uses it.
// MARK: - Tako Namespace Extensions

extension Tako {
    // MARK: - Delegate Protocol
    /// Protocol implemented by the main AppDelegate to look up active surface views by UUID.
    public protocol Delegate: AnyObject {
        func findSurface(forUUID uuid: UUID) -> Tako.SurfaceView?
    }

    // MARK: - Application Object
    /// Upstream's application-level singleton manager.
    /// In our architecture, surface management and core lifecycle are owned per-surface
    /// by TakoCore and PTY. Tako.App holds application readiness state, delegates,
    /// and global clipboard confirmation dispatching.
    open class App: ObservableObject {
        public enum Readiness: String {
            case loading
            case error
            case ready
        }

        @Published public var readiness: Readiness = .ready {
            didSet {
                let args = CommandLine.arguments
                guard readiness == .ready,
                      args.contains("--selftest-keys")
                        || args.contains("--selftest-input")
                        || args.contains("--selftest-scroll")
                        || args.contains("--selftest-frame") else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    MainActor.assumeIsolated {
                        if args.contains("--selftest-input") {
                            Tako.runInputSelfTest()
                        } else if args.contains("--selftest-scroll") {
                            Tako.runScrollSelfTest()
                        } else if args.contains("--selftest-frame") {
                            Tako.runFrameSelfTest()
                        } else {
                            Tako.runKeySelfTest()
                        }
                    }
                }
            }
        }
        @Published public private(set) var config: Tako.Config
        public weak var delegate: Tako.Delegate?
        /// Upstream force-unwraps this handle, so it must be non-nil from
        /// the start. It carries no state -- the Rust core is reached
        /// through `TakoCore`, not through this handle.
        public var app: tako_app_t? = tako_app_t()

        /// Whether quitting may ask first. Which terminals are busy is each
        /// surface's to say (`SurfaceView.needsConfirmQuit`); the app only
        /// says whether asking is configured at all.
        public var needsConfirmQuit: Bool {
            config.confirmCloseSurface != .never
        }

        /// Where the configuration was loaded from, if not the default
        /// search path. Kept so a reload goes back to the same file.
        private let configPath: String?

        public init(configPath: String? = nil) {
            self.configPath = configPath
            self.config = Tako.Config(at: configPath)
            self.readiness = .ready
        }

        public func appTick() {
            // Unneeded in our Rust core architecture because PTY read loops run asynchronously on background queues.
        }

        public func openConfig() {
            let path = ("~/.config/tako/config" as NSString).expandingTildeInPath
            if !FileManager.default.fileExists(atPath: path) {
                let dir = (path as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? "# Tako configuration\n".write(toFile: path, atomically: true, encoding: .utf8)
            }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }

        public func reloadConfig(soft: Bool = false) {
            // Reload the file we actually loaded. Passing nil here sent every
            // reload back to the default search path, so an app started
            // against a specific config -- a UI test, or anyone using
            // TAKO_CONFIG_PATH -- silently lost it on the first reload.
            let config = Tako.Config(at: configPath)
            self.config = config
            NotificationCenter.default.post(
                name: .takoConfigDidChange,
                object: nil,
                userInfo: [Foundation.Notification.Name.TakoConfigChangeKey: config])
        }

        // Upstream's surface-scoped app calls. They take the view, not a C
        // handle: there is no C surface behind a view here, and a handle
        // that is always nil is how these used to do nothing at all. Calls
        // with no implementation were removed rather than left empty; the
        // controllers reach those through their own actions and
        // notifications.

        /// Double-clicking a divider equalizes the splits around it.
        @MainActor public func splitEqualize(surface: Tako.SurfaceView) {
            NotificationCenter.default.post(name: Tako.Notification.didEqualizeSplits, object: surface)
        }

        /// The window holding `surface` enters or leaves fullscreen.
        @MainActor public func toggleFullscreen(surface: Tako.SurfaceView, mode: FullscreenMode = .native) {
            NotificationCenter.default.post(
                name: Tako.Notification.takoToggleFullscreen,
                object: surface,
                userInfo: [Tako.Notification.FullscreenModeKey: mode])
        }

        public enum FontSizeModification: Equatable {
            case increase(Int)
            case decrease(Int)
            case reset
        }

        @MainActor public func changeFontSize(surface: Tako.SurfaceView, _ change: FontSizeModification) {
            surface.changeFontSize(change)
        }

        @MainActor public func resetTerminal(surface: Tako.SurfaceView) {
            surface.resetTerminal()
        }

        public func handleUserNotification(response: UNNotificationResponse) {}
        public func shouldPresentNotification(notification: UNNotification) -> Bool { false }

        /// Completes an asynchronous clipboard read or paste operation.
        /// Upstream calls this callback after paste confirmation or clipboard retrieval.
        public static func completeClipboardRequest(
            _ surface: tako_surface_t,
            data: String,
            state: UnsafeMutableRawPointer?,
            confirmed: Bool = false
        ) {
            tako_surface_complete_clipboard_request(surface, data, state, confirmed)
        }

        public static func completeClipboardRequest(
            _ surfaceView: Tako.SurfaceView,
            data: String,
            state: UnsafeMutableRawPointer?,
            confirmed: Bool = false
        ) {
            // `pasteText` is main-actor isolated because it touches the view;
            // this callback arrives from the clipboard confirmation flow with
            // no isolation of its own.
            DispatchQueue.main.async { surfaceView.pasteText(data) }
        }
    }

    // MARK: - Surface Model & Configuration
    /// Lightweight configuration for initializing new surfaces.
    /// Everything a new surface can be seeded with. The AppleScript layer
    /// converts these to and from a scripting record, so the member names
    /// are upstream's record keys.
    /// Run the key path against the real `keyDown` and write what came out.
    ///
    /// Reproducing a keyboard bug from outside the process needs
    /// Accessibility permission, which a build like this does not have. This
    /// builds the events itself and reports what each one produced.
    /// Does a precise trackpad delta move the grid by a fraction of a row?
    ///
    /// The arithmetic has unit tests, but they run against the accumulator in
    /// isolation. This asks the question of the shipped app: real scroll
    /// events, through the real responder chain, into the surface the window
    /// actually contains -- which is the part that was a second, unmaintained
    /// terminal until recently.
    /// Where the self-tests write their reports. `TAKO_SELFTEST_DIR`
    /// overrides /tmp, so two runs on one machine -- or a test suite running
    /// beside the app's own self-test -- do not overwrite each other's files.
    nonisolated(unsafe) static var selfTestReportDirectory: String =
        ProcessInfo.processInfo.environment["TAKO_SELFTEST_DIR"] ?? "/tmp"

    static func selfTestReportPath(_ name: String) -> String {
        (selfTestReportDirectory as NSString).appendingPathComponent(name)
    }

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

    /// The surface holding the keys currently, so a new tab, split or window
    /// can start where it is.
    @MainActor private static var focusedSurfaceInKeyWindow: SurfaceView? {
        guard let window = NSApplication.shared.keyWindow else { return nil }
        func find(_ view: NSView) -> SurfaceView? {
            if let surface = view as? SurfaceView, surface.isFirstResponderSurface {
                return surface
            }
            for sub in view.subviews {
                if let found = find(sub) { return found }
            }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    /// Where the surface holding the keys currently is, so a new tab can
    /// open in the same place.
    @MainActor static var focusedWorkingDirectory: String? {
        focusedSurfaceInKeyWindow?.pwd
    }

    /// The font size (in points, possibly zoomed) of the surface holding the
    /// keys currently, so a new window, tab or split can start at it.
    @MainActor static var focusedFontSize: CGFloat? {
        focusedSurfaceInKeyWindow?.theme.fontSize
    }

    /// Where a terminal starts when nothing else supplies a directory:
    /// `working-directory`, resolved to an actual path.
    static func resolvedWorkingDirectory(_ config: Tako.Config) -> String {
        switch config.workingDirectory {
        case .path(let path): return (path as NSString).expandingTildeInPath
        case .home: return NSHomeDirectory()
        case .inherit: return FileManager.default.currentDirectoryPath
        }
    }

    /// What a window or a tab is called when the shell has not said.
    ///
    /// The last path component, which is what identifies a project at a
    /// glance. Home and root have no useful basename, so they get `~` and
    /// `/` respectively -- but a bare `/` as a title is meaningless in a
    /// tab strip, so home wins when the directory is either.
    static func titleForDirectory(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let home = NSHomeDirectory()
        if expanded == home || expanded == "/" || expanded.isEmpty { return "~" }
        let name = (expanded as NSString).lastPathComponent
        return name.isEmpty ? "~" : name
    }

    /// Payloads the core sends up with an app action. Upstream generates
    /// these from its Zig definitions; ours carry the same fields.
    enum Action {
        /// Move the current tab left (negative) or right (positive).
        public struct MoveTab {
            public let amount: Int
            public init(amount: Int) { self.amount = amount }
        }

        /// OSC 9;4 progress, shown in the dock and the tab title.
        public struct ProgressReport: Equatable {
            public enum State: Equatable { case none, set, error, indeterminate, pause }
            public let state: State
            public let progress: UInt8?
            public init(state: State, progress: UInt8? = nil) {
                self.state = state
                self.progress = progress
            }
        }

        /// Scrollbar visibility policy.
        public typealias Scrollbar = Tako.Config.Scrollbar

        public struct StartSearch {
            public let needle: String?

            public init(needle: String?) {
                self.needle = needle
            }

            public init(c: tako_action_start_search_s) {
                if let needleCString = c.needle {
                    self.needle = String(cString: needleCString)
                } else {
                    self.needle = nil
                }
            }
        }
    }

    /// Make `to` the first responder of its window, optionally after a delay
    /// so it runs behind any UI that is still restoring focus itself.
    @MainActor public static func moveFocus(
        to: SurfaceView?,
        from: SurfaceView? = nil,
        delay: TimeInterval? = nil
    ) {
        guard let to else { return }
        let move = {
            guard let window = to.window else { return }
            window.makeFirstResponder(to)
        }
        if let delay {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: move)
        } else {
            move()
        }
    }

    public struct SurfaceConfiguration {
        public var fontSize: Float32?
        public var workingDirectory: String?
        public var command: String?
        public var initialInput: String?
        /// Hold the surface open after the command exits, so a script that
        /// finishes instantly doesn't flash the window closed.
        public var waitAfterCommand: Bool = false
        public var environmentVariables: [String: String] = [:]

        public init() {}

        public init(fontSize: Float32? = nil,
                    workingDirectory: String? = nil,
                    command: String? = nil,
                    initialInput: String? = nil,
                    waitAfterCommand: Bool = false,
                    environmentVariables: [String: String] = [:]) {
            self.fontSize = fontSize
            self.workingDirectory = workingDirectory
            self.command = command
            self.initialInput = initialInput
            self.waitAfterCommand = waitAfterCommand
            self.environmentVariables = environmentVariables
        }
    }

    /// Wrapper representing a surface model.
    open class Surface: @unchecked Sendable {
        /// The view that owns the engine and the PTY. Weak because the view
        /// owns the model, not the other way around.
        public weak var view: SurfaceView?

        public var unsafeCValue: tako_surface_t? { nil }

        public init(cSurface: tako_surface_t? = nil) {}

        public init(view: SurfaceView) { self.view = view }

        @MainActor public func sendText(_ text: String) {
            view?.write(text)
        }

        @MainActor public func sendKeyEvent(_ event: Tako.Input.KeyEvent) {
            view?.send(keyEvent: event)
        }

        @MainActor public func sendMouseButton(_ event: Tako.Input.MouseButtonEvent) {
            view?.send(mouseButton: event)
        }

        @MainActor public func sendMousePos(_ event: Tako.Input.MousePosEvent) {
            view?.send(mousePos: event)
        }

        @MainActor public func sendMouseScroll(_ event: Tako.Input.MouseScrollEvent) {
            view?.send(mouseScroll: event)
        }

        @MainActor public var mouseCaptured: Bool { view?.mouseCaptured ?? false }
        @MainActor public var foregroundPID: Int? { view?.pty?.foregroundPID }
        @MainActor public var ttyName: String? { view?.pty?.ttyName }

        @MainActor public func perform(action: String) -> Bool {
            view?.performBindingAction(action) ?? false
        }
    }

    // MARK: - Config Placeholder

    // MARK: - Helper Action / Placeholder Types

    public class Inspector: ObservableObject {
        public init() {}
    }

    public enum OSSurfaceView {}

    public struct ChildExitedMessage {
        public var message: String
        public init(message: String) { self.message = message }
    }

}

// MARK: Search State

extension Tako.OSSurfaceView {
    @MainActor class SearchState: ObservableObject {
        /// The pasteboard used to persist the search needle.
        ///
        /// The `.find` pasteboard lets us sync our needle across the system and other find bars.
        private let pasteboard: OSPasteboard

        @Published var needle: String = ""
        @Published var selected: UInt?
        @Published var total: UInt?

        /// The range of the needle's text selection in the find bar.
        @Published var needleSelection: Range<String.Index>?

        init(
            from startSearch: Tako.Action.StartSearch,
            pasteboard: OSPasteboard = OSPasteboard.find
        ) {
            self.pasteboard = pasteboard
            if let needle = startSearch.needle, !needle.isEmpty {
                self.needle = needle
                writePasteboardNeedle()
            } else {
                readPasteboardNeedle()
            }
        }

        func readPasteboardNeedle() {
            let pasteboardNeedle = pasteboard.string
            if let pasteboardNeedle, pasteboardNeedle != needle {
                needle = pasteboardNeedle
                needleSelection = needle.startIndex..<needle.endIndex
            }
        }

        func writePasteboardNeedle() {
            pasteboard.string = needle
        }
    }
}

// MARK: - PTY Helper Implementation

enum TakoPTYEnvironment {
    /// Automation hosts and build tools frequently set NO_COLOR for their
    /// own logs. A GUI terminal must not leak that launcher preference into
    /// every interactive shell and silently disable application color.
    static let variablesRemovedFromChild = ["NO_COLOR"]

    /// What the terminal calls itself to the programs running inside it.
    ///
    /// A program that asks who it is talking to gets the true answer. Tools
    /// that gate kitty-protocol keyboard input or graphics on a list of
    /// TERM_PROGRAM names will not recognise us even though we speak those
    /// protocols; feature detection belongs in terminfo and in the escape
    /// sequences themselves, not in an allowlist of names.
    static func terminalIdentity(appVersion: String?) -> [(String, String)] {
        let version = appVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0"
        return [
            ("TERM_PROGRAM", "tako"),
            ("TERM_PROGRAM_VERSION", version),
        ]
    }
}

/// Internal UNIX pseudo-terminal pair management for Tako.SurfaceView.
final class PTY {
    let master: Int32
    let child: pid_t
    private(set) var alive = true

    /// The directory the child process actually started in -- what
    /// `working-directory`/`window-inherit-working-directory` resolved to,
    /// or the home directory when nothing supplied one.
    let startedInDirectory: String

    init?(cols: UInt16, rows: UInt16, workingDirectory: String? = nil, config: Tako.Config? = nil) {
        // Everything the child needs -- argv, envp and the working directory
        // -- is built as C strings here, in the parent, before forkpty: after
        // it, only async-signal-safe calls are legal in the child, which
        // rules out setenv/unsetenv/strdup.
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let shellPathString = PTY.loginShell
        let extraEnv = PTY.shellIntegrationEnvironment(config: config, loginShell: shellPathString)
            + TakoPTYEnvironment.terminalIdentity(appVersion: appVersion)

        var envMap = ProcessInfo.processInfo.environment
        for key in TakoPTYEnvironment.variablesRemovedFromChild { envMap.removeValue(forKey: key) }
        envMap["TERM"] = "xterm-256color"
        envMap["COLORTERM"] = "truecolor"
        envMap["SHELL"] = shellPathString
        for (key, value) in extraEnv { envMap[key] = value }

        // Plain C arrays, allocated here: passing a Swift array with `&` in
        // the child would go through Swift's array bridging, which is not
        // guaranteed to be allocation-free.
        let envStrings: [UnsafeMutablePointer<CChar>?] = envMap.map { strdup("\($0.key)=\($0.value)") }
        let envp = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: envStrings.count + 1)
        for (i, s) in envStrings.enumerated() { envp[i] = s }
        envp[envStrings.count] = nil

        let shellPath = strdup(shellPathString)
        let argvStrings: [UnsafeMutablePointer<CChar>?] = [shellPath, strdup("-l")]
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: argvStrings.count + 1)
        for (i, s) in argvStrings.enumerated() { argv[i] = s }
        argv[argvStrings.count] = nil

        // An app launched from the Finder inherits launchd's working
        // directory, which is `/`. A terminal that opens at the root of the
        // disk is useless, and it is why every title and prompt read "/".
        let startDir = workingDirectory.flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        self.startedInDirectory = startDir
        let childDir = strdup(startDir)

        var masterFD: Int32 = 0
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        let pid = forkpty(&masterFD, nil, nil, &size)
        if pid < 0 {
            for s in envStrings { free(s) }
            for s in argvStrings { free(s) }
            envp.deallocate()
            argv.deallocate()
            free(childDir)
            return nil
        }
        if pid == 0 {
            // A shell starts with default signal handling and nothing
            // blocked. Whatever this process ignores -- SIGHUP when launched
            // under nohup or from an ssh session, SIGINT from some launchers
            // -- would otherwise pass through exec to the shell and to every
            // program it runs: Ctrl-C would do nothing, and closing the
            // terminal would not end it.
            var empty: sigset_t = 0
            sigprocmask(SIG_SETMASK, &empty, nil)
            var signalNumber: Int32 = 1
            while signalNumber < NSIG {
                signal(signalNumber, SIG_DFL)
                signalNumber += 1
            }
            chdir(childDir)
            _ = execve(shellPath, argv, envp)
            _exit(127)
        }
        for s in envStrings { free(s) }
        for s in argvStrings { free(s) }
        envp.deallocate()
        argv.deallocate()
        free(childDir)
        master = masterFD
        child = pid
    }

    /// The user's login shell, from the password database. `$SHELL` is not
    /// it: an app launched from Finder inherits launchd's `/bin/zsh`, not
    /// what the user actually logs in with. Upstream reads passwd too,
    /// which is why it opens fish here and we were opening zsh.
    static var loginShell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// The environment upstream's shell integration needs: zsh through
    /// ZDOTDIR, everything else through XDG_DATA_DIRS. This is what makes
    /// the shell report its working directory (OSC 7), its title (OSC 0)
    /// and its prompt boundaries (OSC 133).
    ///
    /// Computed in the parent. Between `fork` and `exec` only
    /// async-signal-safe calls are allowed, and Foundation is not one --
    /// doing this in the child killed the shell before it ever ran.
    static func shellIntegrationEnvironment(config: Tako.Config? = nil, loginShell: String = PTY.loginShell) -> [(String, String)] {
        // `shell-integration = none`: inject nothing.
        guard config?.shellIntegration != Tako.Config.ShellIntegration.none else { return [] }
        guard let resources = Bundle.main.resourceURL?
            .appendingPathComponent("tako").path else { return [] }
        let base = resources + "/shell-integration"
        guard FileManager.default.fileExists(atPath: base) else { return [] }

        return shellIntegrationVariables(
            resourcesDir: resources,
            base: base,
            mode: config?.shellIntegration ?? .detect,
            loginShell: loginShell,
            shellFeatures: shellFeatures(config?.shellIntegrationFeatures),
            environment: ProcessInfo.processInfo.environment)
    }

    /// The env vars a shell-integration mode needs, given the login shell
    /// and the existing environment. Pulled out of
    /// `shellIntegrationEnvironment` so the shell-name/env-var mapping is
    /// testable without a bundled Resources directory, which a test host
    /// does not have.
    static func shellIntegrationVariables(
        resourcesDir: String,
        base: String,
        mode: Tako.Config.ShellIntegration,
        loginShell: String,
        shellFeatures: String,
        environment: [String: String]
    ) -> [(String, String)] {
        guard mode != .none else { return [] }

        var env: [(String, String)] = [
            ("TAKO_RESOURCES_DIR", resourcesDir),
            // Not `title`: upstream's integration sets the window title to
            // the running command, and the design wants the directory. An
            // application that sets OSC 0 deliberately -- vim, ssh -- still
            // wins, which is the behaviour the spec asks for.
            // Neither `title` nor `cursor`: the first sets the window title
            // to the running command where the design wants the directory,
            // and the second turns the cursor into a bar at the prompt where
            // the design wants an ember block everywhere.
            // `highlight` routes an interactive `cat` through bat when it is
            // installed, and does nothing at all when it is not. It stays out
            // of the way of pipes and redirects, so a script's `cat` is still
            // byte-for-byte cat; see the shell-integration files.
            ("TAKO_SHELL_FEATURES", shellFeatures),
        ]

        let shellName: String
        switch mode {
        case .detect: shellName = (loginShell as NSString).lastPathComponent
        case .bash: shellName = "bash"
        case .zsh: shellName = "zsh"
        case .fish: shellName = "fish"
        case .elvish: shellName = "elvish"
        case .none: shellName = ""
        }

        switch shellName {
        case "zsh":
            if let old = environment["ZDOTDIR"] {
                env.append(("TAKO_ZSH_ZDOTDIR", old))
            }
            env.append(("ZDOTDIR", base + "/zsh"))
        case "bash":
            env.append(("TAKO_BASH_INJECT", "1"))
        default:
            let existing = environment["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share"
            env.append(("XDG_DATA_DIRS", base + ":" + existing))
        }
        return env
    }

    /// Tako's own shell-integration feature defaults, in the fixed order
    /// they're declared, with `shell-integration-features`'s comma list
    /// applied over them: a bare name enables it, `no-<name>` disables it.
    /// Names outside `knownShellFeatures` are ignored, matching how every
    /// other config key here treats an unrecognised value.
    static let defaultShellFeatures = ["sudo", "prompt", "highlight"]
    static let knownShellFeatures: Set<String> = [
        "cursor", "sudo", "title", "ssh-env", "ssh-terminfo", "prompt", "highlight",
    ]

    static func shellFeatures(_ raw: String?) -> String {
        var enabled = defaultShellFeatures
        guard let raw else { return enabled.joined(separator: ",") }
        for token in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !token.isEmpty {
            if token.hasPrefix("no-") {
                let name = String(token.dropFirst(3))
                guard knownShellFeatures.contains(name) else { continue }
                enabled.removeAll { $0 == name }
            } else {
                guard knownShellFeatures.contains(token), !enabled.contains(token) else { continue }
                enabled.append(token)
            }
        }
        return enabled.joined(separator: ",")
    }

    /// The process currently in the foreground of this tty -- the running
    /// command, not the shell, when one is running.
    var foregroundPID: Int? {
        let pid = tcgetpgrp(master)
        return pid > 0 ? Int(pid) : nil
    }

    var ttyName: String? {
        guard let name = ttyname(master) else { return nil }
        return String(cString: name)
    }

    func write(_ data: Data) {
        guard !data.isEmpty, alive else { return }
        _ = data.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
    }

    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, alive else { return }
        _ = bytes.withUnsafeBufferPointer { Darwin.write(master, $0.baseAddress, $0.count) }
    }

    func resize(cols: UInt16, rows: UInt16) {
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    func readLoop(targetQueue: DispatchQueue = .main, onData: @escaping (Data) -> Void, onExit: @escaping () -> Void) {
        let fd = master
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let readChunk: () -> Data? = {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n <= 0 { return nil }
                return Data(buffer[0..<n])
            }
            PTYDeliveryPump.pump(
                readNext: readChunk,
                readNextIfAvailable: {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    guard Darwin.poll(&descriptor, 1, 0) > 0,
                          descriptor.revents & Int16(POLLIN) != 0 else {
                        return nil
                    }
                    return readChunk()
                },
                onData: onData,
                onExit: onExit,
                targetQueue: targetQueue
            )
        }
    }

    /// Set once the master is handed off to be closed. A second terminate
    /// -- a surface's close() and then its deinit -- must not close the
    /// number again: by then it may belong to another file.
    private var masterClosed = false

    func terminate() {
        alive = false
        guard !masterClosed else { return }
        masterClosed = true
        kill(child, SIGHUP)
        // Closing a pty master waits while its reader is inside read(),
        // which lasts until every process on the terminal has let go of it.
        // That is not the main thread's to wait for.
        let fd = master
        DispatchQueue.global(qos: .utility).async { close(fd) }
    }

    deinit {
        terminate()
    }
}

// MARK: - Tako.MetalTerminalHost
extension Tako {
    /// The host-side half of the GPU terminal path: everything an AppKit
    /// surface has to decide before handing a frame to the shared
    /// `MetalTerminalRenderer`.
    ///
    /// It is all pure functions over values -- no device, no layer, no view --
    /// so the geometry, the palette and the blink/fallback policy can be
    /// tested on a machine with no GPU and no window server, which is exactly
    /// what `swift test` is.
    enum MetalTerminalHost {
        /// Where the `CAMetalLayer` sits inside a padded surface, and how many
        /// real pixels it must render.
        struct LayerGeometry: Equatable {
            var frame: CGRect
            var drawableSize: CGSize
            var contentsScale: CGFloat

            /// False when the surface is too small to hold a single pixel of
            /// terminal, which is a frame to skip rather than to clamp.
            var isRenderable: Bool {
                drawableSize.width >= 1 && drawableSize.height >= 1
            }
        }

        /// The terminal itself occupies the surface inset by the configured
        /// window padding; the border around it stays the host's to fill.
        static func layerGeometry(
            bounds: CGRect,
            padding: CGFloat,
            scale: CGFloat
        ) -> LayerGeometry {
            let pad = max(padding, 0)
            let scale = max(scale, 1)
            let size = CGSize(
                width: max(bounds.width - pad * 2, 0),
                height: max(bounds.height - pad * 2, 0))
            return LayerGeometry(
                frame: CGRect(origin: CGPoint(x: pad, y: pad), size: size),
                // Whole pixels: a fractional drawable is rounded down by
                // CoreAnimation anyway, and rounding here keeps the viewport
                // the shaders see identical to the texture they write.
                drawableSize: CGSize(
                    width: (size.width * scale).rounded(.down),
                    height: (size.height * scale).rounded(.down)),
                contentsScale: scale)
        }

        /// The four padding bands around the terminal, in view coordinates.
        /// The GPU layer covers the middle, so only these are drawn by the
        /// CoreText overlay -- no band overlaps the Metal layer, which is what
        /// keeps the background from being painted twice.
        static func paddingRects(bounds: CGRect, padding: CGFloat) -> [CGRect] {
            let pad = max(padding, 0)
            guard pad > 0 else { return [] }
            let middleHeight = max(bounds.height - pad * 2, 0)
            return [
                CGRect(x: 0, y: 0, width: bounds.width, height: pad),
                CGRect(x: 0, y: bounds.height - pad, width: bounds.width, height: pad),
                CGRect(x: 0, y: pad, width: pad, height: middleHeight),
                CGRect(x: bounds.width - pad, y: pad, width: pad, height: middleHeight),
            ]
        }

        /// A theme color as the shared renderer wants it: straight (not
        /// premultiplied) sRGB components. Converting first matters -- a
        /// theme color built in another space would otherwise reach the GPU
        /// as raw component values in the wrong basis.
        static func color(_ color: CGColor, alpha: CGFloat = 1) -> SIMD4<Float> {
            let converted = color.converted(
                to: srgbSpace, intent: .defaultIntent, options: nil) ?? color
            let components = converted.components ?? [0, 0, 0, 1]
            let r = components.count > 0 ? components[0] : 0
            let g = components.count > 1 ? components[1] : r
            let b = components.count > 2 ? components[2] : r
            let a = (components.count > 3 ? components[3] : 1) * alpha
            return SIMD4<Float>(Float(r), Float(g), Float(b), Float(max(0, min(1, a))))
        }

        /// The renderer's fallback colors, taken from the user's theme rather
        /// than the shared renderer's built-in defaults.
        static func palette(for theme: TerminalTheme) -> TerminalMetalPalette {
            TerminalMetalPalette(
                background: color(theme.background),
                foreground: color(theme.foreground),
                selection: color(theme.selectionBackground),
                cursor: color(theme.cursorColor))
        }

        /// Cell geometry for the GPU, derived from the same CoreText metrics
        /// the fallback renderer measures the grid with, so both put a cell in
        /// the same place.
        static func metrics(
            for metrics: TerminalRenderer.Metrics,
            scale: CGFloat
        ) -> TerminalMetalCellMetrics {
            TerminalMetalCellMetrics(metrics, scale: max(scale, 1))
        }

        /// The CoreGraphics bottom edge for a preedit cell. Metal places row
        /// zero at the drawable's top, so the overlay must use the drawable
        /// height too. Falling back to the grid height preserves the
        /// bottom-anchored CoreText-only path.
        static func preeditCellBottom(
            cursorRow: Int,
            rows: Int,
            cellHeight: CGFloat,
            viewportHeight: CGFloat?
        ) -> CGFloat {
            guard rows > 0, cellHeight > 0 else { return 0 }
            let row = min(max(cursorRow, 0), rows - 1)
            let height = viewportHeight ?? CGFloat(rows) * cellHeight
            return max(0, height - CGFloat(row + 1) * cellHeight)
        }

        /// Whether the blinking half of the cursor is currently on.
        ///
        /// An unfocused pane does not blink at all -- it shows the outlined
        /// cursor continuously -- and a theme with blinking off has no timer
        /// driving `blinkOn` in the first place.
        static func cursorBlinkPhaseOn(
            isFocused: Bool,
            blinkOn: Bool,
            cursorBlinkEnabled: Bool
        ) -> Bool {
            guard isFocused, cursorBlinkEnabled else { return true }
            return blinkOn
        }

        /// Scrolled into the scrollback, the cursor belongs to a screen the
        /// user is not looking at, so it is not drawn. The planner reads
        /// visibility off the snapshot, so the decision is applied to the
        /// frame rather than carried alongside it.
        static func applyCursorVisibility(
            to frame: inout FfiRenderFrame,
            hasPreedit: Bool = false
        ) {
            frame.snapshot.cursorVisible =
                frame.snapshot.cursorVisible &&
                frame.snapshot.viewportOffset == 0 &&
                !hasPreedit
        }

        /// A layer display can already be queued when synchronized output
        /// opens. Keep the last complete drawable on screen until the engine
        /// closes mode 2026 and reports the accumulated damage.
        static func shouldRender(isSynchronizedOutputActive: Bool) -> Bool {
            !isSynchronizedOutputActive
        }

        // MARK: - Synchronized-output watchdog
        //
        // Suppressing renders for the whole of a mode 2026 frame is correct
        // only while frames are short. codex holds one open for the length of
        // an LLM response -- seconds -- and the display simply stops. The
        // watchdog below force-renders a frame that overstays.
        //
        // The policy lives in pure functions because both bugs this path has
        // shipped were scheduling bugs: a display frozen for the length of a
        // streaming response, and an 8ms busy-loop where the coalescing timer
        // re-entered the redraw request that had scheduled it. Neither was
        // reachable from a test.

        /// How long a mode 2026 frame may suppress drawing before the host
        /// paints it anyway. Long enough that an ordinary frame closes first,
        /// short enough that a stalled one still animates.
        static let syncOutputTimeout: TimeInterval = 0.200

        /// What one PTY batch means for the watchdog.
        enum WatchdogAction: Equatable {
            /// The frame is open and nothing is pending: start the timer.
            case arm
            /// The frame is open and the timer is already running. Re-arming
            /// here -- or requesting a redraw, as this path once did -- is
            /// what turns the coalescing timer into a busy-loop.
            case leaveArmed
            /// The frame closed. The close path redraws on its own.
            case disarm
        }

        static func watchdogAction(
            isSynchronizedOutputActive: Bool,
            watchdogArmed: Bool
        ) -> WatchdogAction {
            guard isSynchronizedOutputActive else { return .disarm }
            return watchdogArmed ? .leaveArmed : .arm
        }

        /// A fired watchdog repaints only while the frame it was armed for is
        /// still open. If the frame closed first, that path has already drawn
        /// the completed frame and repainting would duplicate it.
        static func watchdogShouldForceRender(
            isSynchronizedOutputActive: Bool
        ) -> Bool {
            isSynchronizedOutputActive
        }

        /// Upper bound on forced repaints while a frame stays open for
        /// `duration`. Each one must be re-armed by an incoming PTY batch, so
        /// a stalled frame produces fewer -- but this is the bound that
        /// separates "the display keeps moving" from both failure modes: a
        /// frozen display at 0, and the old busy-loop at one per 8ms.
        static func maxForcedRendersDuring(_ duration: TimeInterval) -> Int {
            guard duration > 0 else { return 0 }
            return Int(duration / syncOutputTimeout)
        }

        /// Ordinary terminal damage does not need a synchronous trip through
        /// Main. Device replies and host events do: they are externally
        /// observable and must stay ordered with later PTY batches.
        static func requiresSynchronousMainApplication(
            output: Data,
            events: [FfiEvent]
        ) -> Bool {
            !output.isEmpty || !events.isEmpty
        }

        /// Cap damage-driven drawing at the fastest display rate we support.
        /// This lets a burst parse ahead instead of interleaving a full frame
        /// between every PTY read, while keeping interactive latency below one
        /// 120 Hz frame.
        static let ptyRedrawCoalescingInterval: TimeInterval = 1.0 / 120.0

        /// Why a surface is drawing with CoreText instead of the GPU.
        enum Fallback: Equatable {
            /// No Metal device, no shader library, or no pipeline: the
            /// renderer never came up.
            case rendererUnavailable
            /// A see-through window. The GPU path clears to the default
            /// background and skips every cell that keeps it, which is only
            /// correct while that background is opaque -- at a lower opacity
            /// those cells would have to be drawn individually and would
            /// cover the very transparency they are meant to preserve. The
            /// whole frame goes back to CoreText, which composites it
            /// correctly, rather than losing content to a half-GPU frame.
            case transparentBackground
            /// The view is temporarily collapsed below its padding (common
            /// during installation and split resizing). CAMetalLayer rejects
            /// a zero-sized drawable, so CoreText owns this clipped frame.
            case unrenderableGeometry
        }

        /// nil when the GPU path is usable, otherwise the reason it is not.
        static func fallback(
            rendererAvailable: Bool,
            backgroundOpacity: Double,
            geometryRenderable: Bool
        ) -> Fallback? {
            guard rendererAvailable else { return .rendererUnavailable }
            guard geometryRenderable else { return .unrenderableGeometry }
            guard backgroundOpacity >= 1 else { return .transparentBackground }
            return nil
        }
    }
}

// MARK: - Tako.SurfaceView
extension Tako {
    /// Upstream's primary NSView subclass for terminal surface rendering.
    /// Backed by `TakoCore` (Rust engine via UniFFI), `PTY` (UNIX shell execution),
    /// and `TerminalRenderer` (CoreText text grid rendering).
    /// Windowing identity for one terminal: tabs, splits, focus, restoration,
    /// and the PTY it is attached to.
    ///
    /// The terminal itself is inherited, not reimplemented. This class used to
    /// carry its own core, renderer, Metal layer, input handling and selection
    /// -- a second terminal beside TakoTerminalNSView, which is the one every
    /// recent fix went into. Two implementations meant the app shipped the
    /// copy nobody was maintaining.
    open class SurfaceView: TakoTerminalNSView, Identifiable, ObservableObject, Codable, TakoTerminalNSViewDelegate {
        /// Identity carried across a layout restore (see the Codable
        /// conformance below); nil for a surface created fresh.
        public var restoredID: String?
        public typealias ID = UUID

        public let id: UUID
        public var uuid: UUID { id }

        public struct DerivedConfig: Equatable {
            public let backgroundColor: Color
            public let backgroundOpacity: Double
            public let backgroundBlur: Tako.Config.BackgroundBlur
            public let macosWindowShadow: Bool
            public let windowTitleFontFamily: String?
            public let windowAppearance: NSAppearance?
            public let scrollbar: Tako.Action.Scrollbar

            public init() {
                self.backgroundColor = Color(nsColor: .windowBackgroundColor)
                self.backgroundOpacity = 1.0
                self.backgroundBlur = .disabled
                self.macosWindowShadow = true
                self.windowTitleFontFamily = nil
                self.windowAppearance = nil
                self.scrollbar = .system
            }

            public init(_ config: Tako.Config) {
                self.backgroundColor = config.backgroundColor
                self.backgroundOpacity = config.backgroundOpacity
                self.backgroundBlur = config.backgroundBlur
                self.macosWindowShadow = config.macosWindowShadow
                self.windowTitleFontFamily = config.windowTitleFontFamily
                self.windowAppearance = nil
                self.scrollbar = .system
            }

            public static func == (lhs: DerivedConfig, rhs: DerivedConfig) -> Bool {
                lhs.backgroundColor == rhs.backgroundColor &&
                lhs.backgroundOpacity == rhs.backgroundOpacity &&
                lhs.macosWindowShadow == rhs.macosWindowShadow &&
                lhs.windowTitleFontFamily == rhs.windowTitleFontFamily
            }
        }

        @Published public private(set) var derivedConfig: DerivedConfig

        public private(set) var pty: PTY?

        private let parserQueue: DispatchQueue
        private let ptyRedrawLock = NSLock()
        private var ptyRedrawScheduled = false

        /// The pending synchronized-output watchdog, if one is armed. Main
        /// thread only; `watchdogAction` above decides what happens to it.
        private var syncOutputTimeoutItem: DispatchWorkItem?
        /// Set by the watchdog to let one `draw()` past the sync-output guard.
        private var syncOverride = false

        /// Applies one batch's `WatchdogAction`. Main thread only: the timer
        /// and `syncOutputTimeoutItem` both live there.
        private func applyWatchdogAction(_ action: MetalTerminalHost.WatchdogAction) {
            switch action {
            case .arm:
                armSyncOutputWatchdog()
            case .leaveArmed:
                break
            case .disarm:
                syncOutputTimeoutItem?.cancel()
                syncOutputTimeoutItem = nil
            }
        }

        /// Arms the one-shot watchdog. If the frame is still open when it
        /// fires, repaint from the mid-frame state rather than leave the
        /// display frozen for the rest of the frame.
        private func armSyncOutputWatchdog() {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.syncOutputTimeoutItem = nil
                guard MetalTerminalHost.watchdogShouldForceRender(
                    isSynchronizedOutputActive: self.core.isSynchronizedOutputActive()
                ) else { return }
                // Mark every row dirty: the renderer replans only damaged rows,
                // so without this the forced frame paints the stale GPU cache.
                self.core.markAllDamaged()
                self.syncOverride = true
                self.needsDisplay = true
                TakoLog.render.debug("syncOutput watchdog: forced render")
            }
            syncOutputTimeoutItem = item
            DispatchQueue.main.asyncAfter(
                deadline: .now() + MetalTerminalHost.syncOutputTimeout,
                execute: item
            )
        }

        /// Thread-safe, one-outstanding redraw request shared by the parser
        /// queue and cursor/UI paths. A PTY burst can therefore parse several
        /// batches before AppKit takes the Rust mutex for `renderFrame`.
        private func requestPtyRedraw() {
            let shouldSchedule = ptyRedrawLock.withLock {
                guard !ptyRedrawScheduled else { return false }
                ptyRedrawScheduled = true
                return true
            }
            if !shouldSchedule {
                TakoLog.render.debug("requestPtyRedraw: coalesced (already scheduled)")
                return
            }
            TakoLog.render.debug("requestPtyRedraw: scheduled")

            DispatchQueue.main.asyncAfter(
                deadline: .now() + MetalTerminalHost.ptyRedrawCoalescingInterval
            ) { [weak self] in
                guard let self else { return }
                self.ptyRedrawLock.withLock {
                    self.ptyRedrawScheduled = false
                }
                TakoLog.render.debug("requestPtyRedraw: timer fired → scheduleRedraw")
                self.scheduleRedraw()
            }
        }

        /// The inherited title, mirrored so Combine subscribers can follow it.
        ///
        /// `title` itself lives on the surface and is a plain stored property
        /// there; a property wrapper cannot be added by overriding, so the
        /// publisher lives here beside it.
        @Published public private(set) var titleText: String = ""

        override public func titleDidChange() {
            if !title.isEmpty { isUserSetTitle = false }
            titleText = title
        }
        public var isUserSetTitle: Bool = false

        /// The shell's current directory. Published so the app can follow it
        /// into window titles and the tab bar.
        @Published public private(set) var pwd: String?
        override public var workingDirectory: String? { pwd }

        public var surface: tako_surface_t? { nil }

        /// Whether this surface currently takes the keys.
        public var isFirstResponderSurface: Bool { window?.firstResponder === self }

        /// Set while the key self-test runs, so the bytes are recorded
        /// instead of reaching the shell.
        public var selfTestCapturing = false
        public private(set) var selfTestBytes: [UInt8] = []

        /// Every byte the key path produces goes through here.
        func writeToShell(_ bytes: [UInt8]) {
            if selfTestCapturing {
                selfTestBytes += bytes
            } else {
                pty?.write(bytes)
            }
        }

        /// Upstream stores surfaces in a `Codable` SplitTree so a window's
        /// layout can be restored. A live surface owns a PTY and a terminal
        /// engine, neither of which is serializable, so only the identity
        /// travels: restoring a layout recreates surfaces, it does not
        /// resurrect dead shells.
        private enum CodingKeys: String, CodingKey { case id }

        public required convenience init(from decoder: Decoder) throws {
            self.init(frame: .zero)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let id = try? container.decode(String.self, forKey: .id) {
                self.restoredID = id
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(String(describing: id), forKey: .id)
        }

        /// Full scrollback text, recomputed on demand. Upstream caches it
        /// because Shortcuts and Accessibility can ask for it repeatedly.
        public private(set) lazy var cachedScreenContents = CachedValue<String> { [weak self] in
            guard let self else { return "" }
            let total = Int(self.core.scrollbackLen()) + self.rows
            return (0..<total)
                .map { row in
                    String(String.UnicodeScalarView(
                        self.core.viewportRow(row: UInt32(row))
                            .compactMap { UnicodeScalar($0.ch) }))
                }
                .joined(separator: "\n")
        }

        /// Just what the viewport is showing.
        public private(set) lazy var cachedVisibleContents = CachedValue<String> { [weak self] in
            guard let self else { return "" }
            return (0..<self.rows)
                .map { row in
                    String(String.UnicodeScalarView(
                        self.core.viewportRow(row: UInt32(row))
                            .compactMap { UnicodeScalar($0.ch) }))
                }
                .joined(separator: "\n")
        }

        /// Command lifecycle for this surface, which is what the tab's crab
        /// indicator draws.
        public let crab = Tako.CrabTracker()

        /// Keeps the crab in this surface's tab. Held here so it lives as
        /// long as the surface does.
        private var crabBinding: Tako.CrabTabBinding?

        /// The window this surface's crab is currently bound to, so moving
        /// between windows rebinds but staying put does not.
        private weak var crabWindow: NSWindow?

        override open func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { crabBinding = nil; crabWindow = nil; return }
            guard window !== crabWindow else { return }
            crabWindow = window
            crabBinding = Tako.CrabTabBinding(surface: self, window: window)
            Tako.TabBarController.install(in: window)
        }

        /// The surface's own background, which the window matches so the
        /// titlebar and padding blend with the terminal.
        @Published public var backgroundColor: Color?

        /// Whether the window showing this surface is currently on screen.
        /// The controller keeps this in sync so the core can stop rendering
        /// for hidden windows.
        public var isWindowVisible: Bool = true

        /// Set while the terminal has rung its bell and the user has not yet
        /// looked at it. Published so the title and dock badge can follow.
        @Published public var bell: Bool = false

        /// Flash the surface briefly so the user can find it after focus
        /// jumps to another window.
        @MainActor public func highlight() {}

        // Find, font size, reset and binding dispatch live in
        // Tako+SurfaceActions.swift; this is the state they keep.

        /// The theme the configuration asked for. Font size changes are made
        /// relative to it, and resetting the font size returns to it.
        var configuredTheme: TerminalTheme?

        /// Where the find needle is shared with other apps' find bars.
        var findPasteboard: OSPasteboard = .find

        /// The match the find bar last selected, in retained rows.
        var currentSearchMatch: SearchMatch?

        var searchNeedleCancellable: AnyCancellable?

        public private(set) lazy var surfaceModel: Tako.Surface? = Tako.Surface(view: self)

        @Published public private(set) var focused: Bool = true

        public var focusInstant: Date = Date()
        public var readonly: Bool = false
        public var processExited: Bool { pty?.alive == false }
        /// Whether closing this terminal should ask first
        /// (`confirm-close-surface`): never once its shell has exited or when
        /// set false; always when set always; otherwise while a program other
        /// than the shell holds the terminal -- the tty's foreground process
        /// group is not the shell's. That needs no shell integration.
        public var needsConfirmQuit: Bool {
            guard let pty, pty.alive else { return false }
            switch confirmCloseSurface {
            case .never:
                return false
            case .always:
                return true
            case .whenBusy:
                guard let foreground = pty.foregroundPID else { return false }
                return foreground != Int(pty.child)
            }
        }

        /// Set from `confirm-close-surface`.
        var confirmCloseSurface: Tako.Config.ConfirmCloseSurface = .whenBusy

        public var initialSize: NSSize?
        public var surfaceSize: NSSize?

        public var cellSize: NSSize {
            NSSize(width: renderer.metrics.cellWidth, height: renderer.metrics.cellHeight)
        }

        public var pid: Int { Int(pty?.child ?? 0) }
        public var ttyName: String {
            guard let master = pty?.master, let name = ttyname(master) else { return "" }
            return String(cString: name)
        }
        public var visibleText: String {
            (0..<rows).map { core.getLine(row: UInt32($0)) }.joined(separator: "\n")
        }

        @Published public var progressReport: Tako.Action.ProgressReport? = nil
        @Published public var keySequence: [KeyboardShortcut] = []
        public var keyTables: [String] = []
        public var hoverUrl: URL? = nil
        public var childExitedMessage: Tako.ChildExitedMessage? = nil
        public var inspector: Tako.Inspector? = nil
        @Published public var inspectorVisible: Bool = false
        /// The open find bar, or nil when it is closed. Published so the
        /// SwiftUI wrapper shows and hides the bar.
        @Published var searchState: Tako.OSSurfaceView.SearchState? = nil {
            didSet { searchStateDidChange() }
        }
        public var scrollbar: Tako.Action.Scrollbar? = nil

        public var onExit: ((SurfaceView) -> Void)?
        public var onTitleChange: ((SurfaceView) -> Void)?
        public var onFocusRequest: ((SurfaceView) -> Void)?

        public init(
            _ app: Tako.App? = nil,
            baseConfig: Tako.SurfaceConfiguration? = nil,
            uuid: UUID = UUID(),
            theme: TerminalTheme? = nil
        ) {
            self.id = uuid
            self.derivedConfig = app != nil ? DerivedConfig(app!.config) : DerivedConfig()
            self.owningApp = app
            self.parserQueue = DispatchQueue(
                label: "com.tako.parser-\(uuid.uuidString)",
                qos: .userInitiated
            )
            // The terminal -- core, text renderer, Metal stack, input, cursor
            // blinking -- is the inherited surface's. This class only adds the
            // windowing identity around it.
            // The app's config is the one it loaded (TAKO_CONFIG_PATH, a UI
            // test's file); the user's default config is for a surface
            // without an app.
            let baseTheme = theme ?? app?.config.theme ?? TerminalTheme.loadUserConfig()
            // `window-inherit-font-size` (default true): a new window, tab or
            // split starts at the focused terminal's current, possibly
            // zoomed, size rather than the configured default.
            let explicitFontSize = baseConfig?.fontSize.map(CGFloat.init)
            let inheritedFontSize = (app?.config.windowInheritFontSize ?? true) ? Tako.focusedFontSize : nil
            let initialTheme = (explicitFontSize ?? inheritedFontSize)
                .map { Self.scaledTheme(baseTheme, toFontSize: $0) } ?? baseTheme
            super.init(frame: .zero, theme: initialTheme)
            // The surface produces input bytes and hands them to its delegate.
            // Without this every keystroke, mouse report and scroll report is
            // computed and then dropped on the floor.
            delegate = self
            if let app {
                applySurfaceConfig(app.config)
            }
            observeConfigReload()
            // A new tab, split or window opens where the focused one is
            // (`window-inherit-working-directory`, default true); otherwise
            // (including the app's very first terminal, which has no focused
            // one to inherit from) it falls back to `working-directory`.
            let inheritWorkingDirectory = app?.config.windowInheritWorkingDirectory ?? true
            let inherited = baseConfig?.workingDirectory
                ?? (inheritWorkingDirectory ? Tako.focusedWorkingDirectory : nil)
                ?? app.map { Tako.resolvedWorkingDirectory($0.config) }
            setupCoreAndPty(workingDir: inherited)
            if let initial = baseConfig?.initialInput, !initial.isEmpty {
                write(initial)
            }
        }

        public init(frame frameRect: NSRect) {
            let id = UUID()
            self.id = id
            self.derivedConfig = DerivedConfig()
            self.parserQueue = DispatchQueue(
                label: "com.tako.parser-\(id.uuidString)",
                qos: .userInitiated
            )
            super.init(frame: frameRect, theme: TerminalTheme.loadUserConfig())
            delegate = self
            setupCoreAndPty(workingDir: nil)
        }

        required public init?(coder: NSCoder) {
            nil
        }

        // MARK: - TakoTerminalNSViewDelegate

        /// Bytes the surface produced from a keystroke, a paste, or a mouse
        /// report. This is the only path from input to the shell.
        public func terminalView(_ view: TakoTerminalNSView, sendInputData data: Data) {
            writeToShell([UInt8](data))
        }

        /// The engine's own replies -- device attributes, cursor position,
        /// XTVERSION -- which the program asked for and is waiting on.
        public func terminalView(_ view: TakoTerminalNSView, sendDeviceReplyData data: Data) {
            writeToShell([UInt8](data))
        }

        /// The grid changed shape, so the process on the other end has to be
        /// told or it keeps formatting for the old size.
        public func terminalView(_ view: TakoTerminalNSView, didResizeCols cols: Int, rows: Int) {
            pty?.resize(cols: UInt16(max(cols, 1)), rows: UInt16(max(rows, 1)))
        }

        private var configObserver: NSObjectProtocol?
        private weak var owningApp: Tako.App?

        deinit {
            pty?.terminate()
            if let configObserver {
                NotificationCenter.default.removeObserver(configObserver)
            }
        }

        /// `Tako.App.reloadConfig()` replaces the app's config and announces
        /// it; nothing else reaches the surfaces already on screen, so each
        /// one listens and takes what applies to it.
        private func observeConfigReload() {
            configObserver = NotificationCenter.default.addObserver(
                forName: .takoConfigDidChange, object: nil, queue: nil
            ) { [weak self] note in
                guard let config = note.userInfo?[Foundation.Notification.Name.TakoConfigChangeKey]
                        as? Tako.Config else { return }
                // The reload may be announced from any thread; a view is
                // only touched on the main one.
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.configDidReload(config) }
                } else {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.configDidReload(config) }
                    }
                }
            }
        }

        /// Applies a reloaded config -- the theme, and with it font and
        /// colors, and which Option key acts as Alt -- if it is this
        /// surface's app's.
        func configDidReload(_ config: Tako.Config) {
            guard let owningApp, config === owningApp.config else { return }
            applySurfaceConfig(config)
            updateTheme(config.theme)
        }

        /// The config keys that belong to a terminal rather than its window.
        /// Attaches a surface built without an app -- one decoded from saved
        /// window state -- to the app whose window now holds it, so its config
        /// applies and its reloads arrive. A surface that has an app keeps it.
        func adopt(by app: Tako.App) {
            guard owningApp == nil else { return }
            owningApp = app
            derivedConfig = DerivedConfig(app.config)
            applySurfaceConfig(app.config)
            updateTheme(app.config.theme)
            if configObserver == nil {
                observeConfigReload()
            }
        }

        private func applySurfaceConfig(_ config: Tako.Config) {
            optionAsAlt = config.macosOptionAsAlt
            hidesMouseWhileTyping = config.mouseHideWhileTyping
            copyOnSelect = config.copyOnSelect
            confirmCloseSurface = config.confirmCloseSurface
            mouseShiftCapture = config.mouseShiftCapture
            cursorClickToMove = config.cursorClickToMove
            linkURLDetectionEnabled = config.linkURL
            core.setScrollbackLimit(lines: config.scrollbackLimitLines)
        }

        /// Where `copy-on-select` puts a selection by itself: a pasteboard of
        /// the app's own, which `paste_from_selection` reads.
        nonisolated(unsafe) static var selectionPasteboard = NSPasteboard(name: .init("com.tako-core.terminal.selection"))

        /// The general clipboard, for `copy-on-select = clipboard`; tests
        /// substitute a private one.
        var clipboard: NSPasteboard = .general

        /// Set from `copy-on-select`.
        var copyOnSelect: Tako.Config.CopyOnSelect = .selection

        override public func selectionDidFinish() {
            guard copyOnSelect != .off, let text = core.selectedText(), !text.isEmpty else { return }
            var targets = [Self.selectionPasteboard]
            if copyOnSelect == .clipboard {
                targets.append(clipboard)
            }
            for pasteboard in targets {
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }

        private func setupCoreAndPty(workingDir: String?) {

            // Default: when the child shell exits on its own (`exit`, Ctrl-D,
            // the command crashing), close this surface the same way a
            // manual close does, just without the confirmation prompt --
            // there's no live process left to confirm killing. Without this,
            // `pty.readLoop`'s `onExit` (below) fires into a nil closure and
            // the pane just sits there dead: no new prompt, no "process
            // exited" message, nothing. Callers that want different behavior
            // can still overwrite `onExit` after construction.
            onExit = { view in
                NotificationCenter.default.post(
                    name: Tako.Notification.takoCloseSurface,
                    object: view,
                    userInfo: ["process_alive": false]
                )
            }

            // Same story as `onExit`, found the same way (declared, called
            // from real pointer handling -- now the inherited surface's -- and
            // never assigned anywhere in the app target): clicking an unfocused
            // split's pane moved AppKit's own key-view focus there
            // (`makeFirstResponder`, already in `mouseDown`) but never told
            // the controller, so its own `focusedSurface` bookkeeping (the
            // custom tab bar's active-pane state, "new split opens next to
            // the focused one", etc.) stayed on whatever pane was focused
            // before the click. `.takoPresentTerminal` is the existing
            // notification for exactly this -- `takoDidPresentTerminal`
            // already does `Tako.moveFocus(to:)` for it elsewhere.
            onFocusRequest = { view in
                NotificationCenter.default.post(
                    name: Tako.Notification.takoPresentTerminal,
                    object: view
                )
            }

            // Same again: `self.title` (a `@Published` property) is what
            // actually drives the window title text, so this being unwired
            // didn't break that -- but it did mean the custom tab bar (which
            // reads titles by re-drawing, not by observing `$title`) never
            // got told to refresh on its own, only whenever some unrelated
            // event happened to trigger a redraw. A tab's label would sit
            // stale after e.g. `cd`ing to a new directory until something
            // else -- switching tabs, resizing -- forced a repaint.
            onTitleChange = { _ in
                Tako.TabBarController.refreshAll()
            }

            pty = PTY(cols: UInt16(cols), rows: UInt16(rows), workingDirectory: workingDir, config: owningApp?.config)
            pty?.readLoop(targetQueue: parserQueue, onData: { [weak self] data in
                guard let self else { return }
                TakoLog.feed.debug("pty \(data.count)B")
                if data.count <= 200 {
                    let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
                    let printable = String(data.map { ($0 >= 0x20 && $0 < 0x7f) ? Character(UnicodeScalar($0)) : "." })
                    TakoLog.feed.debug("pty hex: \(hex)  [\(printable)]")
                }
                let outcome = self.core.feedWithOutcome(bytes: data)
                if !outcome.output.isEmpty {
                    TakoLog.feed.debug("reply \(outcome.output.count)B")
                }
                if MetalTerminalHost.requiresSynchronousMainApplication(
                    output: outcome.output,
                    events: outcome.events
                ) {
                    DispatchQueue.main.sync {
                        if !outcome.output.isEmpty { self.pty?.write(outcome.output) }
                        for event in outcome.events {
                            switch event {
                            case .bell:
                                NSSound.beep()
                                self.crab.bellRang()
                            case .pwdChanged(let url):
                                self.pwd = URL(string: url)?.path ?? url
                                // A shell that never sets a title still gets one,
                                // the way upstream titles a window by its directory.
                                if let pwd = self.pwd {
                                    self.title = Tako.titleForDirectory(pwd)
                                }
                            case .titleChanged(let title):
                                self.title = title
                                self.onTitleChange?(self)
                            case .clipboardSet(let text):
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                            case .notification(let title, let body):
                                let content = UNMutableNotificationContent()
                                content.title = title
                                content.body = body
                                UNUserNotificationCenter.current().add(
                                    UNNotificationRequest(identifier: UUID().uuidString,
                                                          content: content, trigger: nil))
                            case .progress(let state, let value):
                                self.crab.progressReported(state: state, value: value)
                                self.progressReport = state == 0 ? nil : .init(
                                    state: state == 2 ? .error : (state == 3 ? .indeterminate : .set),
                                    progress: value)
                            case .commandStart:
                                self.crab.commandStarted()
                            case .commandEnd(let exitCode):
                                self.crab.commandEnded(exitCode: exitCode)
                            case .clipboardQuery:
                                let text = NSPasteboard.general.string(forType: .string) ?? ""
                                let replyOutcome = self.core.feedWithOutcome(bytes: Data("\u{1b}]52;c;\(Data(text.utf8).base64EncodedString())\u{07}".utf8))
                                if !replyOutcome.output.isEmpty { self.pty?.write(replyOutcome.output) }
                            }
                        }
                    }
                }
                // The watchdog is main-thread state, so its decision is made
                // there. The redraw request stays on the parser queue, where
                // it coalesces a burst instead of hopping to Main per batch.
                let syncActive = outcome.synchronizedOutputActive
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.applyWatchdogAction(
                        MetalTerminalHost.watchdogAction(
                            isSynchronizedOutputActive: syncActive,
                            watchdogArmed: self.syncOutputTimeoutItem != nil
                        )
                    )
                }
                if !syncActive && outcome.hasDamage {
                    self.requestPtyRedraw()
                }
            }, onExit: { [weak self] in
                DispatchQueue.main.sync {
                    guard let self else { return }
                    self.onExit?(self)
                }
            })

            // Cursor blinking is the inherited surface's, driven by its own
            // display link and suppressed inside a Synchronized Output frame.
        }

        public func focusDidChange(_ focused: Bool) {
            self.focused = focused
            needsDisplay = true
        }

        public func updateTheme(_ newTheme: TerminalTheme) {
            // Assigning the inherited `theme` rebuilds the text renderer and
            // stands up a fresh Metal stack, because font metrics and palette
            // are baked into rasterized glyph masks. Doing any of that here as
            // well is how the two surfaces drifted apart in the first place.
            configuredTheme = newTheme
            applyTheme(newTheme)
        }

        public func pasteText(_ text: String) {
            pty?.write([UInt8](core.encodePaste(text: text)))
        }

        /// Named to match the standard Cocoa Edit-menu action (not, say,
        /// `copySelection`): `App/macOS/MainMenu.xib`'s real "Copy" item
        /// (upstream's own, unmodified) targets the literal selector
        /// `copy:`, so a differently-named method here is simply never
        /// called by Cmd+C or Edit > Copy -- this is the whole reason
        /// copying silently did nothing.
        @objc override public func copy(_ sender: Any?) {
            guard let text = core.selectedText() else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        /// Find items follow the find bar; everything else is the terminal
        /// surface's to decide.
        override public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
            validateFindItem(item.action) ?? super.validateUserInterfaceItem(item)
        }

        @objc override public func paste(_ sender: Any?) {
            guard let text = NSPasteboard.general.string(forType: .string) else { return }
            pasteText(text)
        }

        public func write(_ text: String) {
            writeToShell([UInt8](Data(text.utf8)))
        }

        public func sendText(_ text: String) {
            write(text)
            core.scrollViewportBottom()
            needsDisplay = true
        }

        /// Send a key the way `keyDown` would, but from a caller that has no
        /// NSEvent -- scripting, intents, or a keybinding replay.
        public func send(keyEvent event: Tako.Input.KeyEvent) {
            var ffi = FfiKeyEvent(
                key: .character, text: event.text ?? "",
                physicalText: event.text ?? "", unshiftedText: event.text ?? "",
                shift: event.mods.contains(.shift), alt: event.mods.contains(.alt),
                ctrl: event.mods.contains(.ctrl), superKey: event.mods.contains(.super),
                press: event.action.isPress, repeat: event.action == .repeatKey, composing: false
            )
            if let named = Tako.Input.Key.ffiKeys[event.key] {
                ffi.key = named
            } else if event.key == .space {
                ffi.key = FfiKey.character
                ffi.text = " "
            } else if ffi.text.isEmpty {
                // No text and no key the engine knows: nothing to send.
                return
            }
            guard ffi.press else { return }
            pty?.write([UInt8](core.encodeKey(event: ffi)))
            core.scrollViewportBottom()
            // scheduleRedraw, not a direct needsDisplay: this fires on
            // every keystroke, unconditionally, and a fast TUI app can
            // already be replying -- mid its own Synchronized Output frame
            // -- before this line runs. On a real keyboard the two
            // essentially never race meaningfully; a burst of programmatic
            // or fast-repeat keystrokes is exactly when they can.
            scheduleRedraw()
        }

        public func send(mouseButton event: Tako.Input.MouseButtonEvent) {
            guard let cell = mouseCell else { return }
            let button: FfiMouseButton = switch event.button {
            case .left: .left
            case .right: .right
            case .middle: .middle
            case .unknown: .none
            }
            let bytes = core.encodeMouse(event: FfiMouseEvent(
                button: button,
                action: event.action == .press ? .press : .release,
                shift: event.mods.contains(.shift),
                alt: event.mods.contains(.alt),
                ctrl: event.mods.contains(.ctrl),
                col: UInt32(cell.col), row: UInt32(cell.row)))
            pty?.write([UInt8](bytes))
        }

        public func send(mousePos event: Tako.Input.MousePosEvent) {
            setMouseCell(cellAt(NSPoint(x: event.x, y: event.y)))
        }

        public func send(mouseScroll event: Tako.Input.MouseScrollEvent) {
            let lines = Int(event.y.rounded())
            guard lines != 0 else { return }
            let cell = mouseCell ?? (row: 0, col: 0)
            let report = mouseReportBytes(
                button: lines > 0 ? .wheelUp : .wheelDown, action: .press, cell: cell)
            guard report.isEmpty else {
                writeToShell([UInt8](report))
                return
            }
            if lines > 0 {
                core.scrollViewportUp(lines: UInt32(lines))
            } else {
                core.scrollViewportDown(lines: UInt32(-lines))
            }
            needsDisplay = true
        }

        /// True while the running program has asked to receive mouse events
        /// itself, which is when the app must stop interpreting them.
        /// Read through `modes()`, not `snapshot()`: a snapshot takes the
        /// frame's damage list, which the renderer then never sees.
        public var mouseCaptured: Bool { core.modes().mouseTracking != .off }

        public func close() {
            pty?.terminate()
        }

        public func toggleReadonly(_ sender: Any?) {
            readonly.toggle()
        }

        /// Upstream's implementation, verbatim (SurfaceView_AppKit.swift) --
        /// pure logic with no dependency on the IME/marked-text machinery
        /// this shim doesn't carry, so it needed no adaptation.
        ///
        /// True when `text` is a single C0 control character (U+0000-U+001F)
        /// arriving while the IME is composing. Such input belongs to the IME
        /// and must not be forwarded to the terminal.
        // The parent already provides this rule; the app layer used to carry
        // its own copy of it.
        static func surfaceShouldSuppressComposingControlInput(
            _ text: String?,
            composing: Bool
        ) -> Bool {
            guard composing, let text else { return false }
            let scalars = text.unicodeScalars
            guard let scalar = scalars.first,
                  scalars.index(after: scalars.startIndex) == scalars.endIndex else {
                return false
            }
            return scalar.value < 0x20
        }
    }
}

/// Upstream's AppDelegate declares conformance to this; it is the protocol
/// its app-level code calls back into.
protocol TakoAppDelegate: AnyObject {
    func findSurface(forUUID uuid: UUID) -> Tako.SurfaceView?
}

extension TakoAppDelegate {
    func findSurface(forUUID uuid: UUID) -> Tako.SurfaceView? { nil }
}

/// A value that is expensive to compute and is asked for more than once.
/// It is recomputed only after `invalidate()`.
public final class CachedValue<T> {
    private let compute: () -> T
    private var cached: T?

    public init(_ compute: @escaping () -> T) {
        self.compute = compute
    }

    public func get() -> T {
        if let cached { return cached }
        let value = compute()
        cached = value
        return value
    }

    public func invalidate() { cached = nil }
}
