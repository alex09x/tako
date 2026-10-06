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

#if canImport(UIKit)
import CoreGraphics
import Metal
import QuartzCore
import UIKit
import simd

/// A public production UIKit terminal surface built over `TakoCore` and
/// the shared `MetalTerminalRenderer`.
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
            core.setBaseColors(from: theme)
            core.setDefaultCursorStyle(from: theme)
            core.setGraphemeWidthMethod(from: theme)
            core.setColorScheme(from: theme)
            sendQueuedReplies()
            rebuildMetalRenderer()
            updateBlinkTimer()
            setNeedsLayout()
            setNeedsDisplay()
        }
    }
    public private(set) var renderer: TerminalRenderer
    public internal(set) var cols: Int = 80
    public internal(set) var rows: Int = 24

    /// Automatically opens the software keyboard when tapped.
    public var autoFocusKeyboardOnTap: Bool = true

    // MARK: - Metal State

    public private(set) var metalRenderer: MetalTerminalRenderer?
    public private(set) var metalLayer: CAMetalLayer?
    public private(set) var metalUnavailableReason: String?
    public private(set) var lastFrameStatistics: TerminalMetalFrameStatistics?
    public var customShaderErrors: [String] { metalRenderer?.customShaderErrors ?? [] }

    var metalContentScale: CGFloat = 1
    var rendererBuildCount: Int = 0
    var frameFetchCount: Int = 0
    var redrawPending: Bool = false
    var presentationRetryPending: Bool = false
    var unpresentedFrameCount: Int = 0
    var redrawHeldBySynchronizedOutput: Bool = false
    var displayLink: CADisplayLink?

    var pendingResizeWorkItem: DispatchWorkItem?
    var pendingGridSize: (cols: Int, rows: Int)?
    static let resizeSettleDelay: TimeInterval = 0.1

    static var metalLibraryBundle: Bundle { ShaderBundle.resources }
    public static var isMetalDisabledForTesting = false
    public static var metalLibraryProviderForTesting: ((MTLDevice) -> MTLLibrary?)?

    // Cursor blink state
    var blinkTimer: Timer?
    var blinkStateVisible: Bool = true

    var pasteStringProvider: () -> String? = { UIPasteboard.general.string }
    var copyStringConsumer: (String) -> Void = { UIPasteboard.general.string = $0 }

    // Gestures & kinetic momentum
    var panGesture: UIPanGestureRecognizer?
    var longPressGesture: UILongPressGestureRecognizer?
    var tapGesture: UITapGestureRecognizer?
    var panAccumulatedY: CGFloat = 0

    public static var allowOffscreenKineticStepForTesting: Bool = false
    var kineticDeceleration = TerminalKineticDeceleration()
    var kineticDisplayLink: CADisplayLink?
    var kineticTouchLocation: CGPoint = .zero
    var kineticInitialModes: FfiTerminalModes?

    public var isKineticScrolling: Bool {
        kineticDeceleration.isDecelerating
    }

    public var kineticVelocity: Double {
        kineticDeceleration.velocity
    }

    public var isAlternateScreen: Bool { core.modes().alternateScreen }
    public var isAlternateScroll: Bool { core.modes().alternateScroll }

    var isSelecting: Bool = false
    var editMenuInteractionStorage: Any?
    var editMenuInteractionDelegateStorage: Any?

    var lastReportedScrollPosition: Double = 1
    let presentationClock = TerminalPresentationClock()
    public var presentationCadence: TerminalPresentationCadence { presentationClock.cadence }

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

    public var autocapitalizationType: UITextAutocapitalizationType = .none
    public var autocorrectionType: UITextAutocorrectionType = .no
    public var spellCheckingType: UITextSpellCheckingType = .no
    public var smartQuotesType: UITextSmartQuotesType = .no
    public var smartDashesType: UITextSmartDashesType = .no
    public var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    public var inlinePredictionType: UITextInlinePredictionType = .no

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
        accessibilityIdentifier = "terminal"
        accessibilityTraits = [.updatesFrequently]
    }

    override public var accessibilityValue: String? {
        get { plainText(startRow: 0, maxRows: rows) }
        set { super.accessibilityValue = newValue }
    }

    // MARK: - Core Host Operations

    public func feed(data: Data) {
        parserCoordinator.feedSynchronously(data)
    }

    public func enqueue(data: Data) {
        parserCoordinator.enqueue(data)
    }

    @discardableResult
    public func importCheckpoint(_ blob: Data) throws -> TerminalCheckpointRestore {
        try parserCoordinator.importCheckpoint(blob)
    }

    public func inspectCheckpoint(_ blob: Data) throws -> FfiCheckpointInfo {
        try core.checkpointInspect(blob: blob)
    }

    public var checkpointVersion: UInt32 { core.checkpointVersion() }

    public func supportsCheckpointVersion(_ version: UInt32) -> Bool {
        core.checkpointSupports(version: version)
    }

    public func exportCheckpoint(maxBytes: UInt64 = 64 * 1024 * 1024) throws -> Data {
        try core.checkpointExport(flags: 0, maxBytes: maxBytes)
    }

    public func reset() {
        cancelKineticScroll()
        parserCoordinator.feedSynchronously(Data("\u{001B}c".utf8))
        setNeedsDisplay()
    }

    public var bufferText: String {
        core.bufferText()
    }

    public var scrollPosition: Double {
        get { core.scrollPosition() }
        set {
            cancelKineticScroll()
            core.setScrollPosition(position: newValue)
            lastReportedScrollPosition = core.scrollPosition()
            setNeedsDisplay()
        }
    }

    public var viewportOffset: Int {
        Int(core.viewportOffset())
    }

    public var scrollbackLength: Int {
        Int(core.scrollbackLen())
    }

    public func scrollViewportUp(lines: Int = 1) {
        core.scrollViewportUp(lines: UInt32(max(lines, 1)))
        setNeedsDisplay()
    }

    public func scrollViewportDown(lines: Int = 1) {
        core.scrollViewportDown(lines: UInt32(max(lines, 1)))
        setNeedsDisplay()
    }

    public func scrollViewportToBottom() {
        cancelKineticScroll()
        core.scrollViewportBottom()
        setNeedsDisplay()
    }

    public func scrollToOffset(_ offset: Int) {
        cancelKineticScroll()
        core.scrollViewportBottom()
        if offset > 0 {
            core.scrollViewportUp(lines: UInt32(offset))
        }
        setNeedsDisplay()
    }

    public func plainText(startRow: Int = 0, maxRows: Int = 100) -> String {
        let totalRows = Int(core.rows())
        let start = max(startRow, 0)
        guard start < totalRows else { return "" }
        let maxR = max(maxRows, 1)
        return core.getPlainText(startRow: UInt32(start), maxRows: UInt32(maxR))
    }

    public var selectedText: String? {
        core.selectedText()
    }

}
#endif
