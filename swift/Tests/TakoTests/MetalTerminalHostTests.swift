import CoreGraphics
import Foundation
import Testing
@testable import Tako

/// The AppKit half of the GPU terminal path.
///
/// `MetalTerminalRendererTests` already covers what the shared renderer does
/// with a frame; these cover what the macOS surface has to get right before
/// handing one over -- the layer geometry, the theme colors, the cursor
/// policy, and the decision to fall back to CoreText at all. None of it needs
/// a GPU, a window server or a shader library, so it runs anywhere.
struct MetalTerminalHostTests {
    private typealias Host = Tako.MetalTerminalHost

    // MARK: - Layer geometry

    @Test func layerSitsInsideThePaddingAndRendersRealPixels() {
        let geometry = Host.layerGeometry(
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            padding: 10,
            scale: 2)

        #expect(geometry.frame == CGRect(x: 10, y: 10, width: 780, height: 580))
        #expect(geometry.contentsScale == 2)
        // Backing scale, applied once: `drawableSize` is already in pixels.
        #expect(geometry.drawableSize == CGSize(width: 1560, height: 1160))
        #expect(geometry.isRenderable)
    }

    @Test func drawableIsAWholeNumberOfPixels() {
        let geometry = Host.layerGeometry(
            bounds: CGRect(x: 0, y: 0, width: 100.5, height: 50.25),
            padding: 0,
            scale: 1.5)

        #expect(geometry.drawableSize.width == 150)
        #expect(geometry.drawableSize.height == 75)
    }

    /// A pane collapsed smaller than its own padding must report an empty
    /// drawable rather than a negative one, so the frame is skipped instead of
    /// asking Metal for an impossible texture.
    @Test func surfaceSmallerThanItsPaddingIsNotRenderable() {
        let geometry = Host.layerGeometry(
            bounds: CGRect(x: 0, y: 0, width: 8, height: 4),
            padding: 10,
            scale: 2)

        #expect(geometry.frame.size == CGSize(width: 0, height: 0))
        #expect(geometry.drawableSize == CGSize(width: 0, height: 0))
        #expect(!geometry.isRenderable)
    }

    /// A scale below 1 would shrink the drawable under the layer, which reads
    /// as a blurry terminal rather than as an error.
    @Test func scaleIsClampedToAtLeastOne() {
        let geometry = Host.layerGeometry(
            bounds: CGRect(x: 0, y: 0, width: 200, height: 100),
            padding: 0,
            scale: 0)

        #expect(geometry.contentsScale == 1)
        #expect(geometry.drawableSize == CGSize(width: 200, height: 100))
    }

    // MARK: - Padding bands

    /// The CoreText overlay fills only the border. If a band overlapped the
    /// Metal layer, the terminal background would be painted twice -- once on
    /// the GPU and once over it, opaquely.
    @Test func paddingBandsCoverTheBorderAndNothingElse() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let padding: CGFloat = 12
        let rects = Host.paddingRects(bounds: bounds, padding: padding)
        let terminal = Host.layerGeometry(bounds: bounds, padding: padding, scale: 2).frame

