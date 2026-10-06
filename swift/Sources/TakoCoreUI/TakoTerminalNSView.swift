/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import OSLog

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import CoreGraphics
import Metal
import QuartzCore
import simd

@MainActor
open class TakoTerminalNSView: NSView, NSUserInterfaceValidations {
    public weak var delegate: TakoTerminalNSViewDelegate?
    public let core: TakoCore
    let parserCoordinator: TerminalParserCoordinator

    let scrollbarLayer = CALayer()
    let scrollbarKnob = CALayer()
    let scrollbarMarksLayer = CALayer()
    let gutterMarksLayer = CALayer()
    public let triggerHighlightsLayer = CALayer()

    public var regexTriggers: [TerminalRegexTrigger] = [] {
        didSet {
            disabledTriggerIDs.removeAll()
            updateRegexTriggerHighlights()
        }
    }
    public internal(set) var disabledTriggerIDs: Set<UUID> = []
    public var onTriggerMatched: ((_ trigger: TerminalRegexTrigger, _ matchingText: String, _ row: Int) -> Void)?
    var notifiedTriggerMatches: [UUID: Set<UInt64>] = [:]

    let stickyHeaderLayer = CALayer()
    let stickyHeaderIndicatorLayer = CALayer()
    let stickyHeaderTextLayer = CATextLayer()
    let stickyHeaderHintLayer = CATextLayer()
    let stickyHeaderSeparatorLayer = CALayer()
    var isHoveringStickyHeader = false
    public internal(set) var activeStickyCommandHeader: StickyCommandHeader?

    public let paneProgressBarLayer = CALayer()
    public var paneProgressBarEnabled: Bool = true {
        didSet {
            guard paneProgressBarEnabled != oldValue else { return }
            if !paneProgressBarEnabled {
                paneProgressBarLayer.isHidden = true
            } else if activeProgressState != .none {
                updateProgressBar(state: activeProgressState, progress: activeProgressValue)
            }
        }
    }
    public internal(set) var activeProgressState: ProgressState = .none
    public internal(set) var activeProgressValue: Int? = nil

