import AppKit
import Foundation
import Testing
@testable import Tako

/// Config keys a terminal applies to itself: how much history it keeps,
/// hiding the pointer while typing, and copying a finished selection.
@Suite
struct SurfaceTerminalConfigTests {
    private func app(_ text: String) throws -> (Tako.App, URL) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("tako")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return (Tako.App(configPath: file.path), file)
    }

    @Test @MainActor
    func theKeysAreReadWithUpstreamsDefaults() throws {
        let (defaults, file1) = try app("")
        let (set, file2) = try app("""
            scrollback-limit = 2500000
            mouse-hide-while-typing = true
            copy-on-select = clipboard
            """)
        let (bad, file3) = try app("scrollback-limit = lots\ncopy-on-select = maybe\n")
        defer { [file1, file2, file3].forEach { try? FileManager.default.removeItem(at: $0) } }

        #expect(defaults.config.scrollbackLimitLines == 10_000)
        #expect(defaults.config.mouseHideWhileTyping == false)
        #expect(defaults.config.copyOnSelect == .selection)

        #expect(set.config.scrollbackLimitLines == 2500)
        #expect(set.config.mouseHideWhileTyping)
        #expect(set.config.copyOnSelect == .clipboard)

        #expect(bad.config.scrollbackLimitLines == 10_000)
        #expect(bad.config.copyOnSelect == .selection)
    }

    @Test @MainActor
    func aSurfaceKeepsOnlyAsMuchHistoryAsTheConfigAllows() throws {
        // 20,000 bytes: 20 lines.
        let (app, file) = try app("scrollback-limit = 20000\nmouse-hide-while-typing = true\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let view = Tako.SurfaceView(app, uuid: UUID())
        defer { view.close() }

        #expect(view.hidesMouseWhileTyping)
        view.core.feed(bytes: Data((0..<200).map { "line \($0)\r\n" }.joined().utf8))
        #expect(view.core.scrollbackLen() <= 20)
    }

    @MainActor private func selecting(_ view: Tako.SurfaceView) {
        view.core.feed(bytes: Data("hello world".utf8))
        view.core.startSelection(row: 0, col: 0, mode: .linear)
        view.core.extendSelection(row: 0, col: 4)
    }

    @Test @MainActor
    func aFinishedSelectionIsCopiedWhereTheConfigSays() throws {
        let selectionBoard = NSPasteboard(name: .init("tako-test-\(UUID().uuidString)"))
        let clipboard = NSPasteboard(name: .init("tako-test-\(UUID().uuidString)"))
        let original = Tako.SurfaceView.selectionPasteboard
        Tako.SurfaceView.selectionPasteboard = selectionBoard
        defer {
            Tako.SurfaceView.selectionPasteboard = original
            selectionBoard.releaseGlobally()
            clipboard.releaseGlobally()
        }
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        view.clipboard = clipboard
        selecting(view)

        view.copyOnSelect = .off
        view.selectionDidFinish()
        #expect(selectionBoard.string(forType: .string) == nil)

        view.copyOnSelect = .selection
        view.selectionDidFinish()
        #expect(selectionBoard.string(forType: .string) == "hello")
        #expect(clipboard.string(forType: .string) == nil)

        view.copyOnSelect = .clipboard
        view.selectionDidFinish()
        #expect(clipboard.string(forType: .string) == "hello")
    }

    @Test @MainActor
    func pasteFromSelectionUsesTheSelectionPasteboard() {
        let selectionBoard = NSPasteboard(name: .init("tako-test-\(UUID().uuidString)"))
        let original = Tako.SurfaceView.selectionPasteboard
        Tako.SurfaceView.selectionPasteboard = selectionBoard
        defer {
            Tako.SurfaceView.selectionPasteboard = original
            selectionBoard.releaseGlobally()
        }
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        #expect(!view.performBindingAction("paste_from_selection"), "nothing selected yet")
        selectionBoard.clearContents()
        selectionBoard.setString("echo hi", forType: .string)
        #expect(view.performBindingAction("paste_from_selection"))
        #expect(Tako.SurfaceView.isBindingActionSupported("paste_from_selection"))
    }
}

/// Closing a terminal, or quitting, asks first while a program is running in
/// it. It never did: every surface said no confirmation was needed, so Cmd-Q
/// or closing a window killed a running editor or build without a word.
@Suite
struct SurfaceConfirmCloseTests {
    @Test @MainActor
    func theKeyIsReadWithUpstreamsDefault() throws {
        for (text, expected) in [
            ("", Tako.Config.ConfirmCloseSurface.whenBusy),
            ("confirm-close-surface = false", .never),
            ("confirm-close-surface = always", .always),
            ("confirm-close-surface = sometimes", .whenBusy),
        ] {
            let config = try TemporaryConfig(text)
            #expect(config.confirmCloseSurface == expected, "\(text)")
        }
    }

    @Test @MainActor
    func anIdleShellClosesWithoutAskingAndABusyOneAsks() async throws {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        // A shell's startup files may run programs of their own; wait for it
        // to settle at its prompt.
        func eventually(_ condition: () -> Bool) async throws -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while !condition(), Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            return condition()
        }
        #expect(try await eventually { !view.needsConfirmQuit }, "the shell itself holds the terminal")

        view.write("sleep 30\r")
        #expect(try await eventually { view.needsConfirmQuit }, "sleep holds the terminal")

        view.confirmCloseSurface = .never
        #expect(!view.needsConfirmQuit)
    }

    @Test @MainActor
    func alwaysAsksWhileTheShellLives() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        view.confirmCloseSurface = .always
        #expect(view.needsConfirmQuit)
    }
}
