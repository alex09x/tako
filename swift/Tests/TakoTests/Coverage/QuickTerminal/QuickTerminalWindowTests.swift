import Testing
import AppKit
@testable import Tako

@MainActor
struct QuickTerminalWindowTests {
    private func makeWindow() -> QuickTerminalWindow {
        QuickTerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false)
    }

    @Test func canBecomeKeyAndMainAreAlwaysTrue() {
        let window = makeWindow()
        #expect(window.canBecomeKey)
        #expect(window.canBecomeMain)
    }

    @Test func awakeFromNibConfiguresIdentifierAndStyleMask() {
        let window = makeWindow()
        window.awakeFromNib()
        #expect(window.identifier == NSUserInterfaceItemIdentifier("com.tako-core.terminal.quickTerminal"))
        #expect(!window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.nonactivatingPanel))
    }

    @Test func setFrameUsesInitialFrameOverrideWhenPresent() {
        let window = makeWindow()
        let override = NSRect(x: 10, y: 20, width: 30, height: 40)
        window.initialFrame = override
        window.setFrame(NSRect(x: 999, y: 999, width: 999, height: 999), display: false)
        #expect(window.frame == override)
    }

    @Test func setFrameUsesPassedRectWhenNoInitialFrameIsSet() {
        let window = makeWindow()
        window.initialFrame = nil
        let requested = NSRect(x: 1, y: 2, width: 300, height: 150)
        window.setFrame(requested, display: false)
        #expect(window.frame == requested)
    }
}
