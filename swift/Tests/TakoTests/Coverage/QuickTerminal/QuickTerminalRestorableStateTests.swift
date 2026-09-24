import Testing
import AppKit
@testable import Tako

@MainActor
struct QuickTerminalRestorableStateTests {
    @Test func capturesTheFocusedSurfaceAndSurfaceTreeFromTheController() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let surface = try #require(controller.focusedSurface)

        let state = QuickTerminalRestorableState(from: controller)

        #expect(state.focusedSurface == surface.id.uuidString)
        #expect(state.surfaceTree.contains(surface))
    }

    @Test func capturesScreenStateWhenTheHostScreenHasAStableDisplayUUID() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let screen = try #require(window.screen ?? NSScreen.main)

        let state = QuickTerminalRestorableState(from: controller)

        if screen.displayUUID != nil {
            #expect(!state.screenStateEntries.isEmpty)
        } else {
            #expect(state.screenStateEntries.isEmpty)
        }
    }

    @Test func baseConfigTagsTheQuickTerminalEnvironmentVariable() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let state = QuickTerminalRestorableState(from: controller)
        #expect(state.baseConfig?.environmentVariables["TAKO_QUICK_TERMINAL"] == "1")
    }

    @Test func copyInitProducesAnEquivalentState() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let original = QuickTerminalRestorableState(from: controller)

        let copy = QuickTerminalRestorableState(copy: original)

        #expect(copy.focusedSurface == original.focusedSurface)
        #expect(copy.screenStateEntries.count == original.screenStateEntries.count)
    }

    @Test func versionIsOne() {
        #expect(QuickTerminalRestorableState.version == 1)
    }
}
