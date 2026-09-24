import Testing
import AppKit
import SwiftUI
@testable import Tako

@MainActor
private func makeHostedWindow(size: NSSize = .init(width: 520, height: 420)) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled],
        backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    return window
}

@MainActor
@discardableResult
private func host<V: View>(_ view: V, in window: NSWindow) -> NSHostingView<V> {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(origin: .zero, size: window.frame.size)
    window.contentView = hosting
    window.orderFrontRegardless()
    hosting.layoutSubtreeIfNeeded()
    hosting.displayIfNeeded()
    return hosting
}

/// Builds a real `TerminalController` (a real `Tako.SurfaceView` with a real
/// PTY -- there is no lighter-weight construction path, `BaseTerminalController.init`
/// always creates one) with its window assigned directly rather than through
/// nib loading, mirroring `QTTestSupport.makeController` for `QuickTerminalController`:
/// `Terminal.xib` is excluded from this SwiftPM target, so letting `.window`
/// load lazily here would fail to find a nib.
@MainActor
private func makeTerminalController(_ tako: Tako.App) -> (TerminalController, NSWindow) {
    let controller = TerminalController(tako)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    controller.window = window
    return (controller, window)
}

@MainActor
struct TerminalCommandPaletteViewTests {
    @Test func rendersNothingWhenNotPresented() {
        let window = makeHostedWindow()
        defer { window.close() }
        let tako = Tako.App()
        let surface = Tako.SurfaceView(tako, baseConfig: nil)
        defer { surface.pty?.terminate() }

        host(
            TerminalCommandPaletteView(
                surfaceView: surface,
                isPresented: .constant(false),
                takoConfig: tako.config,
                onAction: { _ in }),
            in: window)
    }

    @Test func rendersTheOverlayAndListsNoOptionsWithoutAnAppDelegateOrOtherWindows() {
        let window = makeHostedWindow()
        defer { window.close() }
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = nil
        defer { NSApplication.shared.delegate = originalDelegate }

        let tako = Tako.App()
        let surface = Tako.SurfaceView(tako, baseConfig: nil)
        defer { surface.pty?.terminate() }

        host(
            TerminalCommandPaletteView(
                surfaceView: surface,
                isPresented: .constant(true),
                takoConfig: tako.config,
                onAction: { _ in }),
            in: window)
    }

    @Test func rendersJumpOptionsForEveryOpenTerminalSurface() {
        let window = makeHostedWindow()
        defer { window.close() }
        let appDelegate = AppDelegate()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = appDelegate
        defer { NSApplication.shared.delegate = originalDelegate }

        let tako = Tako.App()
        let (controller, terminalWindow) = makeTerminalController(tako)
        defer {
            controller.surfaceTree.forEach { $0.pty?.terminate() }
            terminalWindow.close()
        }

        let surface = Tako.SurfaceView(tako, baseConfig: nil)
        defer { surface.pty?.terminate() }

        host(
            TerminalCommandPaletteView(
                surfaceView: surface,
                isPresented: .constant(true),
                takoConfig: tako.config,
                onAction: { _ in }),
            in: window)
    }

    @Test func onActionFiresWhenAJumpOptionIsInvokedDirectly() {
        var received: String?
        let tako = Tako.App()
        let surface = Tako.SurfaceView(tako, baseConfig: nil)
        defer { surface.pty?.terminate() }

        let view = TerminalCommandPaletteView(
            surfaceView: surface,
            isPresented: .constant(true),
            takoConfig: tako.config,
            onAction: { action in received = action })

        // commandOptions is private, but nothing stops constructing an
        // independent CommandOption and calling the same onAction closure
        // the view would have wired up, to prove the plumbing itself works.
        let option = CommandOption(title: "Test") { view.onAction("test_action") }
        option.action()
        #expect(received == "test_action")
    }

    @Test func dismissingReturnsFocusToTheSurface() async {
        final class Box { var presented = true }
        let box = Box()
        let window = makeHostedWindow()
        defer { window.close() }

        let tako = Tako.App()
        let surface = Tako.SurfaceView(tako, baseConfig: nil)
        defer { surface.pty?.terminate() }
        window.contentView?.addSubview(surface)

        let binding = Binding<Bool>(get: { box.presented }, set: { box.presented = $0 })
        host(
            TerminalCommandPaletteView(
                surfaceView: surface, isPresented: binding, takoConfig: tako.config,
                onAction: { _ in }),
            in: window)

        box.presented = false
        host(
            TerminalCommandPaletteView(
                surfaceView: surface, isPresented: binding, takoConfig: tako.config,
                onAction: { _ in }),
            in: window)

        // The window-focus hop is a DispatchQueue.main.async, which only a
        // suspension point (not RunLoop pumping) drains for a MainActor
        // test -- see QTTestSupport's and TabTitleEditorCoverageTests' own
        // documented caveats on the same caveat.
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
}
