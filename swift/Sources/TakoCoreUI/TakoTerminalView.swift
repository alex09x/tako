import Foundation
import OSLog

#if canImport(UIKit)
import CoreGraphics
import Metal
import QuartzCore
import UIKit
import simd

/// Delegate protocol for `TakoTerminalView`.
@MainActor
public protocol TakoTerminalViewDelegate: AnyObject {
    /// Called when user input (typing, hardware keys, paste, soft keyboard) produces bytes to send to the PTY.
    func terminalView(_ view: TakoTerminalView, sendInputData data: Data)

    /// Called when the terminal engine generates device reply bytes (e.g. DA/DSR/XTVERSION responses) to send to the PTY.
    func terminalView(_ view: TakoTerminalView, sendDeviceReplyData data: Data)

    /// Called when the terminal grid dimensions change.
    func terminalView(_ view: TakoTerminalView, didResizeCols cols: Int, rows: Int)

    /// A checkpoint was restored into the engine, in parser order.
    ///
    /// Deliberately not `didResizeCols:rows:`: the restored grid is the
    /// canonical one and this view is mirroring it, so its dimensions are
    /// reported, not requested. A host that has a genuinely newer layout
    /// intent sends it back through its own ordered resize path; nothing here
    /// reflows the restored grid on its own.
    func terminalView(_ view: TakoTerminalView, didRestoreCheckpoint restore: TerminalCheckpointRestore)

    /// Optional: Called when the terminal window/session title changes.
    func terminalView(_ view: TakoTerminalView, didChangeTitle title: String)

    /// Optional: Called when a bell event occurs.
    func terminalViewDidBell(_ view: TakoTerminalView)

    /// Shell-integration markers used by hosts to expose command activity.
    func terminalViewCommandDidStart(_ view: TakoTerminalView)
    func terminalView(_ view: TakoTerminalView, commandDidEnd exitCode: Int32?)

    /// A remote program asked for text to be put on the clipboard (OSC 52).
    ///
    /// Deliberately not written to the pasteboard here: whether a program on
    /// the other end of a socket may replace what the user last copied is a
    /// policy question, and the host owns it.
    func terminalView(_ view: TakoTerminalView, didRequestClipboardCopy text: String)

    /// The shell reported its working directory (OSC 7).
    func terminalView(_ view: TakoTerminalView, didChangeWorkingDirectory url: String)

    /// The viewport moved, as a fraction: 0 is the oldest retained line, 1 is
    /// the live screen. A host stores this to restore the position after the
    /// surface is torn down and rebuilt.
    func terminalView(_ view: TakoTerminalView, didScrollTo position: Double)

    /// Screen content changed. A host that mirrors the buffer as text -- for
    /// a copy action or an accessibility element -- refreshes on this rather
    /// than polling.
    func terminalViewDidChangeContent(_ view: TakoTerminalView)
}

public extension TakoTerminalViewDelegate {
    func terminalView(_ view: TakoTerminalView, didRestoreCheckpoint restore: TerminalCheckpointRestore) {}
    func terminalView(_ view: TakoTerminalView, didChangeTitle title: String) {}
    func terminalViewDidBell(_ view: TakoTerminalView) {}
    func terminalViewCommandDidStart(_ view: TakoTerminalView) {}
    func terminalView(_ view: TakoTerminalView, commandDidEnd exitCode: Int32?) {}
    func terminalView(_ view: TakoTerminalView, didRequestClipboardCopy text: String) {}
    func terminalView(_ view: TakoTerminalView, didChangeWorkingDirectory url: String) {}
    func terminalView(_ view: TakoTerminalView, didScrollTo position: Double) {}
    func terminalViewDidChangeContent(_ view: TakoTerminalView) {}
}

/// A public production UIKit terminal surface built over `TakoCore` and
/// the shared `MetalTerminalRenderer`.
///
/// The pixels come from Metal: a `CAMetalLayer` sized in drawable pixels,
/// fed one atomic `FfiRenderFrame` per redraw so the grid dimensions and the
/// cell bytes can never come from two different terminal states. The
/// CoreText `TerminalRenderer` stays for cell metrics -- the grid geometry
/// every gesture and resize is computed from -- and as the CPU fallback for
/// a host with no Metal device, no shader library, or a pipeline that would
/// not build.
@MainActor
public class TakoTerminalView: UIView, UIKeyInput {
    public weak var delegate: TakoTerminalViewDelegate?

    public let core: TakoCore

    /// This view's own parser: every byte fed to the engine goes through it,
    /// off Main, and comes back as outcomes applied here in batch order.
    let parserCoordinator: TerminalParserCoordinator

    public var theme: TerminalTheme {
        didSet {
            renderer = TerminalRenderer(
                metrics: .init(theme: theme),
                defaultForeground: theme.foreground,
                defaultBackground: theme.background,
                selectionColor: theme.selectionBackground,
                selectionForeground: theme.selectionForeground,
                selectionInvertFgBg: theme.selectionInvertFgBg,
                cursorOpacity: theme.cursorOpacity,
                cursorThickness: theme.cursorThickness
            )
            // Cell metrics, the palette and every pipeline-bound resource
            // are baked into the Metal renderer when it is built, so a theme
            // or font change rebuilds it rather than mutating it.
            core.setBaseColors(from: theme)
            core.setDefaultCursorStyle(from: theme)
            core.setGraphemeWidthMethod(from: theme)
            rebuildMetalRenderer()
            updateBlinkTimer()
            setNeedsLayout()
            setNeedsDisplay()
        }
    }
    public private(set) var renderer: TerminalRenderer
    public private(set) var cols: Int = 80
    public private(set) var rows: Int = 24

    /// Automatically opens the software keyboard when tapped.
    public var autoFocusKeyboardOnTap: Bool = true

    // MARK: - Metal

    /// The shared renderer driving the layer, or nil when the device, the
    /// shader library or a pipeline was unavailable and the CPU path runs.
    public private(set) var metalRenderer: MetalTerminalRenderer?
    /// The layer `metalRenderer` draws into. Nil exactly when it is nil.
    public private(set) var metalLayer: CAMetalLayer?
    /// Why the Metal path is unavailable, when it is. Nil while it works.
    public private(set) var metalUnavailableReason: String?
    /// What the last Metal frame turned into, for hosts that log it.
    public private(set) var lastFrameStatistics: TerminalMetalFrameStatistics?
    /// Why the theme's `custom-shader` files are not applied. Empty while
    /// they run or when none are configured.
    public var customShaderErrors: [String] { metalRenderer?.customShaderErrors ?? [] }

    /// Drawable pixels per point the current renderer was built for. Cell
    /// metrics are baked in at that scale, so a change means a rebuild.
    private(set) var metalContentScale: CGFloat = 1
    /// How many times a Metal renderer has been built, successfully or not.
    private(set) var rendererBuildCount: Int = 0
    /// How many atomic frames have been pulled out of the engine. Exactly
    /// one per redraw, on either path.
    private(set) var frameFetchCount: Int = 0
    /// A redraw asked for since the last frame was drawn.
    private(set) var redrawPending: Bool = false
    /// The last frame was planned but never presented, so the layer is still
    /// showing older pixels than the terminal holds.
    ///
    /// Deliberately separate from `redrawPending`: this is not new damage,
    /// it is the same frame owed a second attempt. Without it, a frame lost
    /// to an exhausted drawable pool -- which is exactly what a burst of
    /// full-screen updates plus native scrolling produces -- clears
    /// `redrawPending`, pauses the display link on the next tick, and leaves
    /// the surface settled on a half-updated image while `accessibilityValue`
    /// and the engine's own text are already correct.
    private(set) var presentationRetryPending: Bool = false
    /// Frames in a row that were planned and never reached the layer.
    private(set) var unpresentedFrameCount: Int = 0
    /// A redraw a synchronized-output frame deferred rather than drew.
    ///
    /// DEC mode 2026 means "not yet", never "never". The tick that runs while
    /// it is open draws nothing and pauses the display link, so whatever that
    /// tick stood for -- new damage, or a frame that never reached the layer
    /// -- is owed once the frame closes, and nothing else will ask for it:
    /// the closing feed reports only the damage still queued in the engine,
    /// which is empty whenever the held frame had already drained it on its
    /// way to a drawable that never came. Recording the debt here is what
    /// keeps a restored screen from settling on the pixels it replaced.
    private(set) var redrawHeldBySynchronizedOutput: Bool = false
    /// The one display link driving Metal redraws. Nil on the CPU path.
    private(set) var displayLink: CADisplayLink?

