import Foundation
import OSLog

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import CoreGraphics
import CoreText
import Metal
import QuartzCore
import simd

/// Delegate protocol for `TakoTerminalNSView`.
@MainActor
public protocol TakoTerminalNSViewDelegate: AnyObject {
    /// Called when user input (typing, hardware keys, paste, mouse events) produces bytes to send to the PTY.
    func terminalView(_ view: TakoTerminalNSView, sendInputData data: Data)

    /// Called when the terminal engine generates device reply bytes (e.g. DA/DSR/XTVERSION responses) to send to the PTY.
    func terminalView(_ view: TakoTerminalNSView, sendDeviceReplyData data: Data)

    /// Called when the terminal grid dimensions change.
    func terminalView(_ view: TakoTerminalNSView, didResizeCols cols: Int, rows: Int)

    /// A checkpoint was restored into the engine, in parser order.
    ///
    /// Deliberately not `didResizeCols:rows:`: the restored grid is the
    /// canonical one and this view is mirroring it, so its dimensions are
    /// reported, not requested. A host that has a genuinely newer layout
    /// intent sends it back through its own ordered resize path; nothing here
    /// reflows the restored grid on its own.
    func terminalView(_ view: TakoTerminalNSView, didRestoreCheckpoint restore: TerminalCheckpointRestore)

    /// Optional: Called when the terminal window/session title changes.
    func terminalView(_ view: TakoTerminalNSView, didChangeTitle title: String)

    /// Optional: Called when a bell event occurs.
    func terminalViewDidBell(_ view: TakoTerminalNSView)

    /// Shell-integration markers used by hosts to expose command activity.
    func terminalViewCommandDidStart(_ view: TakoTerminalNSView)
    func terminalView(_ view: TakoTerminalNSView, commandDidEnd exitCode: Int32?)

    /// A remote program asked for text to be put on the clipboard (OSC 52).
    ///
    /// Deliberately not written to the pasteboard directly: whether a program on
    /// the other end of a socket may replace what the user last copied is a
    /// policy question, and the host owns it.
    func terminalView(_ view: TakoTerminalNSView, didRequestClipboardCopy text: String)

    /// The shell reported its working directory (OSC 7).
    func terminalView(_ view: TakoTerminalNSView, didChangeWorkingDirectory url: String)

    /// The viewport moved, as a fraction: 0 is the oldest retained line, 1 is
    /// the live screen. A host stores this to restore the position after the
    /// surface is torn down and rebuilt.
    func terminalView(_ view: TakoTerminalNSView, didScrollTo position: Double)

    /// Screen content changed. A host that mirrors the buffer as text -- for
    /// a copy action or an accessibility element -- refreshes on this rather
    /// than polling.
    func terminalViewDidChangeContent(_ view: TakoTerminalNSView)

    /// A command action requested sending text to another pane.
    func terminalView(_ view: TakoTerminalNSView, sendTextToAnotherPane text: String)
}

public extension TakoTerminalNSViewDelegate {
    func terminalView(_ view: TakoTerminalNSView, didRestoreCheckpoint restore: TerminalCheckpointRestore) {}
    func terminalView(_ view: TakoTerminalNSView, didChangeTitle title: String) {}
    func terminalViewDidBell(_ view: TakoTerminalNSView) {}
    func terminalViewCommandDidStart(_ view: TakoTerminalNSView) {}
    func terminalView(_ view: TakoTerminalNSView, commandDidEnd exitCode: Int32?) {}
    func terminalView(_ view: TakoTerminalNSView, didRequestClipboardCopy text: String) {}
    func terminalView(_ view: TakoTerminalNSView, didChangeWorkingDirectory url: String) {}
    func terminalView(_ view: TakoTerminalNSView, didScrollTo position: Double) {}
    func terminalViewDidChangeContent(_ view: TakoTerminalNSView) {}
    func terminalView(_ view: TakoTerminalNSView, sendTextToAnotherPane text: String) {}
}

/// Which Option key, if any, `TakoTerminalNSView.keyDown` treats as Alt
/// instead of a character composer. Backs the `macos-option-as-alt` config
/// key; string cases match its accepted values.
public enum OptionAsAlt: String, Sendable {
    case off = "false"
    case on = "true"
    case left
    case right

    /// Whether this mode applies to the Option key held down in `event`.
    ///
    /// Left and right Option report the same `.option` bit in
    /// `modifierFlags`; telling them apart needs the device-dependent bits
    /// AppKit also sets there (`NX_DEVICELALTKEYMASK` / `NX_DEVICERALTKEYMASK`),
    /// which `NSEvent.ModifierFlags` does not name.
    func appliesTo(_ event: NSEvent) -> Bool {
        switch self {
        case .off: return false
        case .on: return true
        case .left: return event.modifierFlags.rawValue & 0x20 != 0
        case .right: return event.modifierFlags.rawValue & 0x40 != 0
        }
    }
}

/// Whether a Shift-held click reaches a program that reports the mouse, or
/// stays the terminal's, to select text with. Backs `mouse-shift-capture`;
/// the raw values are its config values.
public enum MouseShiftCapture: String, Sendable {
    /// Shift selects, unless the program asks for it (XTSHIFTESCAPE 1).
    case off = "false"
    /// Shift goes to the program, unless it gives it back (XTSHIFTESCAPE 0).
    case on = "true"
    /// Shift always goes to the program, whatever it asks.
    case always
    /// Shift always selects, whatever the program asks.
    case never

    /// Whether Shift is reported to the program, given what the program
    /// asked with XTSHIFTESCAPE -- nil if it has not.
    public func capturesShift(programRequest: Bool?) -> Bool {
        switch self {
        case .off: return programRequest ?? false
        case .on: return programRequest ?? true
        case .always: return true
        case .never: return false
        }
    }
}

/// A public production AppKit terminal surface built over `TakoCore` and
/// the shared `MetalTerminalRenderer`.
///
/// Transport-neutral: accepts ordered bytes via `feed(data:)` or `enqueue(data:)`,
/// and emits user input, device replies and resize events through its `delegate`.
/// Constructing this view never spawns child processes or local PTYs.
/// A pinned command header at the top of the terminal pane while scrolling through long command output.
public struct StickyCommandHeader: Equatable {
    public let commandId: UInt64
    public let command: String
    public let promptRetainedRow: UInt64
    /// 0 = running, 1 = success (exit code 0), 2 = error (non-zero or abandoned/none)
    public let status: UInt8
    public let exitCode: Int32?

    public init(commandId: UInt64, command: String, promptRetainedRow: UInt64, status: UInt8, exitCode: Int32?) {
        self.commandId = commandId
        self.command = command
        self.promptRetainedRow = promptRetainedRow
        self.status = status
        self.exitCode = exitCode
    }
}

@MainActor
/// Open for subclassing: the macOS app layer wraps this surface in its own
/// `SurfaceView`, which adds windowing identity (tabs, splits, focus,
/// restoration) on top rather than reimplementing the terminal.
open class TakoTerminalNSView: NSView, NSUserInterfaceValidations {
    public weak var delegate: TakoTerminalNSViewDelegate?

    public let core: TakoCore

    /// This view's own parser: every byte fed to the engine goes through it,
    /// off Main, and comes back as outcomes applied here in batch order.
    let parserCoordinator: TerminalParserCoordinator

    /// A native scrollbar for visual UX, optionally shown depending on settings.
    private let scrollbarLayer = CALayer()
    private let scrollbarKnob = CALayer()
    let scrollbarMarksLayer = CALayer()
    let gutterMarksLayer = CALayer()
    let stickyHeaderLayer = CALayer()
    let stickyHeaderIndicatorLayer = CALayer()
    let stickyHeaderTextLayer = CATextLayer()
    let stickyHeaderHintLayer = CATextLayer()
    let stickyHeaderSeparatorLayer = CALayer()
    private var isHoveringStickyHeader = false
    public private(set) var activeStickyCommandHeader: StickyCommandHeader?
    struct TrackedCommandOutput {
        let commandId: UInt64
        var command: String
        var promptLine: UInt64?
        var startOutputAbsLine: UInt64 = 0
        var startCursorCol: UInt32 = 0
        var lastOutputAbsLine: UInt64
        var status: UInt8
        var exitCode: Int32?
        var hasNoOutput: Bool
        var outputResolved: Bool = false
    }
    private var trackedCommands: [UInt64: TrackedCommandOutput] = [:]
    private var trackedCommandsEpoch: UInt64 = 0
    var trackedCommandsCountForTesting: Int { trackedCommands.count }
    var activeTrackedCommandsCountForTesting: Int { trackedCommands.values.filter { !$0.hasNoOutput }.count }
    var trackedCommandsForTesting: [UInt64: TrackedCommandOutput] { trackedCommands }
    private var activeRunningCommandId: UInt64? = nil

    private func findRunningCommandId() -> UInt64? {
        guard let newestId = core.newestCommandId(), newestId > 0 else { return nil }
        if let info = core.firstCommandAfter(after: newestId - 1), info.id == newestId, info.running {
            return newestId
        }
        return nil
    }
    private var isDraggingScrollbar = false
    private var scrollbarDragStartKnobY: CGFloat = 0.0
    private var scrollbarDragStartMouseY: CGFloat = 0.0
    private var isUpdatingScroller = false

    /// Gutter marks for OSC 133 command prompt lines (green = success, red = error, blue = running).
    /// Configured via `command-marks = true|false`, default true.
    public var commandMarksEnabled: Bool = true {
        didSet {
            guard commandMarksEnabled != oldValue else { return }
            updateGutterMarks()
            updateScroller()
        }
    }

    /// Whether the sticky command header stays pinned at the top while scrolling through long output.
    /// Configured via `sticky-command-header = true|false`, default true.
    public var stickyCommandHeaderEnabled: Bool = true {
        didSet {
            guard stickyCommandHeaderEnabled != oldValue else { return }
            updateStickyCommandHeader()
        }
    }