        #expect(rects.count == 4)
        for rect in rects {
            #expect(!rect.intersects(terminal))
            #expect(bounds.contains(rect))
        }
        // Border area = whole surface minus the terminal.
        let covered = rects.reduce(0) { $0 + $1.width * $1.height }
        #expect(covered == bounds.width * bounds.height - terminal.width * terminal.height)
    }

    @Test func noPaddingMeansNothingForTheOverlayToFill() {
        #expect(Host.paddingRects(
            bounds: CGRect(x: 0, y: 0, width: 300, height: 200), padding: 0).isEmpty)
    }

    // MARK: - Theme colors

    @Test func themeColorsReachTheGpuAsStraightSrgbComponents() {
        let color = Host.color(srgb(r: 0x33, g: 0x66, b: 0x99))

        #expect(abs(color.x - Float(0x33) / 255) < 0.001)
        #expect(abs(color.y - Float(0x66) / 255) < 0.001)
        #expect(abs(color.z - Float(0x99) / 255) < 0.001)
        #expect(color.w == 1)
    }

    @Test func colorAlphaIsScaledAndClamped() {
        #expect(Host.color(srgb(0, 0, 0, 0.5), alpha: 0.5).w == 0.25)
        #expect(Host.color(srgb(0, 0, 0, 1), alpha: 4).w == 1)
    }

    /// The palette is the user's theme, not the renderer's built-in defaults:
    /// a configured background must be the color the pass clears to.
    @Test func paletteComesFromTheThemeRatherThanTheSharedDefaults() {
        var theme = TerminalTheme()
        theme.background = srgb(r: 0x1a, g: 0x1b, b: 0x26)
        theme.foreground = srgb(r: 0xc0, g: 0xca, b: 0xf5)
        theme.selectionBackground = srgb(r: 0x28, g: 0x34, b: 0x57)
        theme.cursorColor = srgb(r: 0x7a, g: 0xa2, b: 0xf7)

        let palette = Host.palette(for: theme)
        #expect(palette.background == Host.color(theme.background))
        #expect(palette.foreground == Host.color(theme.foreground))
        #expect(palette.selection == Host.color(theme.selectionBackground))
        #expect(palette.cursor == Host.color(theme.cursorColor))
        #expect(palette != TerminalMetalPalette.standard())
    }

    // MARK: - Cell metrics

    /// Both renderers measure the grid the same way, so a cell lands in the
    /// same place whichever one drew it.
    @Test func gpuCellMetricsMatchTheCoreTextGridAtTheBackingScale() {
        let coreText = TerminalRenderer.Metrics(fontSize: 13, fontName: nil)
        let metrics = Host.metrics(for: coreText, scale: 2)

        #expect(metrics.cellWidth == coreText.cellWidth)
        #expect(metrics.cellHeight == coreText.cellHeight)
        #expect(metrics.scale == 2)
        #expect(metrics.pixelCellWidth == Float(coreText.cellWidth * 2))
        #expect(metrics.pixelCellHeight == Float(coreText.cellHeight * 2))
        // Ascent is measured from the top of the cell, the baseline from the
        // bottom; together they are the cell.
        #expect(abs(metrics.ascent - (coreText.cellHeight - coreText.baseline)) < 0.001)
    }

    /// Metal anchors row zero at the drawable's top edge. A window can have
    /// a few points left over after fitting whole terminal rows, so anchoring
    /// preedit to `rows * cellHeight` would put it below the committed glyphs.
    @Test func preeditUsesTheMetalViewportTopWhenHeightHasARemainder() {
        #expect(Host.preeditCellBottom(
            cursorRow: 2,
            rows: 10,
            cellHeight: 15,
            viewportHeight: 153
        ) == 108)
        #expect(Host.preeditCellBottom(
            cursorRow: 2,
            rows: 10,
            cellHeight: 15,
            viewportHeight: nil
        ) == 105)
    }

    // MARK: - Cursor policy

    @Test func aFocusedBlinkingCursorFollowsTheBlinkPhase() {
        #expect(Host.cursorBlinkPhaseOn(isFocused: true, blinkOn: true, cursorBlinkEnabled: true))
        #expect(!Host.cursorBlinkPhaseOn(isFocused: true, blinkOn: false, cursorBlinkEnabled: true))
    }

    /// Nothing drives `blinkOn` when blinking is off or the pane is not the
    /// key one, so a stale phase must never hide the cursor there.
    @Test func aCursorThatDoesNotBlinkStaysOn() {
        #expect(Host.cursorBlinkPhaseOn(isFocused: true, blinkOn: false, cursorBlinkEnabled: false))
        #expect(Host.cursorBlinkPhaseOn(isFocused: false, blinkOn: false, cursorBlinkEnabled: true))
    }

    /// The planner reads cursor visibility off the snapshot, so scrolling into
    /// the scrollback has to be applied to the frame itself -- one value in,
    /// one value out, no second source of truth.
    @Test func scrollingIntoTheScrollbackHidesTheCursor() {
        let core = TakoCore(cols: 20, rows: 4)
        for line in 0..<40 {
            core.feed(bytes: Data("line \(line)\r\n".utf8))
        }
        _ = core.takeOutput()

        var atBottom = core.renderFrame()
        atBottom.snapshot.cursorVisible = true
        #expect(atBottom.snapshot.viewportOffset == 0)
        Tako.MetalTerminalHost.applyCursorVisibility(to: &atBottom)
        #expect(atBottom.snapshot.cursorVisible)

        core.scrollViewportUp(lines: 3)
        var scrolledBack = core.renderFrame()
        scrolledBack.snapshot.cursorVisible = true
        #expect(scrolledBack.snapshot.viewportOffset > 0)
        Tako.MetalTerminalHost.applyCursorVisibility(to: &scrolledBack)
        #expect(!scrolledBack.snapshot.cursorVisible)
    }

    @Test func preeditHidesTheTerminalCursor() {
        let core = TakoCore(cols: 20, rows: 4)
        var frame = core.renderFrame()
        frame.snapshot.cursorVisible = true

        Host.applyCursorVisibility(to: &frame, hasPreedit: true)

        #expect(!frame.snapshot.cursorVisible)
    }

    /// The engine reports the whole frame under one lock, which is what lets
    /// the host hand the renderer a single value instead of a snapshot and a
    /// separately-fetched cell buffer that could disagree.
    @Test func oneFrameCarriesAGridAndItsCellsTogether() {
        let core = TakoCore(cols: 20, rows: 4)
        core.feed(bytes: Data("hello".utf8))
        _ = core.takeOutput()

        let frame = core.renderFrame()
        #expect(frame.snapshot.cols == 20)
        #expect(frame.snapshot.rows == 4)
        #expect(frame.packedCells.count >= 20 * 4 * TerminalCell.byteSize)
    }

    /// A display request queued before mode 2026 opened must leave the last
    /// complete drawable visible instead of exposing a half-written frame.
    @Test func synchronizedOutputSuppressesAnAlreadyQueuedRedraw() {
        #expect(Host.shouldRender(isSynchronizedOutputActive: false))
        #expect(!Host.shouldRender(isSynchronizedOutputActive: true))
    }

    // MARK: - Synchronized-output watchdog
    //
    // Suppressing every render for the length of a mode 2026 frame is right
    // for a frame that lasts a few milliseconds and wrong for one that lasts
    // seconds. codex holds one open for a whole streaming response, so the
    // watchdog paints a frame that overstays. These cover the policy; both
    // bugs this path shipped were scheduling bugs, not drawing bugs.

    /// The first batch of an open frame arms the timer.
    @Test func openFrameArmsTheWatchdog() {
        #expect(Host.watchdogAction(
            isSynchronizedOutputActive: true, watchdogArmed: false) == .arm)
    }

    /// Every later batch of the same frame leaves it alone. Acting here is
    /// the 8ms busy-loop: the coalescing timer fired, re-entered the redraw
    /// request that had scheduled it, and span for as long as the frame
    /// stayed open.
    @Test func openFrameDoesNotRearmAnAlreadyRunningWatchdog() {
        #expect(Host.watchdogAction(
            isSynchronizedOutputActive: true, watchdogArmed: true) == .leaveArmed)
    }

    /// Closing the frame retires the timer whether or not it ever fired; the
    /// close path draws the completed frame itself.
    @Test func closedFrameDisarmsTheWatchdog() {
        #expect(Host.watchdogAction(
            isSynchronizedOutputActive: false, watchdogArmed: true) == .disarm)
        #expect(Host.watchdogAction(
            isSynchronizedOutputActive: false, watchdogArmed: false) == .disarm)
    }

    /// A watchdog that outlives its frame must not paint: the close path has
    /// already drawn, and a second frame would just be a duplicate.
    @Test func watchdogRepaintsOnlyWhileItsFrameIsStillOpen() {
        #expect(Host.watchdogShouldForceRender(isSynchronizedOutputActive: true))
        #expect(!Host.watchdogShouldForceRender(isSynchronizedOutputActive: false))
    }

    /// The timeout has to sit between the two failure modes: long enough that
    /// an ordinary frame closes on its own and is never torn, short enough
    /// that a stalled one still animates rather than reading as a hang.
    @Test func watchdogTimeoutOutlivesAnOrdinaryFrameButNotPerception() {
        #expect(Host.syncOutputTimeout > Host.ptyRedrawCoalescingInterval)
        #expect(Host.syncOutputTimeout <= 0.25)
    }

    /// The rate a long frame settles at. A second of streaming has to land
    /// between a frozen display and the old busy-loop, which at the
    /// coalescing interval would have been ~120 wakeups for the same second.
    @Test func aLongFrameRendersAtAVisibleRateWithoutSpinning() {
        let forced = Host.maxForcedRendersDuring(1.0)
        #expect(forced == 5)

        let busyLoop = Int(1.0 / Host.ptyRedrawCoalescingInterval)
        #expect(forced < busyLoop / 10)
    }

    /// A frame that closes before the timeout never forces anything -- the
    /// common case, and the reason the watchdog costs nothing in normal use.
    @Test func aShortFrameNeverForcesARender() {
        #expect(Host.maxForcedRendersDuring(Host.syncOutputTimeout / 2) == 0)
        #expect(Host.maxForcedRendersDuring(0) == 0)
    }

    @Test func pureDamageSkipsSynchronousMainApplication() {
        #expect(!Host.requiresSynchronousMainApplication(output: Data(), events: []))
        #expect(Host.requiresSynchronousMainApplication(output: Data([0x1b]), events: []))
        #expect(Host.requiresSynchronousMainApplication(output: Data(), events: [.bell]))
        #expect(Host.ptyRedrawCoalescingInterval > 0)
        #expect(Host.ptyRedrawCoalescingInterval <= 1.0 / 60.0)
    }

    // MARK: - Fallback policy

    @Test func anOpaqueSurfaceWithARendererUsesTheGpu() {
        #expect(Host.fallback(
            rendererAvailable: true, backgroundOpacity: 1, geometryRenderable: true) == nil)
    }

    @Test func aSurfaceWithoutARendererFallsBackExplicitly() {
        #expect(Host.fallback(
            rendererAvailable: false, backgroundOpacity: 1, geometryRenderable: true)
            == .rendererUnavailable)
        // The missing renderer is reported ahead of the opacity: it is the
        // reason there is no GPU path at all.
        #expect(Host.fallback(
            rendererAvailable: false, backgroundOpacity: 0.8, geometryRenderable: false)
            == .rendererUnavailable)
    }

    @Test func aCollapsedSurfaceNeverAssignsAZeroMetalDrawable() {
        #expect(Host.fallback(
            rendererAvailable: true, backgroundOpacity: 1, geometryRenderable: false)
            == .unrenderableGeometry)
    }

    /// A translucent window keeps the CoreText path. The GPU path clears to
    /// the default background and skips every cell that keeps it, which stops
    /// being right once that background is see-through -- so the whole frame
    /// goes back to CoreText rather than half of it going missing.
    @Test func aTranslucentSurfaceFallsBackInsteadOfLosingContent() {
        #expect(Host.fallback(
            rendererAvailable: true, backgroundOpacity: 0.8, geometryRenderable: true)
            == .transparentBackground)
        #expect(Host.fallback(
            rendererAvailable: true, backgroundOpacity: 0, geometryRenderable: true)
            == .transparentBackground)
    }
}