    /// UIKit reports several intermediate bounds while rotating or changing
    /// the software keyboard. Some of those are only a few rows tall. Feeding
    /// every transient size to the terminal moves real rows into scrollback,
    /// and growing again cannot know that those rows should return. Keep only
    /// the last size after layout has been quiet for a short interval.
    private var pendingResizeWorkItem: DispatchWorkItem?
    private var pendingGridSize: (cols: Int, rows: Int)?
    private static let resizeSettleDelay: TimeInterval = 0.1

    /// SwiftPM compiles TerminalShaders.metal into TakoCoreUI's resource
    /// bundle. The direct app builders compile the same source into the main
    /// bundle. Selecting the right one here keeps both integration modes on
    /// Metal instead of silently dropping package consumers to CoreText.
    private static var metalLibraryBundle: Bundle { ShaderBundle.resources }

    /// Test seam: forces the CPU fallback on a machine that does have a GPU,
    /// so the fallback path is covered wherever the tests run.
    static var isMetalDisabledForTesting = false

    /// Test seam: supplies the shader library when the host bundle carries no
    /// compiled default one.
    ///
    /// The standalone Simulator XCTest runner links no metallib, so without
    /// this every view test falls back to CoreText and the Metal presentation
    /// path -- drawables, command buffers, actual pixels -- goes uncovered. A
    /// GPU test compiles `TerminalShaders.metal` itself and hands it in here.
    /// Nil in production, where `metalLibraryBundle` has the real library.
    static var metalLibraryProviderForTesting: ((MTLDevice) -> MTLLibrary?)?

    // Cursor blink state
    private(set) var blinkTimer: Timer?
    private var blinkStateVisible: Bool = true

    /// Reads the text used by the native paste action. Production keeps the
    /// real system pasteboard here; standalone Simulator XCTest processes can
    /// replace the closure because UIKit's pasteboard IPC can block forever
    /// when the runner is not hosted by an application.
    var pasteStringProvider: () -> String? = { UIPasteboard.general.string }

    /// Writes the text used by the native copy action. Production keeps the
    /// real system pasteboard here; standalone Simulator XCTest processes can
    /// replace the closure because UIKit's pasteboard IPC can block forever
    /// when the runner is not hosted by an application.
    var copyStringConsumer: (String) -> Void = { UIPasteboard.general.string = $0 }

    // Gestures
    private var panGesture: UIPanGestureRecognizer?
    private var longPressGesture: UILongPressGestureRecognizer?
    private var tapGesture: UITapGestureRecognizer?
    private var panAccumulatedY: CGFloat = 0

    // Kinetic Momentum Scrolling
    public static var allowOffscreenKineticStepForTesting: Bool = false
    private var kineticDeceleration = TerminalKineticDeceleration()
    private var kineticDisplayLink: CADisplayLink?
    private var kineticTouchLocation: CGPoint = .zero
    private var kineticInitialModes: FfiTerminalModes?

    /// Whether the view is currently decelerating under kinetic momentum.
    public var isKineticScrolling: Bool {
        kineticDeceleration.isDecelerating
    }

    /// Current instantaneous velocity of the kinetic deceleration in points/second.
    public var kineticVelocity: Double {
        kineticDeceleration.velocity
    }

    // Screen buffer & private mode properties
    public var isAlternateScreen: Bool { core.modes().alternateScreen }
    public var isAlternateScroll: Bool { core.modes().alternateScroll }

    // Selection drag state & edit menu interaction
    private var isSelecting: Bool = false
    private var editMenuInteractionStorage: Any?
    // `UIEditMenuInteraction.delegate` is weak; this is the interaction's
    // sole strong owner, retained for as long as the interaction itself.
    private var editMenuInteractionDelegateStorage: Any?

    public init(frame: CGRect = .zero, core: TakoCore? = nil, theme: TerminalTheme = .takoDefault) {
        let initialCore = core ?? TakoCore(cols: 80, rows: 24)
        self.core = initialCore
        self.parserCoordinator = TerminalParserCoordinator(core: initialCore)
        self.theme = theme
        self.renderer = TerminalRenderer(
            metrics: .init(theme: theme),
            defaultForeground: theme.foreground,
            defaultBackground: theme.background,
            selectionColor: theme.selectionBackground,
            selectionForeground: theme.selectionForeground,
            selectionInvertFgBg: theme.selectionInvertFgBg,
            cursorOpacity: theme.cursorOpacity,
            cursorThickness: theme.cursorThickness
        )
        super.init(frame: frame)
        setupView()
        self.core.setBaseColors(from: theme)
        self.core.setDefaultCursorStyle(from: theme)
        self.core.setGraphemeWidthMethod(from: theme)
    }

    public required init?(coder: NSCoder) {
        let initialCore = TakoCore(cols: 80, rows: 24)
        self.core = initialCore
        self.parserCoordinator = TerminalParserCoordinator(core: initialCore)
        self.theme = .takoDefault
        self.renderer = TerminalRenderer(
            metrics: .init(theme: theme),
            defaultForeground: theme.foreground,
            defaultBackground: theme.background,
            selectionColor: theme.selectionBackground,
            selectionForeground: theme.selectionForeground,
            selectionInvertFgBg: theme.selectionInvertFgBg,
            cursorOpacity: theme.cursorOpacity,
            cursorThickness: theme.cursorThickness
        )
        super.init(coder: coder)
        setupView()
        self.core.setBaseColors(from: theme)
        self.core.setDefaultCursorStyle(from: theme)
        self.core.setGraphemeWidthMethod(from: theme)
    }

    deinit {
        // The repeating sources this view owns, held weakly on the
        // far side, plus the parser: work already on its queue finishes
        // against the engine (which outlives the view), but nothing more is
        // ever applied back onto a view that no longer exists.
        NotificationCenter.default.removeObserver(self)
        blinkTimer?.invalidate()
        displayLink?.invalidate()
        kineticDisplayLink?.invalidate()
        kineticDisplayLink = nil
        kineticDeceleration.cancel()
        kineticInitialModes = nil
        pendingResizeWorkItem?.cancel()
        parserCoordinator.shutDown()
    }

    private func setupView() {
        backgroundColor = .clear
        isOpaque = false
        // The one place a parsed batch becomes UIKit work. Installed before
        // anything can feed, and weak, so the coordinator the view owns does
        // not own it back.
        parserCoordinator.setMainApplicationHandler { [weak self] outcomes in
            MainActor.assumeIsolated { self?.apply(outcomes) }
        }
        parserCoordinator.setCheckpointRestoreHandler { [weak self] restore in
            MainActor.assumeIsolated { self?.applyCheckpointRestore(restore) }
        }
        parserCoordinator.setResizeHandler { [weak self] cols, rows in
            MainActor.assumeIsolated { self?.applyOrderedResize(cols: cols, rows: rows) }
        }
        rebuildMetalRenderer()

        // Gesture recognizers
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
        self.tapGesture = tap

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        self.panGesture = pan

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        addGestureRecognizer(longPress)
        self.longPressGesture = longPress

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        setupAccessibility()
        startBlinkTimer()
        startKineticDisplayLink()
    }