    /// Retained row positions for active search hits to display on the scrollbar track (amber/yellow).
    public var searchHitRetainedRows: [UInt64] = [] {
        didSet {
            guard searchHitRetainedRows != oldValue else { return }
            updateScroller()
        }
    }

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
            core.setBaseColors(from: theme)
            core.setDefaultCursorStyle(from: theme)
            core.setGraphemeWidthMethod(from: theme)
            core.setColorScheme(from: theme)
            sendQueuedReplies()
            rebuildMetalRenderer()
            updateBlinkTimer()
            needsDisplay = true
            updateStickyCommandHeader()
        }
    }
    public private(set) var renderer: TerminalRenderer
    public private(set) var cols: Int = 80
    public private(set) var rows: Int = 24

    /// The session title, from OSC 0/2 or set by a host.
    ///
    /// Settable because a host may title a surface itself -- upstream's app
    /// layer names an untitled one after its working directory.
    public var title: String = "" {
        didSet { titleDidChange() }
    }

    /// Called after `title` changes. A host that publishes the title to an
    /// observing UI overrides this to notify; the base does nothing.
    open func titleDidChange() {}
    public private(set) var workingDirectory: String?

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

    /// Drawable pixels per point the current renderer was built for.
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
    private(set) var presentationRetryPending: Bool = false
    /// Frames in a row that were planned and never reached the layer.
    private(set) var unpresentedFrameCount: Int = 0
    /// A redraw a synchronized-output frame deferred rather than drew.
    private(set) var redrawHeldBySynchronizedOutput: Bool = false
    /// Command mark updates deferred while a synchronized-output frame was active.
    private(set) var commandMarksHeldBySynchronizedOutput: Bool = false
    /// Stops drawing without stopping the terminal. While this is true, the
    /// parser, model, damage tracking, scrolling and delegate callbacks keep
    /// running; only fetching and presenting a frame is deferred.
    ///
    /// Turning it back off coalesces everything that arrived while paused into
    /// the normal single pending presentation.
    public var isPresentationPaused: Bool = false {
        didSet {
            guard oldValue != isPresentationPaused else { return }
            if isPresentationPaused {
                // Cancel an AppKit invalidation without clearing redrawPending:
                // all hidden damage remains one coalesced presentation debt.
                super.needsDisplay = false
                updateBlinkTimer()
                displayLink?.isPaused = true
                cancelPresentationThrottle()
            } else {
                updateBlinkTimer()
                resumePresentationIfNeeded()
            }
        }
    }
    /// The display link driving Metal redraws on macOS 14+.
    private var displayLink: CADisplayLink?
    private let presentationRateLimiter = PresentationRateLimiter()
    private var isDrivingPresentation = false
    private var pendingPresentationThrottle: DispatchWorkItem?
    // Tests replace the queue hop with a deterministic, manually-fired
    // one-shot. Production always uses the main queue below.
    private var presentationThrottleSchedulerForTesting: ((TimeInterval, DispatchWorkItem) -> Void)?

    /// Caps this surface's presentation attempts while preserving parser and
    /// model progress. Nil, non-finite values, rates above 10,000 FPS, and
    /// rates below one frame per day leave behavior unlimited.
    public var maximumPresentationFramesPerSecond: Double? {
        get { presentationRateLimiter.maximumFramesPerSecond }
        set {
            presentationRateLimiter.maximumFramesPerSecond = newValue
            cancelPresentationThrottle()
            drivePresentationIfNeeded()
        }
    }

    private var pendingResizeWorkItem: DispatchWorkItem?
    private var pendingGridSize: (cols: Int, rows: Int)?
    private static let resizeSettleDelay: TimeInterval = 0.05

    private static var metalLibraryBundle: Bundle { ShaderBundle.resources }

    /// Test seam: forces the CPU fallback on a machine that does have a GPU.
    public static var isMetalDisabledForTesting = false

    /// Test seam: supplies the shader library when the host bundle carries no
    /// compiled default one.
    public static var metalLibraryProviderForTesting: ((MTLDevice) -> MTLLibrary?)?

    // Cursor blink state
    private(set) var blinkTimer: Timer?
    private var blinkStateVisible: Bool = true
    var isBlinkStateVisibleForTesting: Bool { blinkStateVisible }

    /// Reads the text used by the native paste action.
    var pasteStringProvider: () -> String? = { NSPasteboard.general.string(forType: .string) }

    /// Writes the text used by the native copy action.
    var copyStringConsumer: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Handler invoked when a command action requests sending text to another pane.
    public var sendTextToAnotherPaneHandler: ((String) -> Void)?

    // Screen buffer & private mode properties
    public var isAlternateScreen: Bool { core.modes().alternateScreen }
    public var isAlternateScroll: Bool { core.modes().alternateScroll }

    // Selection & Mouse interaction state
    private var selectionAnchor: (row: Int, col: Int)?
    private var reportingCurrentPress: Bool = false
    /// Shift-left is explicitly native selection, even while a TUI owns the
    /// ordinary mouse stream. This state is latched at press so modifier
    /// changes during the drag cannot leak mouse reports.
    private var nativeSelectionCurrentPress: Bool = false
    private var expandedSelectionPress: Bool = false
    public private(set) var mouseCell: (row: Int, col: Int)?

    /// Place the pointer cell without an `NSEvent`.
    ///
    /// A host whose pointer input arrives as coordinates from a binding layer
    /// rather than as events needs to keep this in step; real mouse events
    /// update it themselves.
    public func setMouseCell(_ cell: (row: Int, col: Int)?) {
        mouseCell = cell
    }

    // IME marked text
    public var markedText: String?
    var keyTextAccumulator: String?

    /// Which Option key, if any, is treated as Alt rather than a character
    /// composer. `.off` (the default) is today's behaviour: Option composes
    /// characters such as `@` on a German layout, through the input context.
    public var optionAsAlt: OptionAsAlt = .off

    /// Whether a Shift-held click goes to a program reporting the mouse.
    public var mouseShiftCapture: MouseShiftCapture = .off

    /// Whether a plain click on the cursor's prompt line moves the cursor
    /// there instead of just placing the selection anchor. Backs
    /// `cursor-click-to-move`, default true.
    public var cursorClickToMove: Bool = true

    /// Whether URLs in the visible text are detected so that holding Command
    /// underlines the one under the pointer and Command-click opens it.
    /// Backs `link-url`, default true. OSC 8 hyperlinks are unaffected by
    /// this flag -- they open on Command-click regardless.
    public var linkURLDetectionEnabled: Bool = true

    /// Opens a link found under the pointer -- an OSC 8 hyperlink or text
    /// matched by `Self.urlPattern`. Defaults to the user's registered
    /// handler; a test substitutes this so nothing here actually launches
    /// an app.
    nonisolated(unsafe) public static var openURL: (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }

    /// Hook for presenting a save panel; can be replaced in tests to avoid modal UI.
    public static var saveFilePanel: (
        _ text: String,
        _ suggestedFilename: String,
        _ window: NSWindow?,
        _ completion: @escaping (URL?) -> Void
    ) -> Void = { text, suggestedFilename, window, completion in
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.prompt = "Save"
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let targetURL = panel.url else {
                completion(nil)
                return
            }
            do {
                try text.write(to: targetURL, atomically: true, encoding: .utf8)
                completion(targetURL)
            } catch {
                completion(nil)
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    /// Matches the schemes upstream's `link-url` looks for: `http`,
    /// `https`, `file` and `mailto`.
    static let urlPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try -- a literal, always-valid pattern
        try! NSRegularExpression(pattern: #"(?:https?|file)://[^\s<>"']+|mailto:[^\s<>"']+"#)
    }()

    /// The link under the pointer while Command is held, if any -- an OSC 8
    /// hyperlink cell span, or `linkURLDetectionEnabled` text matched by
    /// `Self.urlPattern`. Drives the pointing-hand cursor and underline.
    public private(set) var hoveredLink: (url: URL, row: Int, colStart: Int, colEnd: Int)?

    /// A thin bar under `hoveredLink`'s cells, positioned in view
    /// coordinates -- the same ones `cellOrigin` and `cellWidth` use.
    private lazy var linkUnderlineLayer: CALayer = {
        let layer = CALayer()
        layer.backgroundColor = NSColor.labelColor.cgColor
        layer.isHidden = true
        return layer
    }()

    /// Hide the pointer while typing, until it moves.
    public var hidesMouseWhileTyping = false

    /// How the pointer is hidden; tests substitute it.
    nonisolated(unsafe) static var hideMouseUntilMoved: () -> Void = { NSCursor.setHiddenUntilMouseMoves(true) }

    /// Called when a mouse press that left a selection ends -- a drag, or a
    /// double or triple click. A host that copies on select does it here.
    open func selectionDidFinish() {}

    public init(frame: NSRect = .zero, core: TakoCore? = nil, theme: TerminalTheme = .takoDefault) {
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
        self.core.setColorScheme(from: theme)
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
        self.core.setColorScheme(from: theme)
    }

    // Destruction needs no deactivation of its own, and cannot have one:
    // `deinit` is not main-actor isolated, so it may not touch the context.
    // It does not need to. A view cannot be deallocated while it is installed
    // in a window, because the window retains it, so the move to a nil window
    // has already run `updateInputContextActivation` and released the context
    // before any of this. `testLeavingTheWindowReleasesIt` pins that.
    deinit {
        NotificationCenter.default.removeObserver(self)
        pendingPresentationThrottle?.cancel()
        blinkTimer?.invalidate()
        displayLink?.invalidate()
        displayLink = nil
        pendingResizeWorkItem?.cancel()
        parserCoordinator.shutDown()
        metalLayer?.removeFromSuperlayer()
        metalLayer = nil
        metalRenderer = nil
        lastFrameStatistics = nil
    }

    private func setupView() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.addSublayer(linkUnderlineLayer)
        if NSApp != nil {
            registerForDraggedTypes([.fileURL, .string])
        }

        gutterMarksLayer.zPosition = 9000
        gutterMarksLayer.masksToBounds = true
        self.layer?.addSublayer(gutterMarksLayer)

        stickyHeaderLayer.zPosition = 9500
        stickyHeaderLayer.masksToBounds = true
        stickyHeaderLayer.isHidden = true
        stickyHeaderLayer.backgroundColor = stickyHeaderBackgroundColor(hovering: false)

        stickyHeaderSeparatorLayer.backgroundColor = stickyHeaderSeparatorColor()
        stickyHeaderLayer.addSublayer(stickyHeaderSeparatorLayer)

        stickyHeaderIndicatorLayer.cornerRadius = 3.5
        stickyHeaderIndicatorLayer.masksToBounds = true
        stickyHeaderLayer.addSublayer(stickyHeaderIndicatorLayer)

        stickyHeaderTextLayer.truncationMode = .end
        stickyHeaderTextLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        stickyHeaderLayer.addSublayer(stickyHeaderTextLayer)

        stickyHeaderHintLayer.string = "Jump to prompt ↑"
        stickyHeaderHintLayer.alignmentMode = .right
        stickyHeaderHintLayer.foregroundColor = stickyHeaderHintColor(hovering: false)
        stickyHeaderHintLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        stickyHeaderLayer.addSublayer(stickyHeaderHintLayer)

        self.layer?.addSublayer(stickyHeaderLayer)

        scrollbarLayer.zPosition = 9999
        scrollbarLayer.backgroundColor = NSColor(white: 0.05, alpha: 0.3).cgColor
        scrollbarLayer.cornerRadius = 5.0
        scrollbarLayer.masksToBounds = true
        scrollbarMarksLayer.zPosition = 10
        scrollbarMarksLayer.masksToBounds = true
        scrollbarLayer.addSublayer(scrollbarMarksLayer)
        scrollbarKnob.zPosition = 20
        scrollbarKnob.cornerRadius = 3.5
        scrollbarKnob.backgroundColor = NSColor.white.withAlphaComponent(0.4).cgColor
        scrollbarLayer.addSublayer(scrollbarKnob)
        scrollbarLayer.opacity = 1.0
        self.layer?.addSublayer(scrollbarLayer)

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
        setupAccessibility()
        startBlinkTimer()
    }

    private func setupAccessibility() {
        setAccessibilityIdentifier("terminal")
    }

    override public func isAccessibilityElement() -> Bool { true }
    override public func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override public func accessibilityLabel() -> String? { "Terminal" }

    override public func accessibilityValue() -> Any? {
        plainText(startRow: 0, maxRows: rows)
    }

    override public func accessibilitySelectedText() -> String? {
        core.selectedText()
    }

    /// In UTF-16 units, as accessibility ranges are: a cluster counts once
    /// per unit, not once.
    override public func accessibilityNumberOfCharacters() -> Int {
        (accessibilityValue() as? String)?.utf16.count ?? 0
    }

    // MARK: - Core Host Operations

    /// Feed raw bytes received from the PTY host connection synchronously.
    public func feed(data: Data) {
        parserCoordinator.feedSynchronously(data)
    }

    /// Hand bulk PTY output to the parser without waiting for it.
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

        // The sub-cell accumulator holds a fraction of a row measured against
        // the grid that has just been replaced. Carrying it across would
        // present the new grid at an offset it never agreed to. Clearing it
        // belongs *here*, not before the import: a refused checkpoint leaves
        // the engine untouched, so moving the presented viewport for it would
        // be a visible side effect of an operation that did not happen.
        subCellScroll.clear()

        // Report, do not resize: no `core.resize`, and no synthesized
        // `terminalView(_:didResizeCols:rows:)`.
        cols = restore.cols
        rows = restore.rows
        lastReportedScrollPosition = core.scrollPosition()
        trackedCommands.removeAll()
        trackedCommandsEpoch = core.stateEpoch()
        if stickyCommandHeaderEnabled {
            activeRunningCommandId = findRunningCommandId()
            if let runningId = activeRunningCommandId {
                let firstLine = core.firstRetainedLine()
                let totalScrollback = Int(core.scrollbackLen())
                let cmdText = core.firstCommandAfter(after: runningId - 1)?.input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let promptLine = core.commandMarks().first(where: { $0.commandId == runningId })?.promptLine
                let startLine = computeStartOutputAbsLine(
                    promptLine: promptLine,
                    cmdText: cmdText,
                    firstRetainedLine: firstLine,
                    totalScrollback: totalScrollback
                )
                let absLine = firstLine + UInt64(totalScrollback) + UInt64(core.cursorRow())
                trackedCommands[runningId] = TrackedCommandOutput(
                    commandId: runningId,
                    command: cmdText,
                    promptLine: promptLine,
                    startOutputAbsLine: startLine,
                    startCursorCol: core.cursorCol(),
                    lastOutputAbsLine: max(absLine, startLine),
                    status: 0,
                    exitCode: nil,
                    hasNoOutput: false,
                    outputResolved: false
                )
            }
        } else {
            activeRunningCommandId = nil
        }
        TakoLog.resize.info("checkpoint restored \(restore.cols)×\(restore.rows)")
        updateScroller()
        delegate?.terminalView(self, didRestoreCheckpoint: restore)

        delegate?.terminalViewDidChangeContent(self)
        scheduleRedraw()
    }

    /// Replies the engine queued outside a parse -- a colour-scheme change
    /// told to a program that set mode 2031 -- sent now, not with whatever
    /// the program prints next.
    private func sendQueuedReplies() {
        let queued = core.takeOutput()
        if !queued.isEmpty {
            delegate?.terminalView(self, sendDeviceReplyData: queued)
        }
    }

    /// The one place a parsed batch becomes AppKit state, always on Main and
    /// always in the order the batches were parsed.
    private func apply(_ outcomes: [FfiFeedOutcome]) {
        var totalDamage = false
        var commandStatusChanged = false
        for outcome in outcomes {
            // Drain device replies (DA/DSR/XTVERSION/Kitty replies)
            if !outcome.output.isEmpty {
                delegate?.terminalView(self, sendDeviceReplyData: outcome.output)
            }

            // Drain host events
            for event in outcome.events {
                switch event {
                case .titleChanged(let title):
                    self.title = title
                    TakoLog.feed.info("title → \"\(title)\"")
                    delegate?.terminalView(self, didChangeTitle: title)
                case .bell:
                    TakoLog.feed.debug("bell")
                    delegate?.terminalViewDidBell(self)
                case .commandStart(let id):
                    commandStatusChanged = true
                    guard stickyCommandHeaderEnabled else {
                        if let cmdId = id {
                            activeRunningCommandId = cmdId
                        }
                        delegate?.terminalViewCommandDidStart(self)
                        break
                    }
                    let currentEpoch = core.stateEpoch()
                    if trackedCommandsEpoch != currentEpoch {
                        trackedCommands.removeAll()
                        trackedCommandsEpoch = currentEpoch
                        activeRunningCommandId = nil
                    }
                    let targetId = id ?? core.newestCommandId()
                    if let cmdId = targetId {
                        activeRunningCommandId = cmdId
                        let firstLine = core.firstRetainedLine()
                        let totalScrollback = Int(core.scrollbackLen())
                        let cmdText = core.firstCommandAfter(after: cmdId - 1)?.input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let promptLine = core.commandMarks().first(where: { $0.commandId == cmdId })?.promptLine
                        let startLine = computeStartOutputAbsLine(
                            promptLine: promptLine,
                            cmdText: cmdText,
                            firstRetainedLine: firstLine,
                            totalScrollback: totalScrollback
                        )
                        let absLine = firstLine + UInt64(totalScrollback) + UInt64(core.cursorRow())
                        trackedCommands[cmdId] = TrackedCommandOutput(
                            commandId: cmdId,
                            command: cmdText,
                            promptLine: promptLine,
                            startOutputAbsLine: startLine,
                            startCursorCol: core.cursorCol(),
                            lastOutputAbsLine: max(absLine, startLine),
                            status: 0,
                            exitCode: nil,
                            hasNoOutput: false,
                            outputResolved: false
                        )
                    }
                    delegate?.terminalViewCommandDidStart(self)
                case .commandEnd(let exitCode):
                    commandStatusChanged = true
                    guard stickyCommandHeaderEnabled else {
                        activeRunningCommandId = nil
                        delegate?.terminalView(self, commandDidEnd: exitCode)
                        break
                    }
                    let currentEpoch = core.stateEpoch()
                    if trackedCommandsEpoch != currentEpoch {
                        trackedCommands.removeAll()
                        trackedCommandsEpoch = currentEpoch
                        activeRunningCommandId = nil
                    }
                    let targetId = activeRunningCommandId ?? core.newestCommandId()
                    if let cmdId = targetId {
                        let existing = trackedCommands[cmdId]
                        let promptLine = existing?.promptLine ?? core.commandMarks().first(where: { $0.commandId == cmdId })?.promptLine
                        let status: UInt8 = (exitCode == 0 ? 1 : 2)
                        let cmdText = (existing?.command.isEmpty == false)
                            ? existing!.command
                            : (core.firstCommandAfter(after: cmdId - 1)?.input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                        let startLine: UInt64
                        if let existingStart = existing?.startOutputAbsLine, existingStart > (promptLine ?? 0) {
                            startLine = existingStart
                        } else {
                            startLine = computeStartOutputAbsLine(
                                promptLine: promptLine,
                                cmdText: cmdText,
                                firstRetainedLine: core.firstRetainedLine(),
                                totalScrollback: Int(core.scrollbackLen())
                            )
                        }
                        var tracked = existing ?? TrackedCommandOutput(
                            commandId: cmdId,
                            command: cmdText,
                            promptLine: promptLine,
                            startOutputAbsLine: startLine,
                            startCursorCol: 0,
                            lastOutputAbsLine: startLine,
                            status: status,
                            exitCode: exitCode,
                            hasNoOutput: false,
                            outputResolved: false
                        )
                        tracked.promptLine = promptLine
                        tracked.startOutputAbsLine = startLine
                        tracked.status = status
                        tracked.exitCode = exitCode
                        tracked.outputResolved = false
                        if tracked.command.isEmpty, !cmdText.isEmpty {
                            tracked.command = cmdText
                        }
                        trackedCommands[cmdId] = tracked
                    }
                    activeRunningCommandId = nil
                    delegate?.terminalView(self, commandDidEnd: exitCode)
                case .clipboardSet(let text):
                    TakoLog.feed.info("OSC 52 → clipboard (\(text.count) chars)")
                    delegate?.terminalView(self, didRequestClipboardCopy: text)
                case .pwdChanged(let url):
                    let path = URL(string: url)?.path ?? url
                    self.workingDirectory = path
                    delegate?.terminalView(self, didChangeWorkingDirectory: path)
                default:
                    break
                }
            }

            if stickyCommandHeaderEnabled && outcome.hasDamage {
                if activeRunningCommandId == nil {
                    activeRunningCommandId = findRunningCommandId()
                }
                if let cmdId = activeRunningCommandId {
                    let totalScrollback = UInt64(core.scrollbackLen())
                    let cursorRow = UInt64(core.cursorRow())
                    let firstLine = core.firstRetainedLine()
                    let absLine = firstLine + totalScrollback + cursorRow
                    if var tracked = trackedCommands[cmdId] {
                        tracked.lastOutputAbsLine = max(tracked.lastOutputAbsLine, absLine)
                        if tracked.command.isEmpty, let info = core.firstCommandAfter(after: cmdId - 1), let input = info.input?.trimmingCharacters(in: .whitespacesAndNewlines) {
                            tracked.command = input
                        }
                        trackedCommands[cmdId] = tracked
                    } else {
                        let cmdText = core.firstCommandAfter(after: cmdId - 1)?.input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let promptLine = core.commandMarks().first(where: { $0.commandId == cmdId })?.promptLine
                        trackedCommands[cmdId] = TrackedCommandOutput(
                            commandId: cmdId,
                            command: cmdText,
                            promptLine: promptLine,
                            startOutputAbsLine: absLine,
                            startCursorCol: 0,
                            lastOutputAbsLine: absLine,
                            status: 0,
                            exitCode: nil,
                            hasNoOutput: false,
                            outputResolved: false
                        )
                    }
                }
            }

            // Synchronized output suppression & damage-aware redraw
            if outcome.hasDamage && !outcome.synchronizedOutputActive {
                totalDamage = true
                updateScroller()
                scheduleRedraw()
            }
        }

        if redrawHeldBySynchronizedOutput && !core.isSynchronizedOutputActive() {
            redrawHeldBySynchronizedOutput = false
            scheduleRedraw()
        }

        if commandStatusChanged && core.isSynchronizedOutputActive() {
            commandMarksHeldBySynchronizedOutput = true
        }

        let shouldUpdateMarksForCommandStatus = (commandStatusChanged || commandMarksHeldBySynchronizedOutput)
            && !totalDamage
            && !core.isSynchronizedOutputActive()

        if shouldUpdateMarksForCommandStatus {
            commandMarksHeldBySynchronizedOutput = false
            updateScroller()
        } else if totalDamage {
            commandMarksHeldBySynchronizedOutput = false
        }

        if totalDamage {
            TakoLog.render.debug("damage → scheduleRedraw (\(outcomes.count) outcomes)")
            delegate?.terminalViewDidChangeContent(self)
            notifyScrollPositionIfChanged()
        }
    }

    private var lastReportedScrollPosition: Double = 1

    func updateScroller() {
        updateGutterMarks()
        updateStickyCommandHeader()

        let trackHeight = bounds.height
        guard trackHeight > 0 else { return }
        
        let scrollerWidth: CGFloat = 10.0
        scrollbarLayer.frame = CGRect(x: bounds.width - scrollerWidth - 2.0, y: 2.0, width: scrollerWidth, height: trackHeight - 4.0)
        
        let maxScroll = scrollbackLength
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollbarLayer.opacity = 1.0
        
        let usableHeight = scrollbarLayer.bounds.height
        scrollbarMarksLayer.frame = scrollbarLayer.bounds

        let modes = core.modes()
        if modes.alternateScreen && modes.alternateScroll {
            scrollbarMarksLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            let knobHeight: CGFloat = 44.0
            let knobY = (usableHeight - knobHeight) / 2.0
            scrollbarKnob.frame = CGRect(x: 1.5, y: knobY, width: scrollerWidth - 3.0, height: knobHeight)
            scrollbarKnob.backgroundColor = NSColor.white.withAlphaComponent(0.5).cgColor
        } else if maxScroll == 0 {
            updateScrollbarMarks(usableHeight: usableHeight, totalLines: Double(core.rows()), scrollerWidth: scrollerWidth)
            scrollbarKnob.frame = CGRect(x: 1.5, y: 1.5, width: scrollerWidth - 3.0, height: max(0, usableHeight - 3.0))
            scrollbarKnob.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        } else {
            let visibleLines = Double(core.rows())
            let totalLines = Double(maxScroll) + visibleLines
            updateScrollbarMarks(usableHeight: usableHeight, totalLines: totalLines, scrollerWidth: scrollerWidth)

            let proportion = max(0.05, min(1.0, visibleLines / totalLines))
            let knobHeight = max(usableHeight * CGFloat(proportion), 24.0)
            let maxKnobTravel = max(0, usableHeight - knobHeight)
            
            let pos = core.scrollPosition()
            let knobY = maxKnobTravel * CGFloat(1.0 - pos)
            
            scrollbarKnob.frame = CGRect(x: 1.5, y: knobY, width: scrollerWidth - 3.0, height: knobHeight)
            scrollbarKnob.backgroundColor = isDraggingScrollbar
                ? NSColor.white.withAlphaComponent(0.85).cgColor
                : NSColor.white.withAlphaComponent(0.45).cgColor
        }
        CATransaction.commit()
    }

    /// Renders command marks and search hits on the scrollbar track.
    private func updateScrollbarMarks(usableHeight: CGFloat, totalLines: Double, scrollerWidth: CGFloat) {
        guard usableHeight > 0, totalLines > 0, !core.modes().alternateScreen else {
            scrollbarMarksLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            return
        }

        let markWidth: CGFloat = scrollerWidth - 2.0
        let markHeight: CGFloat = 2.0
        let markX: CGFloat = 1.0

        // Coalesce / bin marks by rendered integer Y coordinate so that multiple
        // search hits or command marks mapping to the same pixel row don't allocate
        // duplicate CALayers (capped at usableHeight layers).
        var binnedMarks: [Int: CGColor] = [:]

        // Search hits first so command marks (success/error/running) take precedence over search marks
        if !searchHitRetainedRows.isEmpty {
            let searchColor = NSColor(red: 1.0, green: 0.78, blue: 0.1, alpha: 0.95).cgColor
            let uniqueRows = Set(searchHitRetainedRows)
            for row in uniqueRows {
                let frac = totalLines > 1 ? max(0.0, min(1.0, Double(row) / (totalLines - 1.0))) : 0.0
                let markY = max(0.0, min(usableHeight - markHeight, usableHeight * CGFloat(1.0 - frac) - markHeight / 2.0))
                binnedMarks[Int(round(markY))] = searchColor
            }
        }

        // Command marks on scrollbar
        if commandMarksEnabled {
            for cmd in core.commandMarks() {
                let color: CGColor
                switch cmd.status {
                case 1: color = NSColor.systemGreen.cgColor
                case 2: color = NSColor.systemRed.cgColor
                default: color = NSColor.systemBlue.cgColor
                }
                let frac = totalLines > 1 ? max(0.0, min(1.0, Double(cmd.retainedRow) / (totalLines - 1.0))) : 0.0
                let markY = max(0.0, min(usableHeight - markHeight, usableHeight * CGFloat(1.0 - frac) - markHeight / 2.0))
                binnedMarks[Int(round(markY))] = color
            }
        }

        if binnedMarks.isEmpty {
            scrollbarMarksLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            return
        }

        var sublayers = scrollbarMarksLayer.sublayers ?? []
        var layerIndex = 0

        for (yInt, color) in binnedMarks.sorted(by: { $0.key < $1.key }) {
            let markY = CGFloat(yInt)
            let layer: CALayer
            if layerIndex < sublayers.count {
                layer = sublayers[layerIndex]
            } else {
                layer = CALayer()
                layer.cornerRadius = 1.0
                scrollbarMarksLayer.addSublayer(layer)
                sublayers.append(layer)
            }
            layerIndex += 1

            layer.frame = CGRect(x: markX, y: markY, width: markWidth, height: markHeight)
            layer.backgroundColor = color
        }

        while sublayers.count > layerIndex {
            sublayers.removeLast().removeFromSuperlayer()
        }
    }


    /// Renders thin vertical marks beside each command's prompt line in the left gutter.
    func updateGutterMarks() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard commandMarksEnabled, !core.modes().alternateScreen else {
            gutterMarksLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            return
        }

        let layout = gridLayout
        let gutterWidth = layout.left
        guard gutterWidth >= 2.0 else {
            gutterMarksLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            return
        }

        gutterMarksLayer.frame = CGRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)

        let marks = core.commandMarks()
        if marks.isEmpty {
            gutterMarksLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            return
        }

        let totalScrollback = Int(core.scrollbackLen())
        let offset = Int(core.viewportOffset())
        let topVisible = totalScrollback - offset
        let screenRows = Int(core.rows())

        let markWidth: CGFloat = 3.0
        let markX: CGFloat = max(1.0, gutterWidth - markWidth - 2.0)
        let markHeight: CGFloat = max(4.0, cellHeight - 4.0)

        var binnedGutterMarks: [Int: CGColor] = [:]
        for mark in marks {
            let screenRow = Int(mark.retainedRow) - topVisible
            guard screenRow >= 0, screenRow < screenRows else { continue }

            let color: CGColor
            switch mark.status {
            case 1: color = NSColor.systemGreen.cgColor
            case 2: color = NSColor.systemRed.cgColor
            default: color = NSColor.systemBlue.cgColor
            }
            binnedGutterMarks[screenRow] = color
        }

        if binnedGutterMarks.isEmpty {
            gutterMarksLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            return
        }

        var sublayers = gutterMarksLayer.sublayers ?? []
        var layerIndex = 0

        for (screenRow, color) in binnedGutterMarks.sorted(by: { $0.key < $1.key }) {
            let cellY = bounds.height - layout.top - CGFloat(screenRow + 1) * cellHeight
            let markY = cellY + (cellHeight - markHeight) / 2.0

            let markLayer: CALayer
            if layerIndex < sublayers.count {
                markLayer = sublayers[layerIndex]
            } else {
                markLayer = CALayer()
                markLayer.cornerRadius = markWidth / 2.0
                gutterMarksLayer.addSublayer(markLayer)
                sublayers.append(markLayer)
            }
            layerIndex += 1

            markLayer.frame = CGRect(x: markX, y: markY, width: markWidth, height: markHeight)
            markLayer.backgroundColor = color
        }

        while sublayers.count > layerIndex {
            sublayers.removeLast().removeFromSuperlayer()
        }
    }

    /// Computes the absolute line index where a command's output begins, accounting for
    /// multiline input, wrapped lines, and secondary continuation prompts (OSC 133;A;k=s).
    private func computeStartOutputAbsLine(
        promptLine: UInt64?,
        cmdText: String,
        firstRetainedLine: UInt64,
        totalScrollback: Int
    ) -> UInt64 {
        guard let pLine = promptLine else {
            return firstRetainedLine
        }

        var promptContinuations: UInt64 = 0
        if pLine >= firstRetainedLine {
            var r = pLine - firstRetainedLine + 1
            let totalRetained = UInt64(totalScrollback + Int(core.rows()))
            while r < totalRetained && core.retainedSemanticPrompt(row: r) == 2 {
                promptContinuations += 1
                r += 1
            }
        }

        let terminalCols = max(1, Int(core.cols()))
        let lines = cmdText.split(separator: "\n", omittingEmptySubsequences: false)
        var wrappedInputRows: UInt64 = 0
        for line in lines {
            let rowsForLine = max(1, (line.count + terminalCols - 1) / terminalCols)
            wrappedInputRows += UInt64(rowsForLine)
        }

        let inputRows = max(wrappedInputRows, promptContinuations + 1)
        return max(firstRetainedLine, pLine + inputRows)
    }

    /// Computes the sticky command header for the current viewport state, or nil if unpinned.
    public func currentStickyCommandHeader() -> StickyCommandHeader? {
        guard stickyCommandHeaderEnabled, !core.modes().alternateScreen else {
            return nil
        }

        let currentEpoch = core.stateEpoch()
        if trackedCommandsEpoch != currentEpoch {
            trackedCommands.removeAll()
            trackedCommandsEpoch = currentEpoch
            activeRunningCommandId = findRunningCommandId()
        }

        let totalScrollback = Int(core.scrollbackLen())
        let offset = Int(core.viewportOffset())
        let vpTop = totalScrollback - offset
        guard vpTop >= 0 else { return nil }

        let firstRetainedLine = core.firstRetainedLine()
        let vpTopAbsLine = firstRetainedLine + UInt64(vpTop)
        let currentBottom = firstRetainedLine + UInt64(totalScrollback) + UInt64(core.cursorRow())

        // Refresh/prune existing tracked commands for evicted outputs or removed history
        if let oldestRecord = core.firstCommandAfter(after: 0) {
            let oldestId = oldestRecord.id
            for (id, cmd) in trackedCommands {
                if cmd.status != 0 && !cmd.hasNoOutput && cmd.lastOutputAbsLine < firstRetainedLine {
                    trackedCommands[id]?.hasNoOutput = true
                }
            }
            trackedCommands = trackedCommands.filter { id, _ in
                id >= oldestId
            }
        } else {
            trackedCommands.removeAll()
        }

        // Bound memory: if tracked cache grows, prune distant records
        if trackedCommands.count > 128 {
            let sortedKeys = trackedCommands.keys.sorted()
            let pruneCount = trackedCommands.count - 64
            for id in sortedKeys.prefix(pruneCount) {
                if id != activeRunningCommandId {
                    trackedCommands.removeValue(forKey: id)
                }
            }
        }

        let marks = core.commandMarks().sorted(by: { $0.promptLine < $1.promptLine })

        // Find candidate command that intersects or precedes vpTopAbsLine
        let candidateId: UInt64?
        if let precedingMark = marks.last(where: { $0.promptLine <= vpTopAbsLine }) {
            candidateId = precedingMark.commandId
        } else if let firstMark = marks.first {
            // All retained prompt marks start below vpTopAbsLine.
            // If an earlier command's output extends into the retained buffer, its prompt was evicted.
            candidateId = firstMark.commandId > 1 ? firstMark.commandId - 1 : nil
        } else {
            // No prompt marks retained in scrollback (prompt evicted or running command)
            candidateId = activeRunningCommandId ?? findRunningCommandId() ?? core.newestCommandId()
        }

        guard let targetId = candidateId else {
            return nil
        }

        let resolvedCmd: TrackedCommandOutput?
        if let existing = trackedCommands[targetId] {
            if existing.status == 0 {
                // Refresh bounds for running command
                var runningCmd = existing
                runningCmd.lastOutputAbsLine = max(runningCmd.lastOutputAbsLine, currentBottom)
                if runningCmd.startOutputAbsLine <= (existing.promptLine ?? 0) {
                    runningCmd.startOutputAbsLine = computeStartOutputAbsLine(
                        promptLine: existing.promptLine,
                        cmdText: existing.command,
                        firstRetainedLine: firstRetainedLine,
                        totalScrollback: totalScrollback
                    )
                }
                // Check if running command has finished
                if let info = core.firstCommandAfter(after: targetId - 1), info.id == targetId, !info.running {
                    let promptLine = existing.promptLine ?? marks.first(where: { $0.commandId == targetId })?.promptLine
                    let status: UInt8 = (info.exitCode == 0 ? 1 : 2)
                    let out = core.commandOutput(id: targetId, epoch: info.epoch, maxLines: 100_000, maxBytes: 10_000_000)
                    let lines = UInt64(out?.lines ?? 0)
                    let isNoOutput = (lines == 0)
                    let startLine = computeStartOutputAbsLine(
                        promptLine: promptLine,
                        cmdText: existing.command,
                        firstRetainedLine: firstRetainedLine,
                        totalScrollback: totalScrollback
                    )
                    let lastLine: UInt64
                    if isNoOutput {
                        lastLine = promptLine ?? 0
                    } else {
                        lastLine = max(startLine, startLine + (lines > 0 ? lines - 1 : 0))
                    }
                    runningCmd = TrackedCommandOutput(
                        commandId: targetId,
                        command: existing.command,
                        promptLine: promptLine,
                        startOutputAbsLine: startLine,
                        startCursorCol: existing.startCursorCol,
                        lastOutputAbsLine: lastLine,
                        status: status,
                        exitCode: info.exitCode,
                        hasNoOutput: isNoOutput,
                        outputResolved: true
                    )
                    if activeRunningCommandId == targetId {
                        activeRunningCommandId = nil
                    }
                }
                trackedCommands[targetId] = runningCmd
                resolvedCmd = runningCmd
            } else if !existing.outputResolved {
                // Completed command whose output bounds have not been resolved yet
                let promptLine = existing.promptLine ?? marks.first(where: { $0.commandId == targetId })?.promptLine
                let epoch = core.stateEpoch()
                let out = core.commandOutput(id: targetId, epoch: epoch, maxLines: 100_000, maxBytes: 10_000_000)
                let lines = UInt64(out?.lines ?? 0)
                let isNoOutput = (lines == 0)
                let startLine = computeStartOutputAbsLine(
                    promptLine: promptLine,
                    cmdText: existing.command,
                    firstRetainedLine: firstRetainedLine,
                    totalScrollback: totalScrollback
                )
                let lastLine: UInt64
                if isNoOutput {
                    lastLine = promptLine ?? 0
                } else {
                    lastLine = max(startLine, startLine + (lines > 0 ? lines - 1 : 0))
                }
                var tracked = existing
                tracked.promptLine = promptLine
                tracked.startOutputAbsLine = startLine
                tracked.lastOutputAbsLine = lastLine
                tracked.hasNoOutput = isNoOutput
                tracked.outputResolved = true
                trackedCommands[targetId] = tracked
                resolvedCmd = tracked
            } else {
                var tracked = existing
                if tracked.startOutputAbsLine <= (tracked.promptLine ?? 0) {
                    let startLine = computeStartOutputAbsLine(
                        promptLine: tracked.promptLine,
                        cmdText: tracked.command,
                        firstRetainedLine: firstRetainedLine,
                        totalScrollback: totalScrollback
                    )
                    if !tracked.hasNoOutput {
                        let diff = startLine > tracked.startOutputAbsLine ? (startLine - tracked.startOutputAbsLine) : 0
                        tracked.lastOutputAbsLine += diff
                    }
                    tracked.startOutputAbsLine = startLine
                    trackedCommands[targetId] = tracked
                }
                resolvedCmd = tracked
            }
        } else {
            // Not in cache: query only this single candidate command
            if let info = core.firstCommandAfter(after: targetId - 1), info.id == targetId {
                if info.running && activeRunningCommandId == nil {
                    activeRunningCommandId = info.id
                }
                guard let rawInput = info.input?.trimmingCharacters(in: .whitespacesAndNewlines), !rawInput.isEmpty else {
                    return nil
                }
                let mark = marks.first(where: { $0.commandId == info.id })
                let promptLine = mark?.promptLine

                let startLine = computeStartOutputAbsLine(
                    promptLine: promptLine,
                    cmdText: rawInput,
                    firstRetainedLine: firstRetainedLine,
                    totalScrollback: totalScrollback
                )

                let status: UInt8
                let isNoOutput: Bool
                let lastLine: UInt64

                if info.running {
                    status = 0
                    isNoOutput = false
                    lastLine = max(currentBottom, startLine)
                } else {
                    status = (info.finished ? (info.exitCode == 0 ? 1 : 2) : 2)
                    let out = core.commandOutput(id: info.id, epoch: info.epoch, maxLines: 100_000, maxBytes: 10_000_000)
                    let lines = UInt64(out?.lines ?? 0)
                    isNoOutput = (lines == 0)
                    if isNoOutput {
                        lastLine = promptLine ?? 0
                    } else {
                        lastLine = max(startLine, startLine + (lines > 0 ? lines - 1 : 0))
                    }
                }

                let tracked = TrackedCommandOutput(
                    commandId: info.id,
                    command: rawInput,
                    promptLine: promptLine,
                    startOutputAbsLine: startLine,
                    startCursorCol: 0,
                    lastOutputAbsLine: lastLine,
                    status: status,
                    exitCode: info.exitCode,
                    hasNoOutput: isNoOutput,
                    outputResolved: !info.running
                )
                trackedCommands[info.id] = tracked
                resolvedCmd = tracked
            } else {
                resolvedCmd = nil
            }
        }

        guard let cmd = resolvedCmd, !cmd.hasNoOutput, !cmd.command.isEmpty else {
            return nil
        }

        // Check if prompt is visible on screen
        if let pLine = cmd.promptLine, pLine >= firstRetainedLine {
            let pRow = Int(pLine - firstRetainedLine)
            if pRow >= vpTop {
                // Prompt line is visible on screen or below vpTop
                return nil
            }
        }

        // Check if prompt or prompt continuation mark is at the top of the viewport
        let semPrompt = core.retainedSemanticPrompt(row: UInt64(vpTop))
        if semPrompt != 0 {
            return nil
        }

        // Zero-output completed command has no output on screen
        if cmd.status != 0 && cmd.lastOutputAbsLine <= (cmd.promptLine ?? 0) {
            return nil
        }

        // Check if vpTopAbsLine is within this command's output bounds (both lower and upper bounds)
        if vpTopAbsLine < cmd.startOutputAbsLine || vpTopAbsLine > cmd.lastOutputAbsLine {
            return nil
        }

        let promptRetainedRow: UInt64
        if let pLine = cmd.promptLine, pLine >= firstRetainedLine {
            promptRetainedRow = pLine - firstRetainedLine
        } else {
            promptRetainedRow = 0
        }

        return StickyCommandHeader(
            commandId: cmd.commandId,
            command: cmd.command,
            promptRetainedRow: promptRetainedRow,
            status: cmd.status,
            exitCode: cmd.exitCode
        )
    }

    /// Updates the pinned sticky command header layer based on current viewport offset and command marks.
    func updateStickyCommandHeader() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard stickyCommandHeaderEnabled, !core.modes().alternateScreen else {
            stickyHeaderLayer.isHidden = true
            activeStickyCommandHeader = nil
            return
        }

        guard let header = currentStickyCommandHeader() else {
            stickyHeaderLayer.isHidden = true
            activeStickyCommandHeader = nil
            return
        }

        activeStickyCommandHeader = header

        let layout = gridLayout
        let headerHeight = max(cellHeight, 22.0)
        let headerY = bounds.height - layout.top - headerHeight
        stickyHeaderLayer.frame = CGRect(x: 0, y: headerY, width: bounds.width, height: headerHeight)
        stickyHeaderLayer.isHidden = false
        stickyHeaderLayer.backgroundColor = stickyHeaderBackgroundColor(hovering: isHoveringStickyHeader)

        stickyHeaderSeparatorLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1.0)
        stickyHeaderSeparatorLayer.backgroundColor = stickyHeaderSeparatorColor()

        let indicatorSize: CGFloat = 7.0
        let indicatorX = max(layout.left, 6.0)
        let indicatorY = (headerHeight - indicatorSize) / 2.0
        stickyHeaderIndicatorLayer.frame = CGRect(x: indicatorX, y: indicatorY, width: indicatorSize, height: indicatorSize)

        let indicatorColor: CGColor
        switch header.status {
        case 1: indicatorColor = NSColor.systemGreen.cgColor
        case 2: indicatorColor = NSColor.systemRed.cgColor
        default: indicatorColor = NSColor.systemBlue.cgColor
        }
        stickyHeaderIndicatorLayer.backgroundColor = indicatorColor

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        stickyHeaderTextLayer.contentsScale = scale
        stickyHeaderHintLayer.contentsScale = scale

        let textX = indicatorX + indicatorSize + 8.0
        let hintWidth: CGFloat = 110.0
        let availableWidth = max(0, bounds.width - textX - hintWidth - 20.0)
        stickyHeaderTextLayer.frame = CGRect(x: textX, y: (headerHeight - 16.0) / 2.0, width: availableWidth, height: 16.0)

        let font = NSFont.monospacedSystemFont(ofSize: min(theme.fontSize, 12.0), weight: .semibold)
        stickyHeaderTextLayer.font = font
        stickyHeaderTextLayer.fontSize = font.pointSize
        stickyHeaderTextLayer.foregroundColor = stickyHeaderTextColor()
        stickyHeaderTextLayer.string = header.command

        let hintFont = NSFont.systemFont(ofSize: 10.0, weight: .regular)
        stickyHeaderHintLayer.font = hintFont
        stickyHeaderHintLayer.fontSize = hintFont.pointSize
        stickyHeaderHintLayer.foregroundColor = stickyHeaderHintColor(hovering: isHoveringStickyHeader)
        let hintX = max(textX + availableWidth, bounds.width - hintWidth - 16.0)
        stickyHeaderHintLayer.frame = CGRect(x: hintX, y: (headerHeight - 14.0) / 2.0, width: hintWidth, height: 14.0)
    }

    /// Handles hover state updates for the sticky command header.
    private func updateStickyHeaderHover(_ hovering: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        stickyHeaderLayer.backgroundColor = stickyHeaderBackgroundColor(hovering: hovering)
        stickyHeaderHintLayer.foregroundColor = stickyHeaderHintColor(hovering: hovering)
    }

    var isLightTheme: Bool {
        guard let bg = NSColor(cgColor: theme.background)?.usingColorSpace(.sRGB) else {
            return false
        }
        let luminance = 0.2126 * bg.redComponent + 0.7152 * bg.greenComponent + 0.0722 * bg.blueComponent
        return luminance > 0.5
    }

    func stickyHeaderBackgroundColor(hovering: Bool) -> CGColor {
        if isLightTheme {
            let base = NSColor(cgColor: theme.background) ?? NSColor.white
            let fraction: CGFloat = hovering ? 0.14 : 0.06
            let blended = base.blended(withFraction: fraction, of: .black)
                ?? (hovering ? NSColor(white: 0.86, alpha: 0.98) : NSColor(white: 0.94, alpha: 0.96))
            return blended.withAlphaComponent(hovering ? 0.98 : 0.95).cgColor
        } else {
            let base = NSColor(cgColor: theme.background) ?? NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)
            let fraction: CGFloat = hovering ? 0.16 : 0.08
            let blended = base.blended(withFraction: fraction, of: .white)
                ?? (hovering ? NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.20, alpha: 0.98) : NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 0.94))
            return blended.withAlphaComponent(hovering ? 0.98 : 0.94).cgColor
        }
    }

    func stickyHeaderTextColor() -> CGColor {
        theme.foreground
    }

    func stickyHeaderHintColor(hovering: Bool) -> CGColor {
        if isLightTheme {
            let fg = NSColor(cgColor: theme.foreground) ?? NSColor.black
            return fg.withAlphaComponent(hovering ? 0.85 : 0.55).cgColor
        } else {
            let fg = NSColor(cgColor: theme.foreground) ?? NSColor.white
            return fg.withAlphaComponent(hovering ? 0.85 : 0.5).cgColor
        }
    }

    func stickyHeaderSeparatorColor() -> CGColor {
        if isLightTheme {
            return NSColor.black.withAlphaComponent(0.12).cgColor
        } else {
            return NSColor.white.withAlphaComponent(0.15).cgColor
        }
    }

    /// Jumps the viewport so that the given retained prompt row is pinned at the top.
    public func jumpToPrompt(retainedRow: UInt64) {
        let totalScrollback = Int(core.scrollbackLen())
        let targetOffset = max(0, totalScrollback - Int(retainedRow))
        scrollToOffset(targetOffset)
        updateScroller()
    }

    /// Internal, not private: a host that moved the viewport in the engine
    /// directly (a search selecting a hit) calls it so the scrollbar follows.
    func notifyScrollPositionIfChanged() {
        updateScroller()
        
        let position = core.scrollPosition()
        guard abs(position - lastReportedScrollPosition) > 0.0001 else { return }
        lastReportedScrollPosition = position
        delegate?.terminalView(self, didScrollTo: position)
    }

    override public func layout() {
        super.layout()
        updateScroller()
    }

    /// Reset terminal state.
    public func reset() {
        trackedCommands.removeAll()
        trackedCommandsEpoch = core.stateEpoch()
        activeRunningCommandId = nil
        parserCoordinator.feedSynchronously(Data("\u{001B}c".utf8))
        scheduleRedraw()
    }

    /// Clear screen.
    public func clearScreen() {
        feed(data: Data("\u{1b}[2J\u{1b}[H".utf8))
        scheduleRedraw()
    }

    /// Everything the terminal holds as plain text.
    public var bufferText: String {
        core.bufferText()
    }

    /// Where the viewport sits, 0 (oldest retained line) to 1 (live screen).
    public var scrollPosition: Double {
        get { core.scrollPosition() }
        set {
            core.setScrollPosition(position: newValue)
            notifyScrollPositionIfChanged()
            scheduleRedraw()
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
        notifyScrollPositionIfChanged()
        scheduleRedraw()
    }

    /// Scroll viewport down by lines.
    public func scrollViewportDown(lines: Int = 1) {
        core.scrollViewportDown(lines: UInt32(max(lines, 1)))
        notifyScrollPositionIfChanged()
        scheduleRedraw()
    }

    /// Snap scroll to bottom (live screen).
    public func scrollViewportToBottom() {
        core.scrollViewportBottom()
        notifyScrollPositionIfChanged()
        scheduleRedraw()
    }

    /// Scroll to specific viewport offset.
    public func scrollToOffset(_ offset: Int) {
        core.scrollViewportBottom()
        if offset > 0 {
            core.scrollViewportUp(lines: UInt32(offset))
        }
        notifyScrollPositionIfChanged()
        scheduleRedraw()
    }

    /// Jump viewport to previous verified prompt marker, or fall back to scrolling up one page.
    @discardableResult
    @objc open func jumpToPreviousPrompt(_ sender: Any? = nil) -> Bool {
        if core.scrollToPreviousPrompt() {
            notifyScrollPositionIfChanged()
            scheduleRedraw()
            return true
        }
        scrollViewportUp(lines: max(1, Int(core.rows())))
        return false
    }

    /// Jump viewport to next verified prompt marker, or fall back to scrolling down one page.
    @discardableResult
    @objc open func jumpToNextPrompt(_ sender: Any? = nil) -> Bool {
        if core.scrollToNextPrompt() {
            notifyScrollPositionIfChanged()
            scheduleRedraw()
            return true
        }
        scrollViewportDown(lines: max(1, Int(core.rows())))
        return false
    }

    /// Select the exact output of the current or previous command cleanly bounded by prompt marks.
    @discardableResult
    @objc open func selectCommandOutput(_ sender: Any? = nil) -> Bool {
        if core.selectCommandOutput() {
            notifyScrollPositionIfChanged()
            scheduleRedraw()
            return true
        }
        return false
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

    public var cellWidth: CGFloat { renderer.metrics.cellWidth }
    public var cellHeight: CGFloat { renderer.metrics.cellHeight }

    /// Bottom-left of a cell in view coordinates.
    /// The lower-left corner of a cell, in view coordinates. The exact inverse
    /// of `cellAt`, so anything positioned by it lands on the cell a click
    /// there would report.
    public func cellOrigin(row: Int, col: Int) -> NSPoint {
        let layout = gridLayout
        return NSPoint(
            x: layout.left + CGFloat(col) * cellWidth,
            y: bounds.height - layout.top - CGFloat(row + 1) * cellHeight
        )
    }

    /// Where the grid on screen sits in this view: inside the configured
    /// padding, centred in the spare space with `window-padding-balance`.
    /// Every path that draws the grid or maps a point to a cell uses this one.
    public var gridLayout: TerminalGridLayout {
        TerminalGridLayout(
            viewSize: bounds.size,
            cellSize: CGSize(width: cellWidth, height: cellHeight),
            theme: theme,
            cols: cols,
            rows: rows
        )
    }

    /// The grid cell under a point in this view. Public so a host that adds
    /// its own pointer handling on top resolves cells the same way.
    public func cellAt(_ point: NSPoint) -> (row: Int, col: Int) {
        // Exactly where the renderer put the cell, because that is what the
        // eye is aiming at: row r at `top + r * cellHeight` from the top of
        // the view, column c at `left + c * cellWidth` from its left. Counting
        // rows up from the bottom instead, or leaving the padding out, is
        // half a row off and selects the line above the one clicked.
        gridLayout.cell(
            atTopLeftPoint: CGPoint(x: point.x, y: bounds.height - point.y),
            cols: cols,
            rows: rows
        )
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

    /// The renderer currently drawing this surface, so a test can prove the
    /// two share one clock rather than each keeping a private count.
    var metalRendererForTesting: MetalTerminalRenderer? { metalRenderer }

    // MARK: - Metal renderer lifecycle

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
        scheduleRedraw()
    }

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
        metal.isOpaque = theme.backgroundOpacity >= 1
        if let viewLayer = layer {
            viewLayer.insertSublayer(metal, at: 0)
        }

        metalRenderer = created
        metalLayer = metal
        applyMetalLayerGeometry()
        return nil
    }

    private func releaseMetalResources() {
        metalLayer?.removeFromSuperlayer()
        metalLayer = nil
        metalRenderer = nil
        lastFrameStatistics = nil
    }

    static func drawableSize(for size: CGSize, scale: CGFloat) -> CGSize {
        let scale = max(scale, 1)
        return CGSize(
            width: max((size.width * scale).rounded(.down), 1),
            height: max((size.height * scale).rounded(.down), 1)
        )
    }

    private var effectiveContentScale: CGFloat {
        max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, 1)
    }

    private func applyMetalLayerGeometry() {
        guard let metal = metalLayer else { return }
        let size = Self.drawableSize(for: bounds.size, scale: metalContentScale)
        guard metal.frame != bounds
                || metal.contentsScale != metalContentScale
                || metal.drawableSize != size else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metal.frame = bounds
        metal.contentsScale = metalContentScale
        metal.drawableSize = size
        CATransaction.commit()
        scheduleRedraw()
    }

    // MARK: - Redraw Scheduling & Display Link

    private func startDisplayLink() {
        guard displayLink == nil, window != nil else { return }
        if #available(macOS 14.0, *) {
            let proxy = DisplayLinkProxy()
            proxy.owner = self
            let link = self.displayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func cancelPresentationThrottle() {
        pendingPresentationThrottle?.cancel()
        pendingPresentationThrottle = nil
    }

    private func armPresentationThrottle(after delay: TimeInterval) {
        guard delay > 0, delay.isFinite, !isPresentationPaused, window != nil,
              pendingPresentationThrottle == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPresentationThrottle = nil
            self.drivePresentationIfNeeded()
        }
        // Publish the coalescing marker before handing the work to either
        // scheduler. AppKit/test schedulers may synchronously re-enter the
        // presentation path.
        pendingPresentationThrottle = work
        if let presentationThrottleSchedulerForTesting {
            presentationThrottleSchedulerForTesting(delay, work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// A capped surface parks its display link between permits instead of
    /// polling every display tick.
    private func drivePresentationIfNeeded() {
        guard !isDrivingPresentation else { return }
        isDrivingPresentation = true
        defer { isDrivingPresentation = false }
        guard !isPresentationPaused, redrawPending || presentationRetryPending else { return }
        if let delay = presentationRateLimiter.delayUntilPermit, delay > 0.000_000_001 {
            displayLink?.isPaused = true
            super.needsDisplay = false
            armPresentationThrottle(after: delay)
            return
        }
        if metalRenderer != nil, metalLayer != nil, let displayLink, window != nil {
            displayLink.isPaused = false
        } else {
            // A link can briefly outlive a Metal renderer during a fallback
            // rebuild. It must not consume CPU fallback damage.
            displayLink?.isPaused = true
            super.needsDisplay = true
        }
    }

    private func claimPresentationPermit() -> Bool {
        guard presentationRateLimiter.claimPermit() else {
            // A direct redrawNow() call is also a presentation request. Set
            // the debt before driving the retry so a denied permit cannot
            // observe an otherwise idle surface and drop the wakeup.
            redrawPending = true
            drivePresentationIfNeeded()
            return false
        }
        return true
    }

    // Deterministic scheduling seam for focused presentation tests.
    func setPresentationRateLimitClockForTesting(_ clock: @escaping () -> TimeInterval) {
        presentationRateLimiter.clock = clock
    }

    func setPresentationThrottleSchedulerForTesting(_ scheduler: @escaping (TimeInterval, DispatchWorkItem) -> Void) {
        presentationThrottleSchedulerForTesting = scheduler
    }

    var hasPresentationThrottleForTesting: Bool { pendingPresentationThrottle != nil }

    override public func setNeedsDisplay(_ invalidRect: NSRect) {
        redrawPending = true
        guard !isPresentationPaused else { return }
        super.setNeedsDisplay(invalidRect)
        drivePresentationIfNeeded()
    }

    override public var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue {
                redrawPending = true
                guard !isPresentationPaused else { return }
                super.needsDisplay = true
                drivePresentationIfNeeded()
            } else {
                super.needsDisplay = false
            }
        }
    }

    /// Ask for a frame. Public so a host driving its own PTY can mark the
    /// surface dirty without reaching into the renderer.
    public func scheduleRedraw() {
        redrawPending = true
        guard !isPresentationPaused else { return }
        drivePresentationIfNeeded()
    }

    private func armPresentationRetry() {
        presentationRetryPending = true
        guard !isPresentationPaused else { return }
        drivePresentationIfNeeded()
    }

    private func resumePresentationIfNeeded() {
        guard redrawPending || presentationRetryPending else { return }
        // A layer-backed surface has one owner for the resumed frame: the
        // display link. Asking AppKit to draw as well would make a pending
        // draw and a tick race to fetch the same state twice. The CPU path
        // has no display link, so it is invalidated through AppKit instead.
        drivePresentationIfNeeded()
    }

    func displayLinkFired() {
        guard !isPresentationPaused else {
            displayLink?.isPaused = true
            return
        }
        guard redrawPending || presentationRetryPending else {
            displayLink?.isPaused = true
            return
        }
        guard metalRenderer != nil, metalLayer != nil else {
            // If a renderer fell back after a link was made, route the owed
            // work through AppKit's CPU draw path rather than clearing it in
            // `redrawNow` without painting.
            displayLink?.isPaused = true
            super.needsDisplay = true
            return
        }
        redrawNow()
    }

    public func redrawNow() {
        guard !isPresentationPaused else { return }
        let wasRedrawPending = redrawPending
        guard !core.isSynchronizedOutputActive() else {
            redrawPending = false
            if wasRedrawPending || presentationRetryPending {
                redrawHeldBySynchronizedOutput = true
            }
            displayLink?.isPaused = true
            return
        }
        guard claimPresentationPermit() else { return }
        // An explicit draw/tick can arrive after the deadline but before its
        // queued one-shot. It paid the debt, so retire that obsolete wakeup.
        cancelPresentationThrottle()
        redrawPending = false
        guard let metalRenderer, let metalLayer else { return clearPresentationRetry() }
        guard bounds.width >= 1, bounds.height >= 1 else { return clearPresentationRetry() }

        metalRenderer.planner.isFocused = (window?.firstResponder === self)
        metalRenderer.planner.cursorBlinkPhaseOn = theme.cursorBlink ? blinkStateVisible : true
        // Order matters: the frame decides how many overscan rows exist, and
        // the translation is only valid if they came back.
        let frame = currentRenderFrame()
        let layout = gridLayout
        let scale = Float(metalLayer.contentsScale)
        metalRenderer.planner.margins = TerminalMetalMargins(
            left: Float(layout.left) * scale,
            top: Float(layout.top) * scale,
            right: Float(layout.right(in: bounds.size)) * scale,
            bottom: Float(layout.bottom(in: bounds.size)) * scale,
            fill: Self.marginFill(theme.windowPaddingColor)
        )
        let stats = metalRenderer.render(
            frame: frame,
            in: metalLayer,
            overscanRows: frameOverscanRows,
            verticalPixelOffset: presentedVerticalPixelOffset + Float(layout.top) * scale,
            horizontalPixelOffset: Float(layout.left) * scale
        )
        lastFrameStatistics = stats

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
        return theme.customShaderAnimation.keepsAnimating(isFocused: window?.firstResponder === self)
    }

    private func clearPresentationRetry() {
        unpresentedFrameCount = 0
        presentationRetryPending = false
    }

    private func currentRenderFrame() -> FfiRenderFrame {
        frameFetchCount += 1
        guard presentedSubCellRows != 0 else {
            // On a row boundary this is the frame it has always been, with no
            // extra rows fetched and no translation applied.
            frameOverscanRows = 0
            return core.renderFrame()
        }
        let overscan = core.renderFrameOverscan(rowsBelow: 1)
        frameOverscanRows = Int(overscan.overscanRows)
        // The epoch travels with the frame rather than being fetched after
        // it: read separately, an import landing in between would label these
        // cells with a generation they do not belong to.
        return FfiRenderFrame(
            snapshot: overscan.snapshot,
            packedCells: overscan.packedCells,
            epoch: overscan.epoch,
            graphemes: overscan.graphemes
        )
    }

    /// The current sub-row translation, in drawable pixels, negative upward.
    ///
    /// Taken from the planner's own pixel cell height rather than recomputed
    /// from points, so the translation and the row layout cannot disagree
    /// about what a row is on a scaled display.
    private var presentedVerticalPixelOffset: Float {
        guard presentedSubCellRows != 0, frameOverscanRows > 0,
              let metrics = metalRenderer?.planner.metrics else { return 0 }
        return Float(presentedSubCellRows) * metrics.pixelCellHeight
    }

    private final class DisplayLinkProxy: NSObject {
        weak var owner: TakoTerminalNSView?

        @objc func tick() {
            MainActor.assumeIsolated { owner?.displayLinkFired() }
        }
    }

    // MARK: - Theme colors

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

    override public var isFlipped: Bool { false }

    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        isLeavingWindow = newWindow == nil
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isLeavingWindow = false
        observeWindowKeyState()
        // Both directions matter: moving out of a window must release the
        // context, and moving into one must not claim it unless this surface
        // is actually the focused one there.
        updateInputContextActivation()
        if window == nil {
            displayLink?.isPaused = true
            cancelPresentationThrottle()
        } else {
            startDisplayLink()
            if metalRenderer != nil, effectiveContentScale != metalContentScale {
                rebuildMetalRenderer()
            } else {
                applyMetalLayerGeometry()
            }
            scheduleRedraw()
        }
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if metalRenderer != nil, effectiveContentScale != metalContentScale {
            rebuildMetalRenderer()
        } else {
            applyMetalLayerGeometry()
        }
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if metalRenderer != nil, effectiveContentScale != metalContentScale {
            rebuildMetalRenderer()
        } else {
            applyMetalLayerGeometry()
        }

        let fitted = TerminalGridLayout(
            viewSize: newSize,
            cellSize: CGSize(width: cellWidth, height: cellHeight),
            theme: theme
        )
        scheduleGridResize(cols: fitted.cols, rows: fitted.rows)
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
        updateScroller()
        delegate?.terminalView(self, didResizeCols: appliedCols, rows: appliedRows)
        scheduleRedraw()
    }

    public func flushPendingResizeForTesting() {
        pendingResizeWorkItem?.cancel()
        applyPendingGridResize()
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override public func draw(_ dirtyRect: NSRect) {
        guard !isPresentationPaused else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if metalLayer != nil, metalRenderer != nil {
            guard redrawPending || presentationRetryPending else { return }
            redrawNow()
            if let marked = markedText, !marked.isEmpty {
                // Not `core.snapshot()`: that takes the next frame's damage.
                let cursorRow = Int(core.cursorRow()), cursorCol = Int(core.cursorCol())
                let y = cellOrigin(row: cursorRow, col: cursorCol).y
                context.saveGState()
                context.translateBy(x: gridLayout.left, y: 0)
                renderer.drawMarkedText(
                    marked,
                    cursorCol: cursorCol,
                    cols: Int(core.cols()),
                    availableRows: max(0, Int(core.rows()) - cursorRow),
                    y: y,
                    in: context
                )
                context.restoreGState()
            }
            return
        }

        // CPU Fallback Path
        guard redrawPending || presentationRetryPending else { return }
        guard claimPresentationPermit() else { return }
        // An AppKit draw may satisfy debt before the queued one-shot runs.
        cancelPresentationThrottle()
        redrawPending = false
        clearPresentationRetry()
        let bg = theme.backgroundOpacity < 1
            ? theme.background.copy(alpha: CGFloat(theme.backgroundOpacity))!
            : theme.background
        context.setFillColor(bg)
        context.fill(bounds)

        context.saveGState()

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

        let layout = gridLayout
        renderer.drawWindow(
            in: context,
            windowSize: bounds.size,
            layout: layout,
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

        if let marked = markedText, !marked.isEmpty {
            // drawWindow left the context at the grid's bottom-left.
            let y = CGFloat(Int(snapshot.rows) - 1 - Int(snapshot.cursorRow)) * cellHeight
            renderer.drawMarkedText(
                marked,
                cursorCol: Int(snapshot.cursorCol),
                cols: Int(snapshot.cols),
                availableRows: max(0, Int(snapshot.rows) - Int(snapshot.cursorRow)),
                y: y,
                in: context
            )
        }

        if !snapshot.graphicsPlacements.isEmpty {
            renderer.drawImages(
                snapshot.graphicsPlacements,
                rows: Int(snapshot.rows),
                imageProvider: { [core] in core.graphicsImage(imageId: $0) },
                in: context
            )
        }
        context.restoreGState()
    }

    // MARK: - Cursor Blink

    private func startBlinkTimer() {
        updateBlinkTimer()
    }

    private func updateBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkStateVisible = true
        guard theme.cursorBlink, !isPresentationPaused else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.theme.cursorBlink, !self.isPresentationPaused else { return }
                guard !self.core.isSynchronizedOutputActive() else { return }
                self.blinkStateVisible.toggle()
                self.scheduleRedraw()
            }
        }
    }

    // MARK: - First Responder & Focus

    override public var acceptsFirstResponder: Bool { true }

    /// This surface's own text input context.
    ///
    /// Conforming to NSTextInputClient and inheriting a context from the
    /// window is enough for typing and for marked text, and it is not enough
    /// for Dictation. The recognizer binds to the context that is *active*,
    /// and an inherited one is never activated by this view, so a session is
    /// selected, logs its start, never reaches listening, and is dropped a few
    /// seconds later with nothing delivered.
    ///
    /// Created lazily rather than in init: NSTextInputContext(client:) wants a
    /// fully formed client, and nothing needs a context before the view is
    /// first asked for one.
    private var storedInputContext: NSTextInputContext?

    /// Set while this view is being pulled out of its window.
    ///
    /// AppKit asks a departing view for its input context before clearing the
    /// window reference, so `window != nil` is still true at that moment and
    /// answering builds a context for a surface on its way out. Nothing else
    /// distinguishes that query from an ordinary one.
    private var isLeavingWindow = false

    /// The context, built on first real need.
    private var ownInputContext: NSTextInputContext {
        if let storedInputContext { return storedInputContext }
        inputContextCreations += 1
        let context = NSTextInputContext(client: self)
        storedInputContext = context
        return context
    }

    /// How many times the context has actually been built.
    ///
    /// Counted because "teardown creates no context" cannot be checked by
    /// reading `inputContext`: that read is what would create it. A test
    /// asserting on the property would prove the opposite of its own claim.
    private var inputContextCreations = 0

    var inputContextCreationCountForTesting: Int { inputContextCreations }

    override public var inputContext: NSTextInputContext? {
        // Built only for a surface that could actually take input. AppKit
        // queries this property while a view is leaving its window too, and
        // answering there with a freshly built context creates a session object
        // for a surface on its way out -- which is what a consumer's
        // "no context created during teardown" check caught. A view with no
        // window, or a hidden one, gets whatever it already had, or nothing.
        guard window != nil, !isHiddenOrHasHiddenAncestor, !isLeavingWindow else {
            return storedInputContext
        }
        return ownInputContext
    }

    /// True when this surface should be the one holding an active context:
    /// first responder, in a key window, on screen.
    ///
    /// All three matter. Activating while another surface is focused is how
    /// two terminals end up fighting over one dictation session, and a hidden
    /// view holding an active context keeps the session alive somewhere the
    /// user cannot see it.
    private var shouldHoldInputContext: Bool {
        Self.shouldHoldInputContext(
            hasWindow: window != nil,
            isKeyWindow: window?.isKeyWindow ?? false,
            isFirstResponder: window?.firstResponder === self,
            isHidden: isHiddenOrHasHiddenAncestor
        )
    }

    /// The activation rule, as a function of the four things it depends on.
    ///
    /// Separated from the view so it can be pinned without a window server. A
    /// unit test bundle has no activated application, so no window in it ever
    /// becomes key, and a test that needs one either skips or lies. The rule
    /// is the part that must not drift; whether AppKit reports the states
    /// correctly is what the real acceptance run on a live machine is for.
    static func shouldHoldInputContext(
        hasWindow: Bool,
        isKeyWindow: Bool,
        isFirstResponder: Bool,
        isHidden: Bool
    ) -> Bool {
        guard hasWindow, !isHidden else { return false }
        return isKeyWindow && isFirstResponder
    }

    /// Brings the context's activation in line with the surface's state.
    ///
    /// Idempotent on purpose: AppKit calls the transitions below in orders
    /// that overlap, and deactivating a context that is already inactive, or
    /// activating one twice, must not disturb a session.
    private func updateInputContextActivation() {
        let shouldBeActive = shouldHoldInputContext
        guard shouldBeActive != inputContextIsActive else { return }
        inputContextIsActive = shouldBeActive
        if shouldBeActive {
            ownInputContext.activate()
        } else {
            storedInputContext?.deactivate()
        }
    }

    private var inputContextIsActive = false

    /// Whether this surface currently holds an active input context.
    ///
    /// Exposed for the lifecycle tests: activation is a property of AppKit's
    /// input system with no public read-back, so the alternative is asserting
    /// on nothing.
    var isInputContextActiveForTesting: Bool { inputContextIsActive }

    override public func becomeFirstResponder() -> Bool {
        // The rule cannot be evaluated here. AppKit installs this view as the
        // window's first responder only after this returns true, so
        // `window.firstResponder` is still the previous responder and the rule
        // would decline -- and a window that is already key sends no later
        // notification to retry on, so the context would simply never activate.
        // That is the shape of the reported failure: focused, context present,
        // recognizer stuck at stage 0.
        //
        // Recomputed after the transition instead. A hop that lands late is
        // harmless because the rule re-reads all four conditions at the moment
        // it runs, rather than trusting what was true when it was scheduled.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.updateInputContextActivation() }
        }
        scheduleRedraw()
        return true
    }

    override public func resignFirstResponder() -> Bool {
        // Marked text belongs to the session that is ending. Leaving it behind
        // would commit a half-composed word into the next one.
        if hasMarkedText() { unmarkText() }
        // Deactivated outright rather than recomputed. This view is losing
        // focus by definition, but `window.firstResponder` is still self while
        // this runs, so the rule would say to keep the context and the session
        // would outlive the focus that justified it.
        deactivateInputContext()
        scheduleRedraw()
        return true
    }

    /// Releases the context without consulting the rule, and without creating
    /// one that was never needed.
    private func deactivateInputContext() {
        guard inputContextIsActive else { return }
        inputContextIsActive = false
        // Never builds one: a context that does not exist is not active, so
        // reaching here means it was created and activated earlier.
        storedInputContext?.deactivate()
    }

    override public func viewDidHide() {
        super.viewDidHide()
        updateInputContextActivation()
    }

    override public func viewDidUnhide() {
        super.viewDidUnhide()
        updateInputContextActivation()
    }

    @objc private func windowKeyStateChanged(_ note: Notification) {
        guard (note.object as? NSWindow) === window else { return }
        updateInputContextActivation()
    }

    /// Follows the window this surface is currently in, and only that one.
    ///
    /// Re-subscribed on every move because the view outlives its window: an
    /// observer left pointing at the previous window reports key changes for a
    /// window this surface is no longer in.
    private func observeWindowKeyState() {
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            center.addObserver(
                self,
                selector: #selector(windowKeyStateChanged(_:)),
                name: name,
                object: window
            )
        }
    }

    // MARK: - Keyboard Input

    override public func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags
        if mods.contains(.command) {
            super.keyDown(with: event)
            return
        }

        // When this Option press is configured to act as Alt, the key is
        // encoded straight to ESC + base character: composing it through the
        // input context first is exactly what loses the Alt meaning (see
        // `optionAsAlt`'s doc comment).
        let optionActsAsAlt = mods.contains(.option) && optionAsAlt.appliesTo(event)
        if hidesMouseWhileTyping {
            Self.hideMouseUntilMoved()
        }
        let namedKey = NamedKey.byKeyCode[event.keyCode]

        var ffi = FfiKeyEvent(
            key: .character,
            text: "",
            physicalText: "",
            unshiftedText: "",
            shift: mods.contains(.shift),
            // An Option that composes has already made the character; only
            // an Option acting as Alt, or one held with a key that types
            // nothing (an arrow, a function key), is a modifier to report.
            // Space is named but types a space, so a composing Option on it
            // is no more a modifier than it is on a letter.
            alt: mods.contains(.option)
                && (optionActsAsAlt || (namedKey != nil && namedKey != .space)),
            ctrl: mods.contains(.control),
            superKey: false,
            press: true,
            repeat: event.isARepeat,
            composing: false
        )

        if let named = namedKey {
            ffi.key = named
            if named == .space {
                ffi.text = " "
                ffi.unshiftedText = " "
            }
        } else if optionActsAsAlt {
            guard let chars = event.characters(byApplyingModifiers: mods.subtracting(.option)),
                  !chars.isEmpty else { return }
            ffi.text = chars
            ffi.unshiftedText = event.charactersIgnoringModifiers ?? chars
            ffi.physicalText = PhysicalKey.character(for: event.keyCode)
        } else {
            guard let chars = event.characters, !chars.isEmpty else { return }
            ffi.text = chars
            ffi.unshiftedText = event.charactersIgnoringModifiers ?? chars
            ffi.physicalText = PhysicalKey.character(for: event.keyCode)
        }

        if !optionActsAsAlt {
            keyTextAccumulator = ""
            let handled = inputContext?.handleEvent(event) == true
            var committed = keyTextAccumulator ?? ""
            keyTextAccumulator = nil
            if namedKey == .space {
                committed = SpaceBar.text(forCommitted: committed)
            }

            if !committed.isEmpty {
                insertText(committed, replacementRange: NSRange(location: NSNotFound, length: 0))
                return
            }

            if handled, markedText != nil {
                scheduleRedraw()
                return
            }
        }

        revealLiveScreenForUserInput()
        let bytes = core.encodeKey(event: ffi)
        if !bytes.isEmpty {
            delegate?.terminalView(self, sendInputData: bytes)
        }
        core.clearSelection()
        blinkStateVisible = true
        scheduleRedraw()
    }

    func revealLiveScreenForUserInput() {
        guard viewportOffset > 0 else { return }
        scrollViewportToBottom()
    }

    // MARK: - Mouse & Selection

    /// Mouse-report bytes when there is no `NSEvent` behind the action.
    ///
    /// Upstream's binding layer delivers synthesized pointer actions with
    /// coordinates but no event, so modifier state is reported as clear
    /// rather than invented.
    public func mouseReportBytes(
        button: FfiMouseButton,
        action: FfiMouseAction,
        cell: (row: Int, col: Int)
    ) -> Data {
        core.encodeMouse(event: FfiMouseEvent(
            button: button,
            action: action,
            shift: false,
            alt: false,
            ctrl: false,
            col: UInt32(max(cell.col, 0)),
            row: UInt32(max(cell.row, 0))
        ))
    }

    /// Mouse-report bytes for a real event.
    public func mouseReportBytes(
        button: FfiMouseButton,
        action: FfiMouseAction,
        cell: (row: Int, col: Int),
        event: NSEvent
    ) -> Data {
        core.encodeMouse(event: FfiMouseEvent(
            button: button,
            action: action,
            shift: event.modifierFlags.contains(.shift),
            alt: event.modifierFlags.contains(.option),
            ctrl: event.modifierFlags.contains(.control),
            col: UInt32(cell.col),
            row: UInt32(cell.row)
        ))
    }

    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let loc = convert(event.locationInWindow, from: nil)
        if scrollbarLayer.frame.contains(loc) {
            let maxScroll = scrollbackLength
            let modes = core.modes()
            if modes.alternateScreen && modes.alternateScroll {
                isDraggingScrollbar = true
                scrollbarDragStartMouseY = loc.y
                let key = FfiKeyEvent(
                    key: loc.y > bounds.height / 2 ? .pageUp : .pageDown, text: "", physicalText: "", unshiftedText: "",
                    shift: false, alt: false, ctrl: false, superKey: false,
                    press: true, repeat: false, composing: false)
                let singleKey = core.encodeKey(event: key)
                if !singleKey.isEmpty {
                    delegate?.terminalView(self, sendInputData: singleKey)
                }
                return
            }
            if maxScroll > 0 {
                isDraggingScrollbar = true
                let locInLayer = CGPoint(x: loc.x - scrollbarLayer.frame.origin.x, y: loc.y - scrollbarLayer.frame.origin.y)
                
                if scrollbarKnob.frame.contains(locInLayer) {
                    scrollbarDragStartKnobY = scrollbarKnob.frame.origin.y
                    scrollbarDragStartMouseY = loc.y
                } else {
                    let usableHeight = scrollbarLayer.bounds.height
                    let knobHeight = scrollbarKnob.frame.height
                    let maxKnobTravel = max(0, usableHeight - knobHeight)
                    let targetKnobY = max(0, min(locInLayer.y - knobHeight / 2.0, maxKnobTravel))
                    let newPos = maxKnobTravel > 0 ? Double(1.0 - targetKnobY / maxKnobTravel) : 1.0
                    core.setScrollPosition(position: newPos)
                    lastReportedScrollPosition = newPos
                    updateScroller()
                    scheduleRedraw()
                    
                    scrollbarDragStartKnobY = targetKnobY
                    scrollbarDragStartMouseY = loc.y
                }
                
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                scrollbarKnob.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
                CATransaction.commit()
            }
            return
        }
        isDraggingScrollbar = false
        if stickyCommandHeaderEnabled && !stickyHeaderLayer.isHidden && stickyHeaderLayer.frame.contains(loc) {
            if let header = activeStickyCommandHeader ?? currentStickyCommandHeader() {
                jumpToPrompt(retainedRow: header.promptRetainedRow)
                return
            }
        }
        let cell = cellAt(convert(event.locationInWindow, from: nil))
        if event.modifierFlags.contains(.command), let link = linkRange(at: cell) {
            Self.openURL(link.url)
            return
        }
        nativeSelectionCurrentPress = event.modifierFlags.contains(.shift)
            && !mouseShiftCapture.capturesShift(programRequest: core.mouseShiftCapture())
        let report = nativeSelectionCurrentPress
            ? Data()
            : mouseReportBytes(button: .left, action: .press, cell: cell, event: event)
        reportingCurrentPress = !nativeSelectionCurrentPress && !report.isEmpty
        guard report.isEmpty else {
            delegate?.terminalView(self, sendInputData: report)
            return
        }

        selectionAnchor = cell
        switch (event.clickCount - 1) % 3 {
        case 1:
            core.selectWord(row: UInt32(cell.row), col: UInt32(cell.col))
            expandedSelectionPress = true
            selectionAnchor = nil
        case 2:
            core.selectLine(row: UInt32(cell.row), col: UInt32(cell.col))
            expandedSelectionPress = true
            selectionAnchor = nil
        default:
            expandedSelectionPress = false
            core.startSelection(
                row: UInt32(cell.row),
                col: UInt32(cell.col),
                mode: !nativeSelectionCurrentPress && event.modifierFlags.contains(.option) ? .rectangular : .linear
            )
        }
        scheduleRedraw()
    }

    override public func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if isDraggingScrollbar {
            let maxScroll = scrollbackLength
            let modes = core.modes()
            if modes.alternateScreen && modes.alternateScroll {
                // In alternate screen / session multiplexer (zmx), synthesize arrow keys
                let dy = loc.y - scrollbarDragStartMouseY
                let pointsPerStep: CGFloat = 8.0
                if abs(dy) >= pointsPerStep {
                    let steps = Int(dy / pointsPerStep)
                    scrollbarDragStartMouseY += CGFloat(steps) * pointsPerStep
                    let key = FfiKeyEvent(
                        key: steps > 0 ? .up : .down, text: "", physicalText: "", unshiftedText: "",
                        shift: false, alt: false, ctrl: false, superKey: false,
                        press: true, repeat: false, composing: false)
                    let singleKey = core.encodeKey(event: key)
                    if !singleKey.isEmpty {
                        var keys = Data()
                        for _ in 0..<abs(steps) { keys.append(singleKey) }
                        delegate?.terminalView(self, sendInputData: keys)
                    }
                }
                return
            }
            
            let usableHeight = scrollbarLayer.bounds.height
            let visibleLines = Double(core.rows())
            let totalLines = Double(maxScroll) + visibleLines
            let proportion = max(0.05, min(1.0, visibleLines / totalLines))
            let knobHeight = max(usableHeight * CGFloat(proportion), 24.0)
            let maxKnobTravel = max(0, usableHeight - knobHeight)
            guard maxKnobTravel > 0 else { return }
            
            let dy = loc.y - scrollbarDragStartMouseY
            var newKnobY = scrollbarDragStartKnobY + dy
            newKnobY = max(0, min(newKnobY, maxKnobTravel))
            
            let fraction = newKnobY / maxKnobTravel
            let newPos = 1.0 - Double(fraction)
            
            core.setScrollPosition(position: newPos)
            lastReportedScrollPosition = newPos
            updateScroller()
            scheduleRedraw()
            return
        }
        let cell = cellAt(loc)
        guard !reportingCurrentPress else {
            let report = mouseReportBytes(button: .left, action: .motion, cell: cell, event: event)
            if !report.isEmpty { delegate?.terminalView(self, sendInputData: report) }
            return
        }

        guard !expandedSelectionPress else { return }
        core.extendSelection(row: UInt32(cell.row), col: UInt32(cell.col))
        scheduleRedraw()
    }

    override public func mouseUp(with event: NSEvent) {
        if isDraggingScrollbar {
            isDraggingScrollbar = false
            updateScroller()
            return
        }
        let cell = cellAt(convert(event.locationInWindow, from: nil))
        guard !reportingCurrentPress else {
            let report = mouseReportBytes(button: .left, action: .release, cell: cell, event: event)
            if !report.isEmpty { delegate?.terminalView(self, sendInputData: report) }
            reportingCurrentPress = false
            return
        }

        if let anchor = selectionAnchor, cell == anchor {
            core.clearSelection()
            _ = moveCursorForClick(cell: cell, event: event)
            scheduleRedraw()
        } else if core.hasSelection() {
            selectionDidFinish()
        }
        nativeSelectionCurrentPress = false
    }

    /// `cursor-click-to-move`: a plain click (no drag) on the cursor's own
    /// prompt line -- or, with Option held, anywhere on that prompt's line
    /// -- sends the arrow-key sequences that walk the cursor from its
    /// current column to the clicked one. Only meaningful while the shell
    /// is sitting at a prompt (OSC 133) with no mouse-reporting program in
    /// the way, the latter already guaranteed by the caller.
    private func moveCursorForClick(cell: (row: Int, col: Int), event: NSEvent) -> Bool {
        guard cursorClickToMove, !nativeSelectionCurrentPress, core.cursorIsAtPrompt() else { return false }
        let cursorRow = Int(core.cursorRow())
        let onPromptLine = core.rowSemanticPrompt(row: UInt32(cell.row)) != 0
        guard cell.row == cursorRow || (event.modifierFlags.contains(.option) && onPromptLine) else {
            return false
        }
        let delta = cell.col - Int(core.cursorCol())
        guard delta != 0 else { return false }
        let key: FfiKey = delta > 0 ? .right : .left
        var bytes = Data()
        for _ in 0..<abs(delta) {
            bytes.append(core.encodeKey(event: FfiKeyEvent(
                key: key, text: "", physicalText: "", unshiftedText: "",
                shift: false, alt: false, ctrl: false, superKey: false,
                press: true, repeat: false, composing: false
            )))
        }
        guard !bytes.isEmpty else { return false }
        delegate?.terminalView(self, sendInputData: bytes)
        return true
    }

    /// `link-url` and OSC 8: the link under `cell`, if any. An OSC 8
    /// hyperlink cell wins regardless of `linkURLDetectionEnabled` --
    /// that flag only gates the plain-text regex scan.
    func linkRange(at cell: (row: Int, col: Int)) -> (url: URL, row: Int, colStart: Int, colEnd: Int)? {
        if let hyperlink = core.getCell(row: UInt32(cell.row), col: UInt32(cell.col))?.hyperlinkUri,
           let url = URL(string: hyperlink) {
            var start = cell.col
            var end = cell.col
            while start > 0,
                  core.getCell(row: UInt32(cell.row), col: UInt32(start - 1))?.hyperlinkUri == hyperlink {
                start -= 1
            }
            let cols = Int(core.cols())
            while end + 1 < cols,
                  core.getCell(row: UInt32(cell.row), col: UInt32(end + 1))?.hyperlinkUri == hyperlink {
                end += 1
            }
            return (url, cell.row, start, end)
        }

        guard linkURLDetectionEnabled else { return nil }
        let (line, columns) = Self.rowText(core.viewportRow(row: UInt32(cell.row)))
        let text = line as NSString
        let matches = Self.urlPattern.matches(in: line, range: NSRange(location: 0, length: text.length))
        for match in matches {
            let first = match.range.location
            let last = match.range.location + match.range.length - 1
            guard columns[first] <= cell.col, cell.col <= columns[last] else {
                continue
            }
            var matched = text.substring(with: match.range)
            // Trailing punctuation is usually prose, not part of the URL.
            while let last = matched.last, ".,;:!?)]}>'\"".contains(last) {
                matched.removeLast()
            }
            guard !matched.isEmpty, let url = URL(string: matched) else { return nil }
            return (url, cell.row, columns[first], columns[first + (matched as NSString).length - 1])
        }
        return nil
    }

    /// A row's text, each cell's whole cluster, and the column every UTF-16
    /// unit of it came from: a cluster or a wide glyph is not one unit per
    /// column.
    static func rowText(_ cells: [FfiCell]) -> (text: String, columns: [Int]) {
        var text = ""
        var columns: [Int] = []
        for (col, cell) in cells.enumerated() where cell.ch != 0 {
            let piece = cell.grapheme ?? TerminalRenderer.string(for: cell.ch)
            text += piece
            columns.append(contentsOf: repeatElement(col, count: piece.utf16.count))
        }
        return (text, columns)
    }

    /// Recomputes `hoveredLink` from `mouseCell` and whether Command is
    /// currently held, and moves the underline bar and pointer cursor to
    /// match. Called from `mouseMoved` and `flagsChanged`: either one can
    /// change what should be underlined.
    private func updateHoveredLink(commandHeld: Bool) {
        let link = commandHeld ? mouseCell.flatMap(linkRange(at:)) : nil
        guard link?.url != hoveredLink?.url || link?.colStart != hoveredLink?.colStart
                || link?.row != hoveredLink?.row else { return }
        hoveredLink = link
        guard let link else {
            linkUnderlineLayer.isHidden = true
            NSCursor.arrow.set()
            return
        }
        let origin = cellOrigin(row: link.row, col: link.colStart)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        linkUnderlineLayer.frame = NSRect(
            x: origin.x, y: origin.y,
            width: cellWidth * CGFloat(link.colEnd - link.colStart + 1),
            height: max((cellHeight * 0.08).rounded(.up), 1)
        )
        linkUnderlineLayer.isHidden = false
        CATransaction.commit()
        NSCursor.pointingHand.set()
    }

    override public func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let loc = convert(event.locationInWindow, from: nil)
        let isStickyClick = stickyCommandHeaderEnabled && !stickyHeaderLayer.isHidden && stickyHeaderLayer.frame.contains(loc)
        if !isStickyClick {
            let cell = cellAt(loc)
            let report = mouseReportBytes(button: .right, action: .press, cell: cell, event: event)
            if !report.isEmpty {
                delegate?.terminalView(self, sendInputData: report)
                return
            }
        }
        if let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override public func rightMouseUp(with event: NSEvent) {
        let cell = cellAt(convert(event.locationInWindow, from: nil))
        let report = mouseReportBytes(button: .right, action: .release, cell: cell, event: event)
        if !report.isEmpty {
            delegate?.terminalView(self, sendInputData: report)
        } else {
            super.rightMouseUp(with: event)
        }
    }

    override public func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let cell = cellAt(convert(event.locationInWindow, from: nil))
        let report = mouseReportBytes(button: .middle, action: .press, cell: cell, event: event)
        if !report.isEmpty {
            delegate?.terminalView(self, sendInputData: report)
        } else {
            super.otherMouseDown(with: event)
        }
    }

    override public func otherMouseUp(with event: NSEvent) {
        let cell = cellAt(convert(event.locationInWindow, from: nil))
        let report = mouseReportBytes(button: .middle, action: .release, cell: cell, event: event)
        if !report.isEmpty {
            delegate?.terminalView(self, sendInputData: report)
        } else {
            super.otherMouseUp(with: event)
        }
    }

    override public func flagsChanged(with event: NSEvent) {
        updateHoveredLink(commandHeld: event.modifierFlags.contains(.command))
        super.flagsChanged(with: event)
    }

    override public func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if scrollbarLayer.frame.contains(point) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scrollbarKnob.backgroundColor = NSColor.white.withAlphaComponent(0.65).cgColor
            CATransaction.commit()
        } else if !isDraggingScrollbar {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scrollbarKnob.backgroundColor = scrollbackLength == 0
                ? NSColor.white.withAlphaComponent(0.15).cgColor
                : NSColor.white.withAlphaComponent(0.45).cgColor
            CATransaction.commit()
        }
        if stickyCommandHeaderEnabled && !stickyHeaderLayer.isHidden && stickyHeaderLayer.frame.contains(point) {
            if !isHoveringStickyHeader {
                isHoveringStickyHeader = true
                updateStickyHeaderHover(true)
            }
            NSCursor.pointingHand.set()
            return
        } else if isHoveringStickyHeader {
            isHoveringStickyHeader = false
            updateStickyHeaderHover(false)
            NSCursor.arrow.set()
        }
        mouseCell = cellAt(point)
        updateHoveredLink(commandHeld: event.modifierFlags.contains(.command))
        if let cell = mouseCell {
            let report = mouseReportBytes(button: .none, action: .motion, cell: cell, event: event)
            if !report.isEmpty {
                delegate?.terminalView(self, sendInputData: report)
                return
            }
        }
        super.mouseMoved(with: event)
    }

    override public func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
    }

    override public func mouseExited(with event: NSEvent) {
        if isHoveringStickyHeader {
            isHoveringStickyHeader = false
            updateStickyHeaderHover(false)
        }
        mouseCell = nil
        updateHoveredLink(commandHeld: false)
        super.mouseExited(with: event)
    }

    /// Sub-row scroll motion, presented as a translation rather than dropped.
    ///
    /// A trackpad reports points, many of them, most smaller than a row. The
    /// original code rounded each event on its own and threw the remainder
    /// away, so slow motion produced either nothing or a whole row and never
    /// the truth in between. Carrying the remainder fixed the accounting; this
    /// is what makes it visible.
    ///
    /// Always in `(-1, 0]`: whole rows are rounded away from the tail, so the
    /// grid sits one row further back than the eye should see and is
    /// translated *up* into place. The strip that opens is therefore always
    /// the bottom one, in both directions and across a reversal, and it is
    /// filled by the overscan row the core packs below the viewport. The top
    /// edge cannot be exposed at all.
    private var subCellScroll = SubCellScrollAccumulator()

    /// Kept separate from the local one, and kept at all: a program owning the
    /// wheel still has to be told about small precise movement, and rounding
    /// each event on its own would drop everything under one step.
    private var wheelReports = WheelReportAccumulator()

    /// Sub-row motion currently being presented as a translation.
    private var presentedSubCellRows: CGFloat { subCellScroll.presentedRows }

    /// Where the viewport actually sits on screen, in rows back from the tail.
    ///
    /// `viewportOffset` is where the engine is, which during a precise gesture
    /// is deliberately one row further back than the eye should see; the
    /// difference is made up by the translation. This is the sum, and so the
    /// only number that describes what is being looked at. Integral whenever
    /// nothing is being translated.
    public var presentedScrollRows: CGFloat {
        CGFloat(viewportOffset) + subCellScroll.presentedRows
    }

    /// Motion a reporting program has been sent that has not yet made a whole
    /// wheel step. Exposed so a test can prove it is carried and not dropped.
    var pendingWheelReportSteps: CGFloat { wheelReports.residualSteps }

    /// Rows the current frame carries below the viewport, from the core.
    /// Zero whenever the grid is presented on an exact row boundary.
    private var frameOverscanRows: Int = 0

    /// Points of precise scrolling that make one row.
    ///
    /// Kept at the value this surface has always used rather than derived from
    /// the cell height: changing the speed is a separate decision from fixing
    /// the quantisation, and mixing the two would make the change impossible
    /// to judge.
    private static let pointsPerScrolledLine: CGFloat = 3

    override public func scrollWheel(with event: NSEvent) {
        // A new gesture does not inherit the tail of the last one.
        if event.phase.contains(.began) {
            subCellScroll.begin()
            wheelReports.begin()
        }

        let cell = cellAt(convert(event.locationInWindow, from: nil))

        // Whether the wheel belongs to the program does not depend on which
        // way it turned, so this settles the mode before any accounting. In a
        // reporting mode the wheel is integral by protocol: the program is
        // told about whole wheel steps and there is nothing to translate.
        let reportsToProgram = !mouseReportBytes(
            button: .wheelUp,
            action: .press,
            cell: cell,
            event: event
        ).isEmpty

        if reportsToProgram {
            subCellScroll.clear()
            // Accumulated, not rounded per event: a trackpad delivers many
            // events smaller than a step, and rounding each on its own reports
            // nothing at all for slow movement.
            let lines = event.hasPreciseScrollingDeltas
                ? wheelReports.accumulatePrecise(
                    deltaY: event.scrollingDeltaY,
                    pointsPerStep: Self.pointsPerScrolledLine,
                    maximumSteps: TerminalTouchScrollDecision.maxLinesPerGestureCallback)
                : wheelReports.accumulateNotched(
                    deltaY: event.scrollingDeltaY,
                    maximumSteps: TerminalTouchScrollDecision.maxLinesPerGestureCallback)
            guard lines != 0 else { return }
            let singleReport = mouseReportBytes(
                button: lines > 0 ? .wheelUp : .wheelDown,
                action: .press,
                cell: cell,
                event: event
            )
            guard !singleReport.isEmpty else { return }
            var reports = Data()
            for _ in 0..<abs(lines) { reports.append(singleReport) }
            delegate?.terminalView(self, sendInputData: reports)
            return
        }

        // Mouse reporting is the only general override. Without it, DEC 1007
        // owns the wheel only on the alternate screen; primary-screen wheel
        // motion remains local scrollback presentation.
        let modes = core.modes()
        if modes.alternateScreen && modes.alternateScroll {
            subCellScroll.clear()
            let lines = event.hasPreciseScrollingDeltas
                ? wheelReports.accumulatePrecise(
                    deltaY: event.scrollingDeltaY,
                    pointsPerStep: Self.pointsPerScrolledLine,
                    maximumSteps: TerminalTouchScrollDecision.maxLinesPerGestureCallback)
                : wheelReports.accumulateNotched(
                    deltaY: event.scrollingDeltaY,
                    maximumSteps: TerminalTouchScrollDecision.maxLinesPerGestureCallback)
            guard lines != 0 else { return }
            let key = FfiKeyEvent(
                key: lines > 0 ? .up : .down, text: "", physicalText: "", unshiftedText: "",
                shift: false, alt: false, ctrl: false, superKey: false,
                press: true, repeat: false, composing: false)
            let singleKey = core.encodeKey(event: key)
            guard !singleKey.isEmpty else { return }
            var keys = Data()
            for _ in 0..<abs(lines) { keys.append(singleKey) }
            delegate?.terminalView(self, sendInputData: keys)
            return
        }
        wheelReports.clear()

        let lines: Int
        if event.hasPreciseScrollingDeltas {
            // A trackpad or a Magic Mouse: points, accumulated, with the
            // fraction kept as a translation instead of discarded. Rounding
            // away from the tail leaves a remainder that is never positive,
            // which is what keeps the exposed strip at the bottom edge.
            lines = subCellScroll.accumulatePrecise(
                deltaY: event.scrollingDeltaY,
                pointsPerLine: Self.pointsPerScrolledLine
            )
        } else {
            // A notched wheel already reports lines. Dividing those by three
            // rounded every notch to zero, which is why a promotion of any
            // sub-threshold event to a full row had to exist at all -- and
            // that promotion is what turned small trackpad movement into
            // jumps. Reading each kind in its own units removes the need for
            // it. A notch is a whole row by definition, so nothing is left
            // over to translate.
            lines = subCellScroll.accumulateNotched(deltaY: event.scrollingDeltaY)
        }

        let before = viewportOffset
        if lines > 0 {
            scrollViewportUp(lines: lines)
        } else if lines < 0 {
            scrollViewportDown(lines: -lines)
        }

        // Either end of the scrollback clamps. Past a clamp the row a
        // translation would expose does not exist, so present the boundary
        // exactly rather than a fraction beyond it.
        subCellScroll.settleAtBoundary(
            requestedRows: lines,
            offsetBefore: before,
            offsetAfter: viewportOffset
        )

        guard lines != 0 || presentedSubCellRows != 0 else { return }
        notifyScrollPositionIfChanged()
        scheduleRedraw()
    }

    // MARK: - Copy & Paste

    @objc public func copy(_ sender: Any?) {
        guard let text = core.selectedText() else { return }
        copyStringConsumer(text)
    }

    @objc public func paste(_ sender: Any?) {
        guard let string = pasteStringProvider() else { return }
        revealLiveScreenForUserInput()
        let bytes = core.encodePaste(text: string)
        if !bytes.isEmpty {
            delegate?.terminalView(self, sendInputData: bytes)
        }
    }

    @objc override public func selectAll(_ sender: Any?) {
        core.startSelection(row: 0, col: 0, mode: .linear)
        core.extendSelection(row: UInt32(max(rows - 1, 0)), col: UInt32(max(cols - 1, 0)))
        scheduleRedraw()
    }

    // MARK: - Command Actions

    /// Returns all recorded commands currently kept in the engine's memory.
    public func recordedCommands() -> [FfiCommandInfo] {
        var commands: [FfiCommandInfo] = []
        var after: UInt64 = 0
        while let cmd = core.firstCommandAfter(after: after) {
            commands.append(cmd)
            after = cmd.id
        }
        return commands
    }

    /// Looks up command info for a specific command ID.
    public func commandInfo(for id: UInt64) -> FfiCommandInfo? {
        guard id > 0 else { return nil }
        if let info = core.firstCommandAfter(after: id - 1), info.id == id {
            return info
        }
        return nil
    }

    /// Resolves the full output string of a recorded command.
    public func commandOutputString(for commandId: UInt64) -> String {
        let epoch = core.stateEpoch()
        if let out = core.commandOutput(id: commandId, epoch: epoch, maxLines: 500_000, maxBytes: 50_000_000) {
            return out.output
        }
        return ""
    }

    /// Identifies the command ID associated with a view point or the current context.
    public func commandIdForContext(at point: NSPoint? = nil) -> UInt64? {
        if let point {
            if stickyCommandHeaderEnabled && !stickyHeaderLayer.isHidden && stickyHeaderLayer.frame.contains(point) {
                if let header = activeStickyCommandHeader ?? currentStickyCommandHeader() {
                    return header.commandId
                }
            }
            let cell = cellAt(point)
            let totalScrollback = Int(core.scrollbackLen())
            let offset = Int(core.viewportOffset())
            let vpTop = totalScrollback - offset
            let firstRetainedLine = core.firstRetainedLine()
            let cellAbsLine = firstRetainedLine + UInt64(max(0, vpTop + cell.row))

            let marks = core.commandMarks().sorted(by: { $0.promptLine < $1.promptLine })
            if let mark = marks.last(where: { $0.promptLine <= cellAbsLine }) {
                return mark.commandId
            } else if let firstMark = marks.first, cellAbsLine < firstMark.promptLine {
                if firstMark.commandId > 1 {
                    return firstMark.commandId - 1
                }
            }
        }

        return activeStickyCommandHeader?.commandId
            ?? activeRunningCommandId
            ?? findRunningCommandId()
            ?? core.newestCommandId()
    }

    /// Formats a command and its output as Markdown.
    public static func formatCommandAndOutputAsMarkdown(command: String, output: String) -> String {
        var md = "```bash\n\(command)\n```"
        let trimmedOutput = output.hasSuffix("\n") ? String(output.dropLast()) : output
        if !trimmedOutput.isEmpty {
            md += "\n\n```\n\(trimmedOutput)\n```"
        }
        return md
    }

    /// 1. Copy command to clipboard.
    public func copyCommand(id: UInt64) {
        guard let cmd = commandInfo(for: id), let input = cmd.input else { return }
        copyStringConsumer(input)
    }

    /// 2. Copy output to clipboard.
    public func copyOutput(id: UInt64) {
        let output = commandOutputString(for: id)
        copyStringConsumer(output)
    }

    /// 3. Copy both command and output as a Markdown block.
    public func copyBothAsMarkdown(id: UInt64) {
        guard let cmd = commandInfo(for: id), let input = cmd.input else { return }
        let output = commandOutputString(for: id)
        let md = Self.formatCommandAndOutputAsMarkdown(command: input, output: output)
        copyStringConsumer(md)
    }

    /// 4. Re-run command in this pane (inserted at the prompt, not executed).
    public func rerunCommand(id: UInt64) {
        guard let cmd = commandInfo(for: id), let input = cmd.input else { return }
        revealLiveScreenForUserInput()
        window?.makeFirstResponder(self)
        var text = input
        while text.hasSuffix("\n") || text.hasSuffix("\r") {
            text.removeLast()
        }
        guard !text.isEmpty else { return }
        let bytes = core.encodePaste(text: text)
        if !bytes.isEmpty {
            delegate?.terminalView(self, sendInputData: bytes)
        }
    }

    /// 5. Send output to another pane as text (inserted at the prompt, not executed).
    public func sendOutputToAnotherPane(id: UInt64) {
        let output = commandOutputString(for: id)
        var cleanText = output
        while cleanText.hasSuffix("\n") || cleanText.hasSuffix("\r") {
            cleanText.removeLast()
        }
        if let sendTextToAnotherPaneHandler {
            sendTextToAnotherPaneHandler(cleanText)
        } else {
            delegate?.terminalView(self, sendTextToAnotherPane: cleanText)
        }
    }

    /// 6. Save output to a file via save panel.
    public func saveOutputToFile(id: UInt64, completion: ((URL?) -> Void)? = nil) {
        let output = commandOutputString(for: id)
        let suggestedFilename = "command-\(id)-output.txt"
        Self.saveFilePanel(output, suggestedFilename, window) { url in
            completion?(url)
        }
    }

    /// Directly save output to a file URL.
    public func saveOutput(for id: UInt64, to url: URL) throws {
        let output = commandOutputString(for: id)
        try output.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 7. Open working directory in Finder.
    public func openWorkingDirectory(id: UInt64) {
        guard let cmd = commandInfo(for: id), let cwd = cmd.cwd ?? workingDirectory else { return }
        let url: URL
        if cwd.hasPrefix("file://") {
            url = URL(string: cwd) ?? URL(fileURLWithPath: cwd)
        } else {
            url = URL(fileURLWithPath: cwd)
        }
        Self.openURL(url)
    }

    // MARK: - Context Menu

    override open func menu(for event: NSEvent) -> NSMenu? {
        let loc = convert(event.locationInWindow, from: nil)
        if let targetId = commandIdForContext(at: loc),
           let cmd = commandInfo(for: targetId) {
            return contextMenu(for: cmd)
        }
        return defaultContextMenu()
    }

    public func contextMenu(for commandId: UInt64) -> NSMenu? {
        guard let cmd = commandInfo(for: commandId) else { return nil }
        return contextMenu(for: cmd)
    }

    public func contextMenu(for cmd: FfiCommandInfo) -> NSMenu {
        let menu = NSMenu(title: "Command")

        if core.hasSelection() {
            let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            copyItem.target = self
            menu.addItem(copyItem)
        }

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(pasteItem)

        menu.addItem(NSMenuItem.separator())

        // 1. Copy Command
        let copyCmdItem = NSMenuItem(title: "Copy Command", action: #selector(copyCommandContextAction(_:)), keyEquivalent: "")
        copyCmdItem.representedObject = cmd.id
        copyCmdItem.target = self
        menu.addItem(copyCmdItem)

        // 2. Copy Output
        let copyOutItem = NSMenuItem(title: "Copy Output", action: #selector(copyOutputContextAction(_:)), keyEquivalent: "")
        copyOutItem.representedObject = cmd.id
        copyOutItem.target = self
        menu.addItem(copyOutItem)

        // 3. Copy Both as Markdown
        let copyMdItem = NSMenuItem(title: "Copy Both as Markdown", action: #selector(copyBothAsMarkdownContextAction(_:)), keyEquivalent: "")
        copyMdItem.representedObject = cmd.id
        copyMdItem.target = self
        menu.addItem(copyMdItem)

        menu.addItem(NSMenuItem.separator())

        // 4. Re-run in This Pane
        let rerunItem = NSMenuItem(title: "Re-run in This Pane", action: #selector(rerunCommandContextAction(_:)), keyEquivalent: "")
        rerunItem.representedObject = cmd.id
        rerunItem.target = self
        menu.addItem(rerunItem)

        // 5. Send Output to Another Pane
        let sendItem = NSMenuItem(title: "Send Output to Another Pane", action: #selector(sendOutputToAnotherPaneContextAction(_:)), keyEquivalent: "")
        sendItem.representedObject = cmd.id
        sendItem.target = self
        menu.addItem(sendItem)

        // 6. Save Output to File…
        let saveItem = NSMenuItem(title: "Save Output to File…", action: #selector(saveOutputToFileContextAction(_:)), keyEquivalent: "")
        saveItem.representedObject = cmd.id
        saveItem.target = self
        menu.addItem(saveItem)

        menu.addItem(NSMenuItem.separator())

        // 7. Open Working Directory
        let openDirItem = NSMenuItem(title: "Open Working Directory", action: #selector(openWorkingDirectoryContextAction(_:)), keyEquivalent: "")
        openDirItem.representedObject = cmd.id
        openDirItem.target = self
        if cmd.cwd == nil && workingDirectory == nil {
            openDirItem.isEnabled = false
        }
        menu.addItem(openDirItem)

        menu.addItem(NSMenuItem.separator())

        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        selectAllItem.target = self
        menu.addItem(selectAllItem)

        return menu
    }

    public func defaultContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Terminal")
        if core.hasSelection() {
            let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            copyItem.target = self
            menu.addItem(copyItem)
        }
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(pasteItem)
        menu.addItem(NSMenuItem.separator())
        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        selectAllItem.target = self
        menu.addItem(selectAllItem)
        return menu
    }

    @objc private func copyCommandContextAction(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UInt64 ?? commandIdForContext() else { return }
        copyCommand(id: id)
    }

    @objc private func copyOutputContextAction(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UInt64 ?? commandIdForContext() else { return }
        copyOutput(id: id)
    }

    @objc private func copyBothAsMarkdownContextAction(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UInt64 ?? commandIdForContext() else { return }
        copyBothAsMarkdown(id: id)
    }

    @objc private func rerunCommandContextAction(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UInt64 ?? commandIdForContext() else { return }
        rerunCommand(id: id)
    }

    @objc private func sendOutputToAnotherPaneContextAction(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UInt64 ?? commandIdForContext() else { return }
        sendOutputToAnotherPane(id: id)
    }

    @objc private func saveOutputToFileContextAction(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UInt64 ?? commandIdForContext() else { return }
        saveOutputToFile(id: id)
    }

    @objc private func openWorkingDirectoryContextAction(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UInt64 ?? commandIdForContext() else { return }
        openWorkingDirectory(id: id)
    }

    // MARK: - Drag and Drop

    override public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.availableType(from: [.fileURL, .string]) != nil ? .copy : []
    }

    /// Shell-quotes a file path or string so it can be safely pasted or dropped
    /// into a POSIX shell command line without unintended expansion or word splitting.
    public static func shellQuote(_ string: String) -> String {
        guard !string.isEmpty else { return "''" }
        let isSafe = string.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || "_@%+=:,./-".contains(c))
        }
        if isSafe {
            return string
        }
        return "'" + string.replacingOccurrences(of: "'", with: #"'"'"'"#) + "'"
    }

    override public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            let text = urls.map { url -> String in
                Self.shellQuote(url.path)
            }.joined(separator: " ")
            revealLiveScreenForUserInput()
            let bytes = core.encodePaste(text: text)
            if !bytes.isEmpty { delegate?.terminalView(self, sendInputData: bytes) }
            return true
        }
        if let text = pasteboard.string(forType: .string) {
            revealLiveScreenForUserInput()
            let bytes = core.encodePaste(text: text)
            if !bytes.isEmpty { delegate?.terminalView(self, sendInputData: bytes) }
            return true
        }
        return false
    }

    // MARK: - Services Menu

    override public func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        let canSend = sendType == nil || (sendType == .string && core.hasSelection())
        let canReturn = returnType == nil || returnType == .string
        if canSend && canReturn { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    @objc public func writeSelection(
        to pboard: NSPasteboard,
        types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard let text = core.selectedText() else { return false }
        pboard.clearContents()
        return pboard.setString(text, forType: .string)
    }

    @objc public func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let text = pboard.string(forType: .string) else { return false }
        revealLiveScreenForUserInput()
        let bytes = core.encodePaste(text: text)
        if !bytes.isEmpty { delegate?.terminalView(self, sendInputData: bytes) }
        return true
    }

    // MARK: - NSTextInputClient & NSUserInterfaceValidations

    public func hasMarkedText() -> Bool {
        markedText != nil
    }

    public func markedRange() -> NSRange {
        guard let markedText, !markedText.isEmpty else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: (markedText as NSString).length)
    }

    /// The selection, or the insertion point when there is none.
    ///
    /// Never NSNotFound. Unlike `markedRange()`, where NSNotFound is the
    /// documented way to say "nothing is composing", this method must always
    /// name a valid insertion location: AppKit's input system asks for it
    /// before it will drive a session, and an invalid location stops Dictation
    /// dead -- the recognizer initializes, InputMethodKit asks for the
    /// selected range, and listening never starts. Ordinary typing never
    /// noticed, because it does not go through that query.
    ///
    /// A consumer proved this causally: changing only this return turned a red
    /// two-machine acoustic run green. The ported Tako surface in this same
    /// repository has always returned NSRange() here.
    public func selectedRange() -> NSRange {
        guard let text = core.selectedText() else { return NSRange(location: 0, length: 0) }
        return NSRange(location: 0, length: (text as NSString).length)
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = v.string.isEmpty ? nil : v.string
        case let v as String: markedText = v.isEmpty ? nil : v
        default: return
        }
        scheduleRedraw()
    }

    public func unmarkText() {
        guard markedText != nil else { return }
        markedText = nil
        scheduleRedraw()
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.length > 0, let text = core.selectedText() else { return nil }
        return NSAttributedString(string: text)
    }

    public func characterIndex(for point: NSPoint) -> Int {
        0
    }

    public static func inputMethodViewRect(
        cursorCol: Int,
        cursorRow: Int,
        cols: Int,
        rows: Int,
        cellSize: CGSize,
        viewHeight: CGFloat,
        range: NSRange,
        gridOrigin: CGPoint = .zero
    ) -> NSRect {
        let safeCols = max(cols, 0)
        let safeRows = max(rows, 0)
        let safeCursorCol = min(max(cursorCol, 0), max(safeCols - 1, 0))
        var gridRow = min(max(cursorRow, 0), max(safeRows - 1, 0))
        var x = CGFloat(safeCursorCol) * cellSize.width
        var width = cellSize.width

        if range.length == 0, width > 0 {
            width = 0
            let location = range.location == NSNotFound ? 0 : range.location
            if safeCols > 0, safeRows > 0 {
                let linearCol = safeCursorCol + max(location, 0)
                let logicalRow = gridRow + linearCol / safeCols
                if logicalRow >= safeRows {
                    gridRow = safeRows - 1
                    x = CGFloat(safeCols) * cellSize.width
                } else {
                    gridRow = logicalRow
                    x = CGFloat(linearCol % safeCols) * cellSize.width
                }
            } else {
                x = 0
            }
        }

        return NSRect(
            x: gridOrigin.x + x,
            y: viewHeight - gridOrigin.y - CGFloat(gridRow + 1) * cellSize.height,
            width: width,
            height: cellSize.height
        )
    }

    public static func shouldSuppressComposingControlInput(
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

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let viewRect = Self.inputMethodViewRect(
            cursorCol: Int(core.cursorCol()),
            cursorRow: Int(core.cursorRow()),
            cols: cols,
            rows: rows,
            cellSize: CGSize(width: cellWidth, height: cellHeight),
            viewHeight: bounds.height,
            range: range,
            gridOrigin: CGPoint(x: gridLayout.left, y: gridLayout.top)
        )
        let winRect = convert(viewRect, to: nil)
        guard let window else { return winRect }
        return window.convertToScreen(winRect)
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }

        unmarkText()

        if keyTextAccumulator != nil {
            keyTextAccumulator! += chars
            return
        }

        guard !chars.isEmpty else { return }
        revealLiveScreenForUserInput()
        let bytes: Data
        if chars == "\n" || chars == "\r" {
            bytes = core.encodeKey(event: FfiKeyEvent(
                key: .enter,
                text: "\r",
                physicalText: "",
                unshiftedText: "",
                shift: false, alt: false, ctrl: false, superKey: false,
                press: true, repeat: false, composing: false
            ))
        } else if chars.count == 1, let ch = chars.first {
            bytes = core.encodeKey(event: FfiKeyEvent(
                key: .character,
                text: String(ch),
                physicalText: String(ch),
                unshiftedText: String(ch),
                shift: false, alt: false, ctrl: false, superKey: false,
                press: true, repeat: false, composing: false
            ))
        } else {
            bytes = core.encodePaste(text: chars)
        }

        if !bytes.isEmpty {
            delegate?.terminalView(self, sendInputData: bytes)
        }
        scheduleRedraw()
    }

    override public func doCommand(by selector: Selector) {}

    public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return core.hasSelection()
        }
        if item.action == #selector(paste(_:)) {
            return pasteStringProvider() != nil
        }
        if item.action == #selector(selectAll(_:)) {
            return true
        }
        if item.action == #selector(jumpToPreviousPrompt(_:)) ||
           item.action == #selector(jumpToNextPrompt(_:)) ||
           item.action == #selector(selectCommandOutput(_:)) {
            return true
        }
        if item.action == #selector(copyCommandContextAction(_:)) ||
           item.action == #selector(copyOutputContextAction(_:)) ||
           item.action == #selector(copyBothAsMarkdownContextAction(_:)) ||
           item.action == #selector(rerunCommandContextAction(_:)) ||
           item.action == #selector(sendOutputToAnotherPaneContextAction(_:)) ||
           item.action == #selector(saveOutputToFileContextAction(_:)) {
            return true
        }
        if item.action == #selector(openWorkingDirectoryContextAction(_:)) {
            if let menuItem = item as? NSMenuItem,
               let cmdId = menuItem.representedObject as? UInt64,
               let cmd = commandInfo(for: cmdId) {
                return cmd.cwd != nil || workingDirectory != nil
            }
            return workingDirectory != nil
        }
        return false
    }
}

extension TakoTerminalNSView: NSTextInputClient {}

public typealias TakoTerminalView = TakoTerminalNSView
public typealias TakoTerminalViewDelegate = TakoTerminalNSViewDelegate

#endif
