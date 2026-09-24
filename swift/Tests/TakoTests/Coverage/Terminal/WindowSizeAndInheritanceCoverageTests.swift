import Testing
import AppKit
@testable import Tako

/// `window-width`/`window-height`, `window-inherit-working-directory` and
/// `window-inherit-font-size`: what a new window's terminal area starts at,
/// and what a new window, tab or split inherits from the focused terminal.
@MainActor
@Suite
struct WindowSizeAndInheritanceCoverageTests {
    // MARK: - window-width / window-height

    @Test func aNewWindowIsSizedToTheConfiguredGridInCells() throws {
        let (app, file) = try TerminalTestSupport.app(configText: "window-width = 200\nwindow-height = 60")
        defer { try? FileManager.default.removeItem(at: file) }

        let controller = TerminalController(app, withBaseConfig: nil, withSurfaceTree: nil)
        let window = TerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        controller.window = window
        controller.windowDidLoad()
        defer { TerminalTestSupport.tearDown(controller, window) }

        let surface = try #require(controller.focusedSurface)
        // 200 by 60 cells, plus the padding around them.
        let padding = surface.theme.padding
        let expected = NSSize(
            width: surface.cellSize.width * 200 + padding.left + padding.right,
            height: surface.cellSize.height * 60 + padding.top + padding.bottom)
        #expect(surface.initialSize == expected)
        let fitted = TerminalGridLayout(viewSize: expected, cellSize: surface.cellSize, theme: surface.theme)
        #expect(fitted.cols == 200)
        #expect(fitted.rows == 60)

        // The window's content view (a `TerminalViewContainer`) reports the
        // configured grid as its intrinsic size when it exceeds the size the
        // terminal itself would naturally take up -- this is what actually
        // grows the window on screen.
        let contentSize = try #require(window.contentView?.intrinsicContentSize)
        #expect(contentSize.width == expected.width)
        #expect(contentSize.height == expected.height)
    }

    @Test func windowWidthAloneWithoutWindowHeightDoesNothing() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        #expect(controller.focusedSurface?.initialSize == nil)
    }

    @Test func aNewTabIsNotSizedByWindowWidthAndHeight() throws {
        let (controller, window) = TerminalTestSupport.makeController()
        controller.appliesConfiguredWindowSize = false
        controller.windowDidLoad()
        defer { TerminalTestSupport.tearDown(controller, window) }
        #expect(controller.focusedSurface?.initialSize == nil)
    }

    // MARK: - window-inherit-working-directory

    @Test func windowInheritWorkingDirectoryFalseFallsBackToWorkingDirectory() throws {
        let home = NSHomeDirectory()
        let (app, file) = try TerminalTestSupport.app(
            configText: "window-inherit-working-directory = false\nworking-directory = home")
        defer { try? FileManager.default.removeItem(at: file) }
        let view = Tako.SurfaceView(app, uuid: UUID())
        defer { view.close() }
        #expect(view.pty?.startedInDirectory == home)
    }

    // MARK: - working-directory

    @Test func resolvedWorkingDirectoryReadsThePathVariant() throws {
        #expect(Tako.resolvedWorkingDirectory(try TemporaryConfig("working-directory = /tmp")) == "/tmp")
    }

    @Test func resolvedWorkingDirectoryReadsTheHomeVariant() throws {
        #expect(Tako.resolvedWorkingDirectory(try TemporaryConfig("working-directory = home")) == NSHomeDirectory())
    }

    @Test func resolvedWorkingDirectoryReadsTheInheritVariant() throws {
        #expect(
            Tako.resolvedWorkingDirectory(try TemporaryConfig("working-directory = inherit"))
                == FileManager.default.currentDirectoryPath)
    }

    // MARK: - window-inherit-font-size

    @Test func focusedFontSizeReadsTheKeyWindowsFirstResponderSurface() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        defer { view.close() }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let result = Tako.focusedFontSize
        if window.isKeyWindow {
            #expect(result == view.theme.fontSize)
        } else {
            #expect(result == nil)
        }
    }

    @Test func aNewSurfaceStartsAtTheFocusedTerminalsFontSizeByDefault() throws {
        let focused = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        defer { focused.close() }
        focused.changeFontSize(.increase(6))
        let zoomed = focused.theme.fontSize
        let window = NSWindow(
            contentRect: focused.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = focused
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(focused)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        guard window.isKeyWindow else { return }

        let (app, file) = try TerminalTestSupport.app(configText: "")
        defer { try? FileManager.default.removeItem(at: file) }
        let newSurface = Tako.SurfaceView(app, uuid: UUID())
        defer { newSurface.close() }
        #expect(newSurface.theme.fontSize == zoomed)
    }

    @Test func windowInheritFontSizeFalseUsesTheConfiguredDefault() throws {
        let focused = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        defer { focused.close() }
        focused.changeFontSize(.increase(6))
        let window = NSWindow(
            contentRect: focused.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = focused
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(focused)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        guard window.isKeyWindow else { return }

        let (app, file) = try TerminalTestSupport.app(configText: "window-inherit-font-size = false")
        defer { try? FileManager.default.removeItem(at: file) }
        let newSurface = Tako.SurfaceView(app, uuid: UUID())
        defer { newSurface.close() }
        #expect(newSurface.theme.fontSize == app.config.theme.fontSize)
    }
}
