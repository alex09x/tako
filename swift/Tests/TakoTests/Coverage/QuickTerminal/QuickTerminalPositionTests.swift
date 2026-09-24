import Testing
import AppKit
@testable import Tako

@MainActor
struct QuickTerminalPositionTests {
    // A fixed, mock geometry so origin math is exact and doesn't depend on
    // whatever physical display this test happens to run on.
    //   frame:        (0, 0, 2000, 1200)
    //   visibleFrame: (0, 25, 2000, 1150)  (minY 25, maxY 1175)
    private let screen = MockGeometryScreen(
        frame: NSRect(x: 0, y: 0, width: 2000, height: 1200),
        visibleFrame: NSRect(x: 0, y: 25, width: 2000, height: 1150))

    private func window(width: CGFloat = 400, height: CGFloat = 300, x: CGFloat = 0, y: CGFloat = 0) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        return w
    }

    @Test func initialOriginForEachPosition() {
        let win = window()
        #expect(QuickTerminalPosition.top.initialOrigin(for: win, on: screen) == CGPoint(x: 800, y: 1175))
        #expect(QuickTerminalPosition.bottom.initialOrigin(for: win, on: screen) == CGPoint(x: 800, y: -300))
        #expect(QuickTerminalPosition.left.initialOrigin(for: win, on: screen) == CGPoint(x: -400, y: 450))
        #expect(QuickTerminalPosition.right.initialOrigin(for: win, on: screen) == CGPoint(x: 2000, y: 450))
        // NOTE: pins current behavior, which reuses window.frame.width (not height) here.
        #expect(QuickTerminalPosition.center.initialOrigin(for: win, on: screen) == CGPoint(x: 800, y: 750))
    }

    @Test func finalOriginForEachPosition() {
        let win = window()
        #expect(QuickTerminalPosition.top.finalOrigin(for: win, on: screen) == CGPoint(x: 800, y: 875))
        #expect(QuickTerminalPosition.bottom.finalOrigin(for: win, on: screen) == CGPoint(x: 800, y: 25))
        #expect(QuickTerminalPosition.left.finalOrigin(for: win, on: screen) == CGPoint(x: 0, y: 450))
        #expect(QuickTerminalPosition.right.finalOrigin(for: win, on: screen) == CGPoint(x: 1600, y: 450))
        #expect(QuickTerminalPosition.center.finalOrigin(for: win, on: screen) == CGPoint(x: 800, y: 450))
    }

    @Test func centeredOriginPreservesYForTopAndBottomButRecomputesX() {
        let win = window(x: 10, y: 999)
        #expect(QuickTerminalPosition.top.centeredOrigin(for: win, on: screen) == CGPoint(x: 800, y: 999))
        #expect(QuickTerminalPosition.bottom.centeredOrigin(for: win, on: screen) == CGPoint(x: 800, y: 999))
    }

    @Test func centeredOriginRecomputesBothAxesForCenter() {
        let win = window(x: 10, y: 999)
        #expect(QuickTerminalPosition.center.centeredOrigin(for: win, on: screen) == CGPoint(x: 800, y: 450))
    }

    @Test func centeredOriginIsANoOpForLeftAndRight() {
        let win = window(x: 42, y: 77)
        #expect(QuickTerminalPosition.left.centeredOrigin(for: win, on: screen) == win.frame.origin)
        #expect(QuickTerminalPosition.right.centeredOrigin(for: win, on: screen) == win.frame.origin)
    }

    @Test func verticallyCenteredOriginPreservesXForLeftAndRightButRecomputesY() {
        let win = window(x: 321, y: 12)
        #expect(QuickTerminalPosition.left.verticallyCenteredOrigin(for: win, on: screen) == CGPoint(x: 321, y: 450))
        #expect(QuickTerminalPosition.right.verticallyCenteredOrigin(for: win, on: screen) == CGPoint(x: 321, y: 450))
    }

    @Test func verticallyCenteredOriginIsANoOpForTopBottomAndCenter() {
        let win = window(x: 5, y: 6)
        #expect(QuickTerminalPosition.top.verticallyCenteredOrigin(for: win, on: screen) == win.frame.origin)
        #expect(QuickTerminalPosition.bottom.verticallyCenteredOrigin(for: win, on: screen) == win.frame.origin)
        #expect(QuickTerminalPosition.center.verticallyCenteredOrigin(for: win, on: screen) == win.frame.origin)
    }

    @Test func configuredFrameSizeMatchesQuickTerminalSizeCalculate() {
        let size = QuickTerminalSize()
        let expected = size.calculate(position: .top, screenDimensions: screen.visibleFrame.size)
        let got = QuickTerminalPosition.top.configuredFrameSize(on: screen, terminalSize: size)
        #expect(got.width == expected.width)
        #expect(got.height == expected.height)
    }

    @Test func setLoadedAppliesCalculatedSizeAndKeepsOrigin() {
        let win = window(width: 10, height: 10, x: 3, y: 4)
        let originalOrigin = win.frame.origin
        QuickTerminalPosition.top.setLoaded(win, size: QuickTerminalSize())
        // setLoaded falls back to `window.screen ?? NSScreen.main`, which is real
        // on this host, so compute the expectation off the same fallback.
        let effectiveScreen = win.screen ?? NSScreen.main
        guard let effectiveScreen else {
            Issue.record("no screen available to compute expectation against")
            return
        }
        let expected = QuickTerminalSize().calculate(position: .top, screenDimensions: effectiveScreen.visibleFrame.size)
        #expect(win.frame.size.width == expected.width)
        #expect(win.frame.size.height == expected.height)
        #expect(win.frame.origin == originalOrigin)
    }

    @Test func setInitialMakesWindowInvisibleAndUsesConfiguredSizeWhenNoClosedFrame() {
        let win = window(width: 10, height: 10)
        // `setInitial` computes the origin from the window's frame *before*
        // resizing it (both are folded into a single `setFrame` call), so
        // the expectation must be captured against that same pre-resize frame.
        let expectedOrigin = QuickTerminalPosition.top.initialOrigin(for: win, on: screen)

        QuickTerminalPosition.top.setInitial(in: win, on: screen, terminalSize: QuickTerminalSize())

        #expect(win.alphaValue == 0)
        let expectedSize = QuickTerminalPosition.top.configuredFrameSize(on: screen, terminalSize: QuickTerminalSize())
        #expect(win.frame.size.width == expectedSize.width)
        #expect(win.frame.size.height == expectedSize.height)
        #expect(win.frame.origin == expectedOrigin)
    }

    @Test func setInitialUsesClosedFrameSizeWhenProvided() {
        let win = window(width: 10, height: 10)
        let closed = NSRect(x: 0, y: 0, width: 123, height: 456)
        QuickTerminalPosition.top.setInitial(in: win, on: screen, terminalSize: QuickTerminalSize(), closedFrame: closed)
        #expect(win.frame.size == closed.size)
    }

    @Test func setFinalMakesWindowVisibleAndUsesConfiguredSizeWhenNoClosedFrame() {
        let win = window(width: 10, height: 10)
        QuickTerminalPosition.bottom.setFinal(in: win, on: screen, terminalSize: QuickTerminalSize())
        #expect(win.alphaValue == 1)
        let expectedSize = QuickTerminalPosition.bottom.configuredFrameSize(on: screen, terminalSize: QuickTerminalSize())
        #expect(win.frame.size.width == expectedSize.width)
        #expect(win.frame.size.height == expectedSize.height)
    }

    @Test func setFinalUsesClosedFrameSizeWhenProvided() {
        let win = window(width: 10, height: 10)
        let closed = NSRect(x: 0, y: 0, width: 77, height: 88)
        QuickTerminalPosition.bottom.setFinal(in: win, on: screen, terminalSize: QuickTerminalSize(), closedFrame: closed)
        #expect(win.frame.size == closed.size)
    }

    @Test func centerNeverConflictsWithDockRegardlessOfOrientation() {
        // hasDock forced true: visible frame is narrower than the full frame.
        let dockedScreen = MockGeometryScreen(
            frame: NSRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: NSRect(x: 0, y: 0, width: 900, height: 800))
        // `.center` never appears in QuickTerminalPosition.conflictsWithDock's
        // switch over dock orientation, so it can never conflict.
        #expect(!QuickTerminalPosition.center.conflictsWithDock(on: dockedScreen))
    }

    @Test func noConflictWhenScreenHasNoDock() {
        // `hasDock`'s no-dock branch reads `NSApp.mainMenu`; force `NSApp`
        // to exist first so a filtered run that hits this test before any
        // window creation doesn't crash on its implicitly-unwrapped nil.
        _ = NSApplication.shared
        // Equal frame/visibleFrame with no menu bar/notch means hasDock is false,
        // so conflictsWithDock must short-circuit to false for every position.
        let rect = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let dockless = MockGeometryScreen(frame: rect, visibleFrame: rect)
        for position: QuickTerminalPosition in [.top, .bottom, .left, .right, .center] {
            #expect(!position.conflictsWithDock(on: dockless))
        }
    }

    @Test func conflictsWithDockFollowsTheEdgeTheDockIsOn() {
        let conflicting: [DockOrientation: Set<QuickTerminalPosition>] = [
            .top: [.top, .left, .right],
            .bottom: [.bottom, .left, .right],
            .left: [.top, .bottom],
            .right: [.top, .bottom],
        ]
        for (orientation, expected) in conflicting {
            for position: QuickTerminalPosition in [.top, .bottom, .left, .right, .center] {
                let conflicts = position.conflictsWithDock(screenHasDock: true, orientation: orientation)
                #expect(conflicts == expected.contains(position), "\(position) with the dock at \(orientation)")
            }
        }
    }

    @Test func noDockOrAnUnknownEdgeNeverConflicts() {
        for position: QuickTerminalPosition in [.top, .bottom, .left, .right, .center] {
            #expect(!position.conflictsWithDock(screenHasDock: false, orientation: .bottom))
            #expect(!position.conflictsWithDock(screenHasDock: true, orientation: nil))
        }
    }

    @Test func conflictsWithDockOnAScreenAsksThatScreenAndThisMacsDock() {
        _ = NSApplication.shared
        let dockedScreen = MockGeometryScreen(
            frame: NSRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: NSRect(x: 0, y: 0, width: 900, height: 800))
        for position: QuickTerminalPosition in [.top, .bottom, .left, .right, .center] {
            let expected = position.conflictsWithDock(
                screenHasDock: dockedScreen.hasDock, orientation: Dock.orientation)
            #expect(position.conflictsWithDock(on: dockedScreen) == expected)
        }
    }
}