    public let contextTintLayer = CALayer()
    public let contextBreadcrumbsLayer = CALayer()
    public let contextBreadcrumbsTextLayer = CATextLayer()

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
        var startedAt: Date?
        var endedAt: Date?
        var duration: TimeInterval?
    }
    var trackedCommands: [UInt64: TrackedCommandOutput] = [:]
    var trackedCommandsEpoch: UInt64 = 0
    var trackedCommandsCountForTesting: Int { trackedCommands.count }
    var activeTrackedCommandsCountForTesting: Int { trackedCommands.values.filter { !$0.hasNoOutput }.count }
    var trackedCommandsForTesting: [UInt64: TrackedCommandOutput] { trackedCommands }
    var activeRunningCommandId: UInt64? = nil
    var commandDurations: [UInt64: TimeInterval] = [:]
    var gutterCommandMarksByRow: [Int: (commandId: UInt64, status: UInt8, exitCode: Int32?, duration: TimeInterval?, startedAt: Date?)] = [:]

    var isDraggingScrollbar = false
    var scrollbarDragStartKnobY: CGFloat = 0.0
    var scrollbarDragStartMouseY: CGFloat = 0.0
    var isUpdatingScroller = false

    public var commandMarksEnabled: Bool = true {
        didSet {
            guard commandMarksEnabled != oldValue else { return }
            updateGutterMarks()
            updateScroller()
        }
    }
    public var stickyCommandHeaderEnabled: Bool = true {
        didSet {
            guard stickyCommandHeaderEnabled != oldValue else { return }
            updateStickyCommandHeader()
        }
    }
    public var commandDurationsEnabled: Bool = true {
        didSet {
            guard commandDurationsEnabled != oldValue else { return }
            updateGutterMarks()
        }
    }
    public var commandTimestampsEnabled: Bool = false {
        didSet {
            guard commandTimestampsEnabled != oldValue else { return }
            updateGutterMarks()
        }
    }

    public var semanticPathDetectionEnabled: Bool = true
    public var onSemanticPathClick: ((SemanticPathPayload) -> Void)?
    public var configuredEditorCommand: String? = nil
    nonisolated(unsafe) public static var editorLauncher: ((_ editor: String, _ args: [String], _ cwd: String?) -> Bool)? = nil

    public internal(set) var isOutputFilterActive: Bool = false
    public internal(set) var outputFilterQuery: String = ""
    public internal(set) var outputFilterIsRegex: Bool = false
    public internal(set) var outputFilterMatchingLines: [FilteredOutputLine] = []
    public internal(set) var outputFilterScrollOffset: Int = 0

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
    public internal(set) var renderer: TerminalRenderer
    public internal(set) var cols: Int = 80
    public internal(set) var rows: Int = 24
    public var title: String = "" {
        didSet { titleDidChange() }
    }
    open func titleDidChange() {}
    open var workingDirectory: String?

    public internal(set) var metalRenderer: MetalTerminalRenderer?
    public internal(set) var metalLayer: CAMetalLayer?
    public internal(set) var metalUnavailableReason: String?
    public internal(set) var lastFrameStatistics: TerminalMetalFrameStatistics?
    public var customShaderErrors: [String] { metalRenderer?.customShaderErrors ?? [] }

    var metalContentScale: CGFloat = 1
    var rendererBuildCount: Int = 0
    var frameFetchCount: Int = 0
    var redrawPending: Bool = false
    var presentationRetryPending: Bool = false
    var unpresentedFrameCount: Int = 0
    var redrawHeldBySynchronizedOutput: Bool = false
    var commandMarksHeldBySynchronizedOutput: Bool = false

    public var isPresentationPaused: Bool = false {
        didSet {
            guard oldValue != isPresentationPaused else { return }
            if isPresentationPaused {
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
    var displayLink: CADisplayLink?
    let presentationRateLimiter = PresentationRateLimiter()
    var isDrivingPresentation = false
    var pendingPresentationThrottle: DispatchWorkItem?
    var presentationThrottleSchedulerForTesting: ((TimeInterval, DispatchWorkItem) -> Void)?

    public var maximumPresentationFramesPerSecond: Double? {
        get { presentationRateLimiter.maximumFramesPerSecond }
        set {
            presentationRateLimiter.maximumFramesPerSecond = newValue
            cancelPresentationThrottle()
            drivePresentationIfNeeded()
        }
    }

    var pendingResizeWorkItem: DispatchWorkItem?
    var pendingGridSize: (cols: Int, rows: Int)?
    static let resizeSettleDelay: TimeInterval = 0.05
    static var metalLibraryBundle: Bundle { ShaderBundle.resources }
    public static var isMetalDisabledForTesting = false
    public static var metalLibraryProviderForTesting: ((MTLDevice) -> MTLLibrary?)?

    var blinkTimer: Timer?
    var blinkStateVisible: Bool = true
    var isBlinkStateVisibleForTesting: Bool { blinkStateVisible }

    var pasteStringProvider: () -> String? = { NSPasteboard.general.string(forType: .string) }
    var copyStringConsumer: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    public var sendTextToAnotherPaneHandler: ((String) -> Void)?
    public var confirmPasteHandler: ((String, @escaping (Bool) -> Void) -> Void)?

    public var isAlternateScreen: Bool { core.modes().alternateScreen }
    public var isAlternateScroll: Bool { core.modes().alternateScroll }

    var selectionAnchor: (row: Int, col: Int)?
    var reportingCurrentPress: Bool = false
    var nativeSelectionCurrentPress: Bool = false
    var expandedSelectionPress: Bool = false
    public internal(set) var mouseCell: (row: Int, col: Int)?

    public func setMouseCell(_ cell: (row: Int, col: Int)?) {
        mouseCell = cell
    }

    func findRunningCommandId() -> UInt64? {
        guard let newestId = core.newestCommandId(), newestId > 0 else { return nil }
        if let info = core.firstCommandAfter(after: newestId - 1), info.id == newestId, info.running {
            return newestId
        }
        return nil
    }

    /// Whether the terminal surface is currently idle at a shell prompt (not running a command, and not in alternate screen).
    open var isAtShellPrompt: Bool {
        guard !core.modes().alternateScreen else { return false }
        if let runningId = findRunningCommandId(), runningId > 0 {
            return false
        }
        return true
    }

    public var markedText: String?
    var keyTextAccumulator: String?
    public var optionAsAlt: OptionAsAlt = .off
    public var mouseShiftCapture: MouseShiftCapture = .off
    public var cursorClickToMove: Bool = true
    public var linkURLDetectionEnabled: Bool = true

    public var onOutputFilterChanged: ((_ active: Bool, _ matchCount: Int, _ totalCount: Int) -> Void)?
    public internal(set) var currentHoveredLink: TerminalLink?
    public internal(set) var hoveredLinkTarget: String?
    var hoveredLink: TerminalLink?
    var hoveredSemanticPath: SemanticPathTarget?
    public internal(set) var hasPresentedMatchingPreview: Bool = false
    var lastMousePoint: NSPoint?

    lazy var linkUnderlineLayer: CALayer = {
        let layer = CALayer()
        layer.backgroundColor = NSColor.labelColor.cgColor
        layer.isHidden = true
        return layer
    }()
    lazy var linkHUDLayer: CALayer = {
        let layer = CALayer()
        layer.zPosition = 9600
        layer.masksToBounds = true
        layer.isHidden = true
        layer.cornerRadius = 4.0
        return layer
    }()
    lazy var linkHUDTextLayer: CATextLayer = {
        let layer = CATextLayer()
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer.fontSize = 11.0
        layer.foregroundColor = NSColor.white.cgColor
        layer.alignmentMode = .left
        layer.truncationMode = .end
        return layer
    }()

    public var hidesMouseWhileTyping = false
    nonisolated(unsafe) static var hideMouseUntilMoved: () -> Void = { NSCursor.setHiddenUntilMouseMoves(true) }

    open func selectionDidFinish() {}

    var storedInputContext: NSTextInputContext?
    var isLeavingWindow = false
    var inputContextCreations = 0
    var inputContextIsActive = false
    let presentationClock = TerminalPresentationClock()
    var subCellScroll = SubCellScrollAccumulator()
    var wheelReports = WheelReportAccumulator()
    var frameOverscanRows: Int = 0
    var lastReportedScrollPosition: Double = 1

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
}
#endif