    private func setupAccessibility() {
        isAccessibilityElement = true
        accessibilityLabel = "Terminal"
        // A stable handle for the UI tests, which read the grid through the
        // accessibility value because it is drawn by Metal and has no text to
        // find any other way.
        accessibilityIdentifier = "terminal"
        accessibilityTraits = [.updatesFrequently]
    }

    override public var accessibilityValue: String? {
        get { plainText(startRow: 0, maxRows: rows) }
        set { super.accessibilityValue = newValue }
    }

    // MARK: - Core Host Operations

    /// Feed raw bytes received from the PTY host connection.
    ///
    /// The engine is driven on this view's dedicated serial parser queue,
    /// never on Main -- but the outcome of *these* bytes is applied here,
    /// before this returns, so the long-standing contract holds: a device
    /// reply is delivered before any input that depends on it, and a caller
    /// that reads `plainText`, `selectedText` or the redraw state right
    /// after a feed sees this feed's effect. Main waits for the parse
    /// instead of performing it.
    ///
    /// Use `enqueue(data:)` for bulk PTY output, which never waits.
    public func feed(data: Data) {
        parserCoordinator.feedSynchronously(data)
    }

    /// Hand bulk PTY output to the parser without waiting for it.
    ///
    /// The high-throughput path: bytes are appended to the parser's pending
    /// buffer and this returns immediately, so a reader thread never blocks
    /// on Main and Main never blocks on the engine. Bursts coalesce into
    /// batches of at most `TerminalParserCoordinator.maxBatchBytes`, parsed
    /// in arrival order, and their outcomes are applied on Main in that same
    /// order with at most one application outstanding.
    ///
    /// The one thing `feed(data:)` gives that this does not is ordering
    /// against work the *caller* does next: an enqueued device reply reaches
    /// the delegate on a later main hop, so input generated in between is
    /// not held back for it. Feed anything a reply gates; enqueue the rest.
    public func enqueue(data: Data) {
        parserCoordinator.enqueue(data)
    }

    /// Replace the terminal from a checkpoint, ordered against the parser.
    ///
    /// Not a reset: `reset()` feeds `ESC c`, which is a stream the terminal
    /// interprets. This hands the engine a whole state to become, and the
    /// engine swaps it in atomically -- a rejected checkpoint leaves the
    /// terminal exactly as it was.
    ///
    /// Throws the engine's own typed error, so a caller can tell an
    /// unsupported container version from a corrupt payload.
    @discardableResult
    public func importCheckpoint(_ blob: Data) throws -> TerminalCheckpointRestore {
        try parserCoordinator.importCheckpoint(blob)
    }

    /// What a checkpoint declares, without importing it -- so a host can
    /// negotiate before committing.
    public func inspectCheckpoint(_ blob: Data) throws -> FfiCheckpointInfo {
        try core.checkpointInspect(blob: blob)
    }

    /// The container version this build writes.
    public var checkpointVersion: UInt32 { core.checkpointVersion() }

    /// Whether this build can import that container version.
    public func supportsCheckpointVersion(_ version: UInt32) -> Bool {
        core.checkpointSupports(version: version)
    }

    /// Export the terminal as a checkpoint, bounded by a caller-supplied cap.
    public func exportCheckpoint(maxBytes: UInt64 = 64 * 1024 * 1024) throws -> Data {
        try core.checkpointExport(flags: 0, maxBytes: maxBytes)
    }

    /// Adopt a completed restore on Main, in parser order.
    private func applyCheckpointRestore(_ restore: TerminalCheckpointRestore) {
        // A debounced layout intent from before the restore describes the
        // geometry the *view* wanted for the terminal that has just been
        // replaced. Letting it fire now would reflow the canonical grid on
        // this mirror's authority, which is not this side's call.
        pendingResizeWorkItem?.cancel()
        pendingResizeWorkItem = nil
        pendingGridSize = nil

        // Momentum measured against the grid that has just been replaced does
        // not carry over. Cancelling it belongs *here*, not before the import:
        // a refused checkpoint leaves the engine untouched, so killing a live
        // fling for it would be a visible side effect of an operation that did
        // not happen.
        cancelKineticScroll()

        // Report, do not resize: no `core.resize`, and no synthesized
        // `terminalView(_:didResizeCols:rows:)`.
        cols = restore.cols
        rows = restore.rows
        lastReportedScrollPosition = core.scrollPosition()
        TakoLog.resize.info("checkpoint restored \(restore.cols)×\(restore.rows)")
        delegate?.terminalView(self, didRestoreCheckpoint: restore)
        delegate?.terminalViewDidChangeContent(self)
        setNeedsDisplay()
    }

    /// The one place a parsed batch becomes UIKit state, always on Main and
    /// always in the order the batches were parsed.
    private func apply(_ outcomes: [FfiFeedOutcome]) {
        var totalDamage = false
        for outcome in outcomes {
            // Drain device replies (DA/DSR/XTVERSION/Kitty replies)
            if !outcome.output.isEmpty {
                delegate?.terminalView(self, sendDeviceReplyData: outcome.output)
            }

            // Drain host events
            for event in outcome.events {
                switch event {
                case .titleChanged(let title):
                    TakoLog.feed.info("title → \"\(title)\"")
                    delegate?.terminalView(self, didChangeTitle: title)
                case .bell:
                    TakoLog.feed.debug("bell")
                    delegate?.terminalViewDidBell(self)
                case .commandStart:
                    delegate?.terminalViewCommandDidStart(self)
                case .commandEnd(let exitCode):
                    delegate?.terminalView(self, commandDidEnd: exitCode)
                case .clipboardSet(let text):
                    TakoLog.feed.info("OSC 52 → clipboard (\(text.count) chars)")
                    delegate?.terminalView(self, didRequestClipboardCopy: text)
                case .pwdChanged(let url):
                    delegate?.terminalView(self, didChangeWorkingDirectory: url)
                default:
                    break
                }
            }

            // Synchronized output suppression & damage-aware redraw
            if outcome.hasDamage && !outcome.synchronizedOutputActive {
                totalDamage = true
                setNeedsDisplay()
            }
        }
        if isKineticScrolling, let initialModes = kineticInitialModes {
            let currentModes = core.modes()
            if currentModes.alternateScreen != initialModes.alternateScreen
                || currentModes.mouseTracking != initialModes.mouseTracking
                || currentModes.alternateScroll != initialModes.alternateScroll
                || currentModes.cursorKeyAppMode != initialModes.cursorKeyAppMode
                || core.isSynchronizedOutputActive() {
                cancelKineticScroll()
            }
        }
        // A closed synchronized frame releases whatever it held back. The
        // damage the closing feed reports covers only what is still queued in
        // the engine, so a frame that was drawn out of the engine and then
        // dropped -- by an exhausted drawable pool, or by mode 2026 opening
        // before the next tick -- has to be asked for here by name. Without
        // this the display link stays paused with the old screen on the glass.
        if redrawHeldBySynchronizedOutput && !core.isSynchronizedOutputActive() {
            redrawHeldBySynchronizedOutput = false
            setNeedsDisplay()
        }
        if totalDamage {
            TakoLog.render.debug("damage → setNeedsDisplay (\(outcomes.count) outcomes)")
            // Anything mirroring the buffer as text needs to know the text
            // changed; polling it per frame would read the whole scrollback
            // sixty times a second.
            delegate?.terminalViewDidChangeContent(self)
            notifyScrollPositionIfChanged()
        }
    }

