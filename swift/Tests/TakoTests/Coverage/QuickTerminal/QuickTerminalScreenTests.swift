import Testing
import AppKit
@testable import Tako

// QuickTerminalScreen has no Equatable conformance, so cases are compared via
// pattern matching rather than `==`.
private func isMain(_ screen: QuickTerminalScreen?) -> Bool {
    if case .main = screen { return true }
    return false
}
private func isMouse(_ screen: QuickTerminalScreen?) -> Bool {
    if case .mouse = screen { return true }
    return false
}
private func isMenuBar(_ screen: QuickTerminalScreen?) -> Bool {
    if case .menuBar = screen { return true }
    return false
}

@MainActor
struct QuickTerminalScreenTests {
    @Test func fromTakoConfigParsesEachKnownString() {
        #expect(isMain(QuickTerminalScreen(fromTakoConfig: "main")))
        #expect(isMouse(QuickTerminalScreen(fromTakoConfig: "mouse")))
        #expect(isMenuBar(QuickTerminalScreen(fromTakoConfig: "macos-menu-bar")))
    }

    @Test func fromTakoConfigRejectsUnknownStrings() {
        #expect(QuickTerminalScreen(fromTakoConfig: "not-a-real-value") == nil)
        #expect(QuickTerminalScreen(fromTakoConfig: "") == nil)
    }

    @Test func mainScreenResolvesToNSScreenMain() {
        #expect(QuickTerminalScreen.main.screen == NSScreen.main)
    }

    @Test func menuBarScreenResolvesToFirstScreen() {
        #expect(QuickTerminalScreen.menuBar.screen == NSScreen.screens.first)
    }

    @Test func mouseScreenResolvesToScreenContainingTheMouseLocation() {
        // NSEvent.mouseLocation is real hardware state we can't move from a
        // test, but every screen's frame partitions the display space, so
        // whichever screen (if any) contains it is independently verifiable.
        let expected = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
        #expect(QuickTerminalScreen.mouse.screen == expected)
    }
}