    /// Last position reported to the delegate, so output that leaves the
    /// viewport where it was does not produce a stream of identical
    /// callbacks.
    private var lastReportedScrollPosition: Double = 1

    private func notifyScrollPositionIfChanged() {
        let position = core.scrollPosition()
        guard abs(position - lastReportedScrollPosition) > 0.0001 else { return }
        lastReportedScrollPosition = position
        delegate?.terminalView(self, didScrollTo: position)
    }

    /// Reset terminal state.
    ///
    /// Routed through the parser like every other byte, so a reset can never
    /// overtake PTY output that is still queued in front of it -- and, like
    /// `feed(data:)`, it has taken effect by the time it returns.
    public func reset() {
        cancelKineticScroll()
        parserCoordinator.feedSynchronously(Data("\u{001B}c".utf8))
        setNeedsDisplay()
    }

    /// Everything the terminal holds as plain text: scrollback first, then
    /// the live screen, with soft-wrapped lines rejoined.
    ///
    /// This is the copy source. Reading the visible rows instead -- which is
    /// what a viewport-shaped accessor gives -- returns the last screenful of
    /// a session that may have thousands of lines.
    public var bufferText: String {
        core.bufferText()
    }

    /// Where the viewport sits, 0 (oldest retained line) to 1 (live screen).
    ///
    /// Stored and restored across a surface being torn down and rebuilt. A
    /// line number cannot serve: scrollback is evicted as the session runs,
    /// so the number would point somewhere else, or nowhere.
    public var scrollPosition: Double {
        get { core.scrollPosition() }
        set {
            cancelKineticScroll()
            core.setScrollPosition(position: newValue)
            lastReportedScrollPosition = core.scrollPosition()
            setNeedsDisplay()
        }
    }

    /// Query scroll offset.
    public var viewportOffset: Int {
        Int(core.viewportOffset())
    }

    /// Query total scrollback length in lines.
    public var scrollbackLength: Int {
        Int(core.scrollbackLen())
    }

    /// Scroll viewport up by lines.
    public func scrollViewportUp(lines: Int = 1) {
        core.scrollViewportUp(lines: UInt32(max(lines, 1)))
        setNeedsDisplay()
    }

    /// Scroll viewport down by lines.
    public func scrollViewportDown(lines: Int = 1) {
        core.scrollViewportDown(lines: UInt32(max(lines, 1)))
        setNeedsDisplay()
    }

    /// Snap scroll to bottom (live screen).
    public func scrollViewportToBottom() {
        cancelKineticScroll()
        core.scrollViewportBottom()
        setNeedsDisplay()
    }

    /// Scroll to specific viewport offset.
    public func scrollToOffset(_ offset: Int) {
        cancelKineticScroll()
        core.scrollViewportBottom()
        if offset > 0 {
            core.scrollViewportUp(lines: UInt32(offset))
        }
        setNeedsDisplay()
    }

    /// Obtain bounded plain text starting at startRow for maxRows lines.
    public func plainText(startRow: Int = 0, maxRows: Int = 100) -> String {
        let totalRows = Int(core.rows())
        let start = max(startRow, 0)
        guard start < totalRows else { return "" }
        let maxR = max(maxRows, 1)
        return core.getPlainText(startRow: UInt32(start), maxRows: UInt32(maxR))
    }

    /// Current selection text.
    public var selectedText: String? {
        core.selectedText()
    }


    // MARK: - Presented-frame cadence

    /// Presentation cadence for this surface, across every renderer it builds.
    ///
    /// Owned by the view, not by the renderer: a theme, font or backing-scale
    /// change replaces the renderer, and a count that restarted there would
    /// read to a consumer exactly like the display having stalled.
    ///
    /// Internal: what leaves this module is the immutable reading, never the
    /// thing that can advance it.
    let presentationClock = TerminalPresentationClock()

    /// One coherent read of what this surface has actually put on screen:
    /// sequence, presented time and interval, all from the same frame.
    ///
    /// Advanced only from the drawable's presented handler, so it counts
    /// frames the display showed rather than frames that were encoded. Stays
    /// at `.none` while Metal is unavailable and the CoreText fallback draws,
    /// and keeps its value -- rather than resetting -- while the renderer is
    /// absent between rebuilds.
    public var presentationCadence: TerminalPresentationCadence { presentationClock.cadence }

    // MARK: - Metal renderer lifecycle

    /// Build the Metal renderer, its layer and its display link, replacing
    /// whatever was there. Every GPU object the old renderer held goes with
    /// it, so a theme, font or scale change never leaks a pipeline, an atlas
    /// texture or a second layer.
    private func rebuildMetalRenderer() {
        releaseMetalResources()
        rendererBuildCount += 1
        metalContentScale = effectiveContentScale

        if let failure = makeMetalRenderer(scale: metalContentScale) {
            metalUnavailableReason = failure
            stopDisplayLink()
            return
        }
        metalUnavailableReason = nil
        startDisplayLink()
        // The new renderer has drawn nothing yet.
        setNeedsDisplay()
    }

    /// Returns nil on success, or the reason the CPU fallback must run.
    private func makeMetalRenderer(scale: CGFloat) -> String? {
        guard !Self.isMetalDisabledForTesting else { return "Metal disabled for testing" }
        guard let device = MTLCreateSystemDefaultDevice() else { return "no Metal device" }
        let resolvedLibrary = Self.metalLibraryProviderForTesting?(device)
            ?? MetalTerminalRenderer.defaultLibrary(device: device, bundle: Self.metalLibraryBundle)
        guard let library = resolvedLibrary else {
            return String(describing: MetalTerminalRendererError.defaultLibraryUnavailable)
        }

        let created: MetalTerminalRenderer
        do {
            created = try MetalTerminalRenderer(
                device: device,
                library: library,
                metrics: TerminalMetalCellMetrics(renderer.metrics, scale: scale),
                palette: Self.metalPalette(for: theme),
                colorSpace: theme.windowColorSpace == .displayP3 ? .displayP3 : .sRGB,
                // The same clock every time, so the sequence a consumer is
                // watching survives this renderer being replaced.
                presentationClock: presentationClock
            )
        } catch {
            return String(describing: error)
        }
        created.planner.cursorThickness = theme.cursorThickness
        created.planner.cellColorsAreDisplayP3 = theme.windowColorSpace == .displayP3

        // Kitty placements resolve through the engine's own image store.
        // Captured weakly and by value, so the renderer never outlives the
        // engine and never reaches back into the view.
        let engine = core
        created.imageProvider = { [weak engine] imageId in
            engine?.graphicsImage(imageId: imageId)
        }
        created.imageMetadataProvider = { [weak engine] imageId in
            engine?.graphicsImageMetadata(imageId: imageId)
        }
        if !theme.customShaders.isEmpty {
            for error in created.loadCustomShaders(paths: theme.customShaders) {
                TakoLog.render.error(error)
            }
        }

        let metal = CAMetalLayer()
        created.configure(layer: metal)
        // A translucent theme needs the layer to composite, not to claim
        // every pixel it covers.
        metal.isOpaque = theme.backgroundOpacity >= 1
        layer.insertSublayer(metal, at: 0)

        metalRenderer = created
        metalLayer = metal
        applyMetalLayerGeometry()
        return nil
    }

    /// Drop the renderer, its layer, and with them every GPU object they
    /// own: the pipelines, the instance rings, the glyph atlas pages and the
    /// cached Kitty textures.
    private func releaseMetalResources() {
        metalLayer?.removeFromSuperlayer()
        metalLayer = nil
        metalRenderer = nil
        lastFrameStatistics = nil
    }

    /// The layer's pixel size for a point size at a content scale: whole
    /// pixels, never zero. `nextDrawable()` vends nothing for a zero-sized
    /// layer, and a fractional size rounds where the caller cannot see it.
    static func drawableSize(for size: CGSize, scale: CGFloat) -> CGSize {
        let scale = max(scale, 1)
        return CGSize(
            width: max((size.width * scale).rounded(.down), 1),
            height: max((size.height * scale).rounded(.down), 1)
        )
    }

    /// Drawable pixels per point for wherever this view currently is.
    private var effectiveContentScale: CGFloat {
        max(window?.screen.scale ?? contentScaleFactor, 1)
    }

    private func applyMetalLayerGeometry() {
        guard let metal = metalLayer else { return }
        let size = Self.drawableSize(for: bounds.size, scale: metalContentScale)
        guard metal.frame != bounds
                || metal.contentsScale != metalContentScale
                || metal.drawableSize != size else { return }
        // A layer resize is not an animation; the next frame simply arrives
        // at the new size.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metal.frame = bounds
        metal.contentsScale = metalContentScale
        metal.drawableSize = size
        CATransaction.commit()
        setNeedsDisplay()
    }

    // MARK: - Redraw scheduling

    /// One display link for the life of the view, paused whenever nothing
    /// has changed, so an idle terminal costs no vsync at all.
    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let proxy = DisplayLinkProxy()
        proxy.owner = self
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// `setNeedsDisplay` is the one redraw entry point every call site
    /// already uses, so the Metal path hangs off it rather than adding a
    /// second, parallel one.
    override public func setNeedsDisplay() {
        scheduleRedraw()
        // With Metal owning the pixels the CoreGraphics backing store is
        // dead weight; only the fallback marks it dirty.
        if metalLayer == nil { super.setNeedsDisplay() }
    }

    override public func setNeedsDisplay(_ rect: CGRect) {
        scheduleRedraw()
        if metalLayer == nil { super.setNeedsDisplay(rect) }
    }

    /// Coalescing: any number of calls between two vsyncs draw one frame.
    private func scheduleRedraw() {
        redrawPending = true
        displayLink?.isPaused = false
    }

    /// Re-arm the same frame after it failed to reach the layer. The display
    /// link is only un-paused while the view is in a window; off-screen there
    /// is nothing stale to look at, and `didMoveToWindow` asks for a redraw
    /// on the way back in.
    private func armPresentationRetry() {
        presentationRetryPending = true
        if window != nil { displayLink?.isPaused = false }
    }

    func displayLinkFired() {
        guard redrawPending || presentationRetryPending else {
            displayLink?.isPaused = true
            return
        }
        redrawNow()
    }

    /// Draw one frame right now, if Metal owns the pixels.
    func redrawNow() {
        let wasRedrawPending = redrawPending
        redrawPending = false
        // No surface, or one with no area, has no stale pixels to correct --
        // and a retry armed against it would spin the display link every
        // vsync for as long as the condition lasts. Layout schedules its own
        // redraw once there is something to draw into.
        guard let metalRenderer, let metalLayer else { return clearPresentationRetry() }
        guard bounds.width >= 1, bounds.height >= 1 else { return clearPresentationRetry() }
        // A redraw may already have been queued when mode 2026 opened. Do
        // not let that stale display-link tick expose a half-written frame;
        // the feed that closes synchronized output reports the accumulated
        // damage and schedules the complete frame.
        guard !core.isSynchronizedOutputActive() else {
            // Deferred, not cancelled: remember that this tick owed a frame so
            // the close of the synchronized frame can pay it even when the
            // closing feed carries no damage of its own.
            if wasRedrawPending || presentationRetryPending {
                redrawHeldBySynchronizedOutput = true
            }
            displayLink?.isPaused = true
            return
        }
        metalRenderer.planner.isFocused = isFirstResponder
        metalRenderer.planner.cursorBlinkPhaseOn = theme.cursorBlink ? blinkStateVisible : true
        // Edge to edge: whatever does not fit a whole cell is at the right
        // and the bottom, and window-padding-color decides what fills it.
        let scale = Float(metalLayer.contentsScale)
        metalRenderer.planner.margins = TerminalMetalMargins(
            right: Float(max(0, bounds.width - CGFloat(cols) * renderer.metrics.cellWidth)) * scale,
            bottom: Float(max(0, bounds.height - CGFloat(rows) * renderer.metrics.cellHeight)) * scale,
            fill: TakoTerminalView.marginFill(theme.windowPaddingColor)
        )
        let stats = metalRenderer.render(frame: currentRenderFrame(), in: metalLayer)
        lastFrameStatistics = stats
        // A planned frame that never reached the layer is not a drawn frame.
        // Settling here is what leaves old glyph rows mixed into a screen
        // whose text has already stabilized, so the frame is owed another
        // attempt on the next tick rather than a paused display link.
        if stats.presentation.leavesStalePixels {
            unpresentedFrameCount += 1
            TakoLog.render.debug("frame not presented (\(String(describing: stats.presentation))) → retry")
            armPresentationRetry()
        } else {
            clearPresentationRetry()
        }
        // An animating custom shader owes the next frame as soon as this one is drawn.
        if customShaderKeepsAnimating {
            scheduleRedraw()
        }
    }

    /// Custom shaders are running and `custom-shader-animation` wants
    /// frames in the current focus state.
    var customShaderKeepsAnimating: Bool {
        guard metalRenderer?.customShaders.isEmpty == false else { return false }
        return theme.customShaderAnimation.keepsAnimating(isFocused: isFirstResponder)
    }

    private func clearPresentationRetry() {
        unpresentedFrameCount = 0
        presentationRetryPending = false
    }

    /// The one place a frame comes from. The snapshot and the packed cells
    /// are two fields of a single value captured under one terminal lock, so
    /// they always describe the same instant -- unlike fetching
    /// `snapshot()` and `viewportPacked()` separately, which can tear.
    private func currentRenderFrame() -> FfiRenderFrame {
        frameFetchCount += 1
        return core.renderFrame()
    }

    /// A `CADisplayLink` retains its target, so the view is on the far side
    /// of a weak reference and can still deinit.
    private final class DisplayLinkProxy: NSObject {
        weak var owner: TakoTerminalView?

        @objc func tick() {
            MainActor.assumeIsolated { owner?.displayLinkFired() }
        }
    }

    // MARK: - Theme colors

    /// The theme's colors as the shared renderer wants them: `TerminalTheme`
    /// speaks `CGColor`, the planner speaks straight components.
    static func metalPalette(
        for theme: TerminalTheme,
        encoding: TerminalMetalColorEncoding = .displayEncoded
    ) -> TerminalMetalPalette {
        TerminalMetalPalette(
            background: metalColor(theme.background, alpha: Float(theme.backgroundOpacity), encoding: encoding),
            foreground: metalColor(theme.foreground, encoding: encoding),
            selection: metalColor(theme.selectionBackground, encoding: encoding),
            cursor: metalColor(theme.cursorColor, alpha: Float(theme.cursorOpacity), encoding: encoding),
            selectionForeground: theme.selectionForeground.map { metalColor($0, encoding: encoding) },
            selectionInvertsColors: theme.selectionInvertFgBg
        )
    }

    static func marginFill(_ color: TerminalTheme.WindowPaddingColor) -> TerminalMetalMargins.Fill {
        switch color {
        case .background: return .background
        case .extend: return .extend
        case .extendAlways: return .extendAlways
        }
    }

    /// A theme color in the renderer's encoding. Total: an unconvertible or
    /// componentless color falls back to opaque black rather than trapping.
    static func metalColor(
        _ color: CGColor,
        alpha: Float? = nil,
        encoding: TerminalMetalColorEncoding = .displayEncoded
    ) -> SIMD4<Float> {
        let converted = color.converted(to: srgbSpace, intent: .defaultIntent, options: nil) ?? color
        let parts = converted.components ?? []
        func byte(_ value: CGFloat) -> UInt8 {
            UInt8(clamping: Int((min(max(value, 0), 1) * 255).rounded()))
        }
        switch parts.count {
        case 0:
            return TerminalMetalColor.rgba(r: 0, g: 0, b: 0, alpha: alpha ?? 1, encoding: encoding)
        case 1, 2:
            // Grayscale: one luminance component, then an optional alpha.
            let gray = byte(parts[0])
            let opacity = alpha ?? Float(parts.count == 2 ? parts[1] : 1)
            return TerminalMetalColor.rgba(r: gray, g: gray, b: gray, alpha: opacity, encoding: encoding)
        default:
            return TerminalMetalColor.rgba(
                r: byte(parts[0]),
                g: byte(parts[1]),
                b: byte(parts[2]),
                alpha: alpha ?? Float(parts.count >= 4 ? parts[3] : 1),
                encoding: encoding
            )
        }
    }

    // MARK: - Layout & Drawing

    override public func layoutSubviews() {
        super.layoutSubviews()

        // Cell metrics are baked in at the drawable's scale, so a move to a
        // screen with another one rebuilds the renderer; otherwise the layer
        // just follows the bounds.
        if metalRenderer != nil, effectiveContentScale != metalContentScale {
            rebuildMetalRenderer()
        } else {
            applyMetalLayerGeometry()
        }

        let cellW = renderer.metrics.cellWidth
        let cellH = renderer.metrics.cellHeight
        guard cellW > 0, cellH > 0 else { return }

        let newCols = max(Int(bounds.width / cellW), 1)
        let newRows = max(Int(bounds.height / cellH), 1)
        scheduleGridResize(cols: newCols, rows: newRows)
    }

    private func scheduleGridResize(cols newCols: Int, rows newRows: Int) {
        if newCols == cols, newRows == rows {
            pendingResizeWorkItem?.cancel()
            pendingResizeWorkItem = nil
            pendingGridSize = nil
            return
        }
        if let pendingGridSize,
           pendingGridSize.cols == newCols,
           pendingGridSize.rows == newRows {
            return
        }

        pendingResizeWorkItem?.cancel()
        pendingGridSize = (newCols, newRows)
        let work = DispatchWorkItem { [weak self] in
            self?.applyPendingGridResize()
        }
        pendingResizeWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.resizeSettleDelay,
            execute: work
        )
    }

    private func applyPendingGridResize() {
        cancelKineticScroll()
        pendingResizeWorkItem = nil
        guard let target = pendingGridSize else { return }
        pendingGridSize = nil
        guard target.cols != cols || target.rows != rows else { return }

        TakoLog.resize.info("resize \(cols)×\(rows) → \(target.cols)×\(target.rows)")
        // The view adopts the requested geometry now -- layout and hit
        // testing are about the surface, not about how far the parser has
        // got -- while the engine is reshaped in stream order. The renderer
        // reads its dimensions from the frame the engine published, so the
        // two cannot disagree on screen.
        cols = target.cols
        rows = target.rows
        // A reflow moves every byte that has not been parsed yet. Going
        // through the parser FIFO is what decides, rather than races, which
        // side of the resize each byte lands on.
        parserCoordinator.resize(cols: cols, rows: rows)
    }

    /// The resize once the engine has actually adopted it, in parser order
    /// and after the outcomes of every byte parsed at the old geometry.
    private func applyOrderedResize(cols appliedCols: Int, rows appliedRows: Int) {
        delegate?.terminalView(self, didResizeCols: appliedCols, rows: appliedRows)
        setNeedsDisplay()
    }

    /// Deterministic test seam for the debounced layout path.
    func flushPendingResizeForTesting() {
        pendingResizeWorkItem?.cancel()
        applyPendingGridResize()
    }

    override public func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        // A view off-screen has nothing to present into.
        if newWindow == nil {
            displayLink?.isPaused = true
            cancelKineticScroll()
        }
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        if metalRenderer != nil, effectiveContentScale != metalContentScale {
            rebuildMetalRenderer()
        }
        // Arriving at a session gives you the keyboard. Waiting for a tap
        // meant the first thing typed into a new session went nowhere, which
        // reads as the connection not being up yet rather than as the cursor
        // being somewhere else.
        //
        // Deferred a turn because a view is not reliably able to become first
        // responder while it is still being added to the window.
        if autoFocusKeyboardOnTap {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, !self.isFirstResponder else { return }
                _ = self.becomeFirstResponder()
            }
        }
        setNeedsDisplay()
    }

    /// The CPU fallback, for a host with no Metal device, no shader library
    /// or a pipeline that would not build. It consumes the same single
    /// atomic frame the Metal path does.
    override public func draw(_ rect: CGRect) {
        guard metalLayer == nil else { return }
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)

        let renderFrame = currentRenderFrame()
        let snapshot = renderFrame.snapshot
        let cells = TerminalFrame(
            packed: renderFrame.packedCells,
            cols: Int(snapshot.cols),
            rows: Int(snapshot.rows)
        )

        let cursorVisible = snapshot.cursorVisible
            && snapshot.viewportOffset == 0
            && (blinkStateVisible || !theme.cursorBlink)
        // The phone view draws edge to edge, whatever the theme's padding:
        // window-padding-* belong to the macOS app's windows.
        renderer.drawWindow(
            in: context,
            windowSize: bounds.size,
            layout: TerminalGridLayout(
                viewSize: bounds.size,
                cellSize: CGSize(width: renderer.metrics.cellWidth, height: renderer.metrics.cellHeight),
                padding: TerminalPadding(uniform: 0),
                balance: false
            ),
            paddingColor: theme.windowPaddingColor,
            alternateScreen: snapshot.modes.alternateScreen,
            cols: Int(snapshot.cols),
            rows: Int(snapshot.rows),
            rowProvider: { cells.row($0) },
            graphemes: renderFrame.graphemes,
            cursorRow: Int(snapshot.cursorRow),
            cursorCol: Int(snapshot.cursorCol),
            cursorVisible: cursorVisible,
            cursorStyle: snapshot.cursorStyle,
            selection: snapshot.selection
        )
        context.restoreGState()
    }

    // MARK: - Cursor Blink

    /// One blink timer, invalidated before another is scheduled, so no view
    /// can end up with two.
    private func startBlinkTimer() {
        updateBlinkTimer()
    }

    private func updateBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkStateVisible = true
        guard theme.cursorBlink else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.theme.cursorBlink else { return }
                guard !self.core.isSynchronizedOutputActive() else { return }
                self.blinkStateVisible.toggle()
                self.setNeedsDisplay()
            }
        }
    }

    // MARK: - UIResponder & Software Keyboard (UIKeyInput)

    /// An optional host-owned input view replacing the system keyboard.
    ///
    /// When `nil` (the default), UIKit displays the standard system keyboard.
    /// Updating this view while the terminal is first responder safely refreshes
    /// input views via `reloadInputViews()` without relinquishing first responder
    /// status or interrupting `UIKeyInput`.
    public var customInputView: UIView? {
        didSet {
            guard customInputView !== oldValue else { return }
            if isFirstResponder {
                reloadInputViews()
            }
        }
    }

    override public var inputView: UIView? {
        get { customInputView }
        set { customInputView = newValue }
    }

    override public var canBecomeFirstResponder: Bool { true }

    public var hasText: Bool { true }

    // MARK: Text input traits
    //
    // The keyboard's defaults are for prose: capitalise the first letter,
    // correct and predict words, curl quotes, turn `--` into a dash and a
    // double space into ". ". Every one of those sends a shell something the
    // person did not type -- `Ls`, a curly quote where a straight one quotes
    // a word, a full stop and a backspace in the middle of a command line.
    // A terminal takes the keys as they are.

    public var autocapitalizationType: UITextAutocapitalizationType = .none
    public var autocorrectionType: UITextAutocorrectionType = .no
    public var spellCheckingType: UITextSpellCheckingType = .no
    public var smartQuotesType: UITextSmartQuotesType = .no
    public var smartDashesType: UITextSmartDashesType = .no
    public var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    public var inlinePredictionType: UITextInlinePredictionType = .no

    public func insertText(_ typed: String) {
        guard !typed.isEmpty else { return }
        // A lone no-break space is Option+Space on a hardware keyboard.
        let text = SpaceBar.text(forCommitted: typed)
        revealLiveScreenForUserInput()
        let bytes: Data
        if text == "\n" || text == "\r" {
            bytes = core.encodeKey(event: FfiKeyEvent(
                key: .enter,
                text: "\r",
                physicalText: "",
                unshiftedText: "",
                shift: false, alt: false, ctrl: false, superKey: false,
                press: true, repeat: false, composing: false
            ))
        } else if text.count == 1, let ch = text.first {
            bytes = core.encodeKey(event: FfiKeyEvent(
                key: .character,
                text: String(ch),
                physicalText: String(ch),
                unshiftedText: String(ch),
                shift: false, alt: false, ctrl: false, superKey: false,
                press: true, repeat: false, composing: false
            ))
        } else {
            bytes = core.encodePaste(text: text)
        }
        if !bytes.isEmpty {
            delegate?.terminalView(self, sendInputData: bytes)
        }
    }

    public func deleteBackward() {
        revealLiveScreenForUserInput()
        let bytes = core.encodeKey(event: FfiKeyEvent(
            key: .backspace,
            text: "",
            physicalText: "",
            unshiftedText: "",
            shift: false, alt: false, ctrl: false, superKey: false,
            press: true, repeat: false, composing: false
        ))
        if !bytes.isEmpty {
            delegate?.terminalView(self, sendInputData: bytes)
        }
    }

    // MARK: - Hardware Key Commands & Modifiers

    override public var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: "\u{1b}", modifierFlags: [], action: #selector(handleKeyCommand(_:))), // Esc
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleKeyCommand(_:))),     // Tab
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(handleKeyCommand(_:))),     // Enter
            UIKeyCommand(input: "\u{08}", modifierFlags: [], action: #selector(handleKeyCommand(_:))), // Backspace
        ]
        // Control key combinations: Ctrl+A through Ctrl+Z
        let letters = "abcdefghijklmnopqrstuvwxyz"
        for char in letters {
            commands.append(UIKeyCommand(input: String(char), modifierFlags: .control, action: #selector(handleKeyCommand(_:))))
        }
        // Ctrl+Space is NUL, the mark in Emacs and a common tmux prefix.
        // Without a command of its own it arrives through insertText as a
        // plain space and the Control is lost.
        commands.append(UIKeyCommand(input: " ", modifierFlags: .control, action: #selector(handleKeyCommand(_:))))
        return commands
    }

    @objc private func handleKeyCommand(_ command: UIKeyCommand) {
        guard let input = command.input else { return }
        revealLiveScreenForUserInput()
        let isCtrl = command.modifierFlags.contains(.control)
        let isShift = command.modifierFlags.contains(.shift)
        let isAlt = command.modifierFlags.contains(.alternate)

        let key: FfiKey
        var text = ""

        switch input {
        case UIKeyCommand.inputUpArrow: key = .up
        case UIKeyCommand.inputDownArrow: key = .down
        case UIKeyCommand.inputLeftArrow: key = .left
        case UIKeyCommand.inputRightArrow: key = .right
        case "\u{1b}": key = .escape
        case "\t": key = .tab
        case "\r": key = .enter
        case "\u{08}": key = .backspace
        case " ": key = .space; text = " "
        default:
            key = .character
            text = input
        }

        let event = FfiKeyEvent(
            key: key,
            text: text,
            physicalText: text,
            unshiftedText: text,
            shift: isShift,
            alt: isAlt,
            ctrl: isCtrl,
            superKey: false,
            press: true,
            repeat: false,
            composing: false
        )
        let bytes = core.encodeKey(event: event)
        if !bytes.isEmpty {
            delegate?.terminalView(self, sendInputData: bytes)
        }
    }

    // MARK: - Paste & Copy Actions

    override public func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return UIPasteboard.general.hasStrings
        }
        if action == #selector(copy(_:)) {
            return core.hasSelection()
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override public func paste(_ sender: Any?) {
        guard let string = pasteStringProvider() else { return }
        revealLiveScreenForUserInput()
        let bytes = core.encodePaste(text: string)
        if !bytes.isEmpty {
            delegate?.terminalView(self, sendInputData: bytes)
        }
    }

    override public func copy(_ sender: Any?) {
        guard let text = core.selectedText() else { return }
        copyStringConsumer(text)
    }

    /// Typing in a terminal always targets the live prompt. Leaving the
    /// viewport parked in scrollback makes successfully-sent input invisible
    /// and looks like a dead keyboard, so every native input path follows the
    /// live screen before producing PTY bytes.
    private func revealLiveScreenForUserInput() {
        cancelKineticScroll()
        guard viewportOffset > 0 else { return }
        scrollViewportToBottom()
        notifyScrollPositionIfChanged()
    }

    // MARK: - Gestures & Interactions

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        cancelKineticScroll()
        if autoFocusKeyboardOnTap && !isFirstResponder {
            _ = becomeFirstResponder()
        }
        if core.hasSelection() {
            core.clearSelection()
            setNeedsDisplay()
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !isSelecting else { return }
        let translation = gesture.translation(in: self)
        let cellH = renderer.metrics.cellHeight
        let cellW = renderer.metrics.cellWidth
        guard cellH > 0, cellW > 0 else { return }

        switch gesture.state {
        case .began:
            cancelKineticScroll()
            panAccumulatedY = 0
        case .changed:
            panAccumulatedY += translation.y
            gesture.setTranslation(.zero, in: self)

            let lines = Int(abs(panAccumulatedY) / cellH)
            if lines >= 1 {
                let direction: TerminalPanDirection = panAccumulatedY > 0 ? .up : .down
                let point = gesture.location(in: self)
                let col = min(max(Int(point.x / cellW), 0), cols - 1)
                let row = min(max(Int(point.y / cellH), 0), rows - 1)

                let modes = core.modes()
                let action = TerminalTouchScrollDecision.decide(
                    lines: lines,
                    direction: direction,
                    modes: modes,
                    touchCol: col,
                    touchRow: row,
                    core: core
                )

                performTouchScrollAction(action)
                panAccumulatedY = panAccumulatedY.truncatingRemainder(dividingBy: cellH)
            }
        case .ended:
            let velocityY = gesture.velocity(in: self).y
            let point = gesture.location(in: self)
            panAccumulatedY = 0
            startKineticScroll(initialVelocityY: Double(velocityY), location: point)
        case .cancelled, .failed:
            panAccumulatedY = 0
            cancelKineticScroll()
        default:
            panAccumulatedY = 0
            cancelKineticScroll()
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        let cellW = renderer.metrics.cellWidth
        let cellH = renderer.metrics.cellHeight
        guard cellW > 0, cellH > 0 else { return }

        let col = min(max(Int(point.x / cellW), 0), cols - 1)
        let row = min(max(Int(point.y / cellH), 0), rows - 1)

        switch gesture.state {
        case .began:
            cancelKineticScroll()
            isSelecting = true
            core.startSelection(row: UInt32(row), col: UInt32(col), mode: .linear)
            setNeedsDisplay()
        case .changed:
            if isSelecting {
                core.extendSelection(row: UInt32(row), col: UInt32(col))
                setNeedsDisplay()
            }
        case .ended:
            isSelecting = false
            if core.hasSelection() {
                let activated = isFirstResponder || becomeFirstResponder()
                if activated {
                    showEditMenu(at: point)
                }
            }
        case .cancelled, .failed:
            isSelecting = false
        default:
            break
        }
    }

    // MARK: - Kinetic Momentum Engine

    private func startKineticDisplayLink() {
        guard kineticDisplayLink == nil else { return }
        let proxy = KineticDisplayLinkProxy()
        proxy.owner = self
        let link = CADisplayLink(target: proxy, selector: #selector(KineticDisplayLinkProxy.tick(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        kineticDisplayLink = link
    }

    private func stopKineticDisplayLink() {
        kineticDisplayLink?.invalidate()
        kineticDisplayLink = nil
    }

    private final class KineticDisplayLinkProxy: NSObject {
        weak var owner: TakoTerminalView?

        @objc func tick(_ link: CADisplayLink) {
            MainActor.assumeIsolated { owner?.kineticDisplayLinkFired(link) }
        }
    }

    /// Begins kinetic scroll momentum with the given release velocity and touch point.
    public func startKineticScroll(initialVelocityY: Double, location: CGPoint) {
        cancelKineticScroll()
        guard window != nil || Self.allowOffscreenKineticStepForTesting else { return }
        guard !isSelecting else { return }

        let modes = core.modes()
        kineticInitialModes = modes
        kineticTouchLocation = location
        kineticDeceleration = TerminalKineticDeceleration(initialVelocity: initialVelocityY)

        if kineticDeceleration.isDecelerating {
            kineticDisplayLink?.isPaused = false
        }
    }

    /// Halts active kinetic deceleration and disables the kinetic display link.
    public func cancelKineticScroll() {
        kineticDeceleration.cancel()
        kineticDisplayLink?.isPaused = true
        kineticInitialModes = nil
    }

    @objc private func handleAppDidEnterBackground() {
        cancelKineticScroll()
    }

    private func kineticDisplayLinkFired(_ link: CADisplayLink) {
        guard kineticDeceleration.isDecelerating else {
            kineticDisplayLink?.isPaused = true
            return
        }
        let dt: TimeInterval
        if link.targetTimestamp > link.timestamp {
            dt = link.targetTimestamp - link.timestamp
        } else {
            dt = 1.0 / 60.0
        }
        let clampedDt = min(max(dt, 1.0 / 120.0), 1.0 / 15.0)
        stepKineticScroll(deltaTime: clampedDt)
    }

    /// Advances kinetic momentum by `deltaTime` seconds. Returns `true` if motion or input occurred.
    @discardableResult
    public func stepKineticScroll(deltaTime: TimeInterval) -> Bool {
        guard kineticDeceleration.isDecelerating else {
            cancelKineticScroll()
            return false
        }
        guard window != nil || Self.allowOffscreenKineticStepForTesting else {
            cancelKineticScroll()
            return false
        }
        guard !isSelecting else {
            cancelKineticScroll()
            return false
        }

        let cellH = renderer.metrics.cellHeight
        let cellW = renderer.metrics.cellWidth
        guard cellH > 0, cellW > 0 else {
            cancelKineticScroll()
            return false
        }

        let currentModes = core.modes()
        if let initialModes = kineticInitialModes {
            if currentModes.alternateScreen != initialModes.alternateScreen
                || currentModes.mouseTracking != initialModes.mouseTracking
                || currentModes.alternateScroll != initialModes.alternateScroll
                || currentModes.cursorKeyAppMode != initialModes.cursorKeyAppMode
                || core.isSynchronizedOutputActive() {
                cancelKineticScroll()
                return false
            }
        }

        guard let (lines, direction) = kineticDeceleration.step(deltaTime: deltaTime, cellHeight: Double(cellH)) else {
            if !kineticDeceleration.isDecelerating {
                cancelKineticScroll()
            }
            return false
        }

        let col = min(max(Int(kineticTouchLocation.x / cellW), 0), cols - 1)
        let row = min(max(Int(kineticTouchLocation.y / cellH), 0), rows - 1)

        let action = TerminalTouchScrollDecision.decide(
            lines: lines,
            direction: direction,
            modes: currentModes,
            touchCol: col,
            touchRow: row,
            core: core
        )

        let progressed = performTouchScrollAction(action)
        if !kineticDeceleration.isDecelerating {
            cancelKineticScroll()
        }
        return progressed
    }

    @discardableResult
    private func performTouchScrollAction(_ action: TerminalTouchScrollAction) -> Bool {
        switch action {
        case .scrollViewportUp(let l):
            scrollViewportUp(lines: l)
            notifyScrollPositionIfChanged()
            if viewportOffset >= scrollbackLength {
                cancelKineticScroll()
                return false
            }
            return true
        case .scrollViewportDown(let l):
            scrollViewportDown(lines: l)
            notifyScrollPositionIfChanged()
            if viewportOffset <= 0 {
                cancelKineticScroll()
                return false
            }
            return true
        case .sendInput(let data):
            if !data.isEmpty {
                delegate?.terminalView(self, sendInputData: data)
                return true
            }
            return false
        case .none:
            cancelKineticScroll()
            return false
        }
    }

    private func showEditMenu(at point: CGPoint) {
        let rect = CGRect(origin: point, size: CGSize(width: 1, height: 1))
        if #available(iOS 16.0, *) {
            let interaction: UIEditMenuInteraction
            if let existing = editMenuInteractionStorage as? UIEditMenuInteraction {
                interaction = existing
            } else {
                let menuDelegate = TakoTerminalViewEditMenuDelegate(terminalView: self)
                editMenuInteractionDelegateStorage = menuDelegate
                interaction = UIEditMenuInteraction(delegate: menuDelegate)
                addInteraction(interaction)
                editMenuInteractionStorage = interaction
            }
            let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: point)
            interaction.presentEditMenu(with: config)
        } else {
            let menu = UIMenuController.shared
            menu.showMenu(from: self, rect: rect)
        }
    }
}

/// Backing delegate for `TakoTerminalView`'s `UIEditMenuInteraction`.
///
/// A `nil` delegate leaves the interaction with nothing to present, so the
/// menu appears but shows no items. This supplies the one action the
/// terminal's edit menu ever needs: a native Copy, shown only while there is
/// a selection, wired straight to the existing `copy(_:)` override.
@available(iOS 16.0, *)
@MainActor
final class TakoTerminalViewEditMenuDelegate: NSObject, UIEditMenuInteractionDelegate {
    private weak var terminalView: TakoTerminalView?

    init(terminalView: TakoTerminalView) {
        self.terminalView = terminalView
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard let terminalView, terminalView.core.hasSelection() else {
            return UIMenu(children: [])
        }
        let copyAction = UIAction(title: "Copy") { [weak terminalView] _ in
            terminalView?.copy(nil)
        }
        return UIMenu(children: [copyAction])
    }
}
#endif
