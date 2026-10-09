/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation
import SwiftUI
import Combine
import OSLog
import TakoKit

extension Tako {
    open class SurfaceView: TakoTerminalNSView, Identifiable, ObservableObject, Codable, TakoTerminalNSViewDelegate, SecureInputCheckable {
        /// Identity carried across a layout restore (see the Codable
        /// conformance below); nil for a surface created fresh.
        public var restoredID: String?
        public typealias ID = UUID

        public let id: UUID
        public var uuid: UUID { id }

        var _explicitSecureInput: Bool = false

        @Published var derivedConfig: DerivedConfig

        weak var owningApp: Tako.App?
        var configObserver: NSObjectProtocol?
        var triggersObserver: NSObjectProtocol?
        public var onExit: ((SurfaceView) -> Void)?
        public var onTitleChange: ((SurfaceView) -> Void)?
        public var onFocusRequest: ((SurfaceView) -> Void)?
        var confirmCloseSurface: Tako.Config.ConfirmCloseSurface = .whenBusy
        public var safePaste: Bool = true
        var clipboard: NSPasteboard = .general
        var copyOnSelect: Tako.Config.CopyOnSelect = .selection
        var resumeBannerHostingView: NSView?

        public internal(set) var pty: PTY?
        /// The persistent session this terminal's shell lives in, when
        /// session-persistence is on.
        var persistence: SurfaceSession?

        let parserQueue: DispatchQueue
        let ptyRedrawLock = NSLock()
        var ptyRedrawScheduled = false

        /// The pending synchronized-output watchdog, if one is armed. Main
        /// thread only; `watchdogAction` above decides what happens to it.
        var syncOutputTimeoutItem: DispatchWorkItem?
        /// Debounce work item for refreshing search hit marks during rapid output.
        var searchHitDebounceItem: DispatchWorkItem?
        /// Earliest refresh request time in the current continuous burst (bounded debounce).
        var searchHitBurstStartTime: TimeInterval = 0
        /// Set by the watchdog to let one `draw()` past the sync-output guard.

        var syncOverride = false

        /// there; a property wrapper cannot be added by overriding, so the
        /// publisher lives here beside it.
        @Published public private(set) var titleText: String = ""

        override public func titleDidChange() {
            if !title.isEmpty { isUserSetTitle = false }
            titleText = title
        }
        public var isUserSetTitle: Bool = false

        /// The shell's current directory. Published so the app can follow it
        /// into window titles and the tab bar.
        @Published public internal(set) var pwd: String?
        override open var workingDirectory: String? {
            get { pwd }
            set { pwd = newValue }
        }

        public var surface: tako_surface_t? { nil }

        /// Set while the key self-test runs, so the bytes are recorded
        /// instead of reaching the shell.
        public var selfTestCapturing = false
        public internal(set) var selfTestBytes: [UInt8] = []

        var _currentProcess: PTY?
        let processLock = NSLock()
        var currentProcess: PTY? {
            get { processLock.withLock { _currentProcess } }
            set { processLock.withLock { _currentProcess = newValue } }
        }
        var configuredTheme: TerminalTheme?

        /// Where the find needle is shared with other apps' find bars.
        var findPasteboard: OSPasteboard = .find

        /// The match the find bar last selected, in retained rows.
        var currentSearchMatch: SearchMatch?

        var searchNeedleCancellable: AnyCancellable?

        public private(set) lazy var surfaceModel: Tako.Surface? = Tako.Surface(view: self)

        @Published public internal(set) var focused: Bool = true

        public var focusInstant: Date = Date()
        public var readonly: Bool = false
        public var initialSize: NSSize?
        public var surfaceSize: NSSize?

        @Published public var progressReport: Tako.Action.ProgressReport? = nil
        @Published public var keySequence: [KeyboardShortcut] = []
        public var keyTables: [String] = []
        public var hoverUrl: URL? = nil
        public var childExitedMessage: Tako.ChildExitedMessage? = nil
        public var inspector: Tako.Inspector? = nil
        @Published public var inspectorVisible: Bool = false
        /// The open find bar, or nil when it is closed. Published so the
        /// SwiftUI wrapper shows and hides the bar.
        @Published var searchState: Tako.OSSurfaceView.SearchState? = nil {
            didSet { searchStateDidChange() }
        }

        /// The open output filter bar (Focus mode), or nil when it is closed (E5).
        @Published public var outputFilterState: OutputFilterState? = nil
        public var scrollbar: Tako.Action.Scrollbar? = nil

        public init(
            _ app: Tako.App? = nil,
            baseConfig: Tako.SurfaceConfiguration? = nil,
            uuid: UUID = UUID(),
            theme: TerminalTheme? = nil
        ) {
            self.id = uuid
            self.derivedConfig = app != nil ? DerivedConfig(app!.config) : DerivedConfig()
            self.owningApp = app
            self.parserQueue = DispatchQueue(
                label: "com.tako.parser-\(uuid.uuidString)",
                qos: .userInitiated
            )
            // The terminal -- core, text renderer, Metal stack, input, cursor
            // blinking -- is the inherited surface's. This class only adds the
            // windowing identity around it.
            // The app's config is the one it loaded (TAKO_CONFIG_PATH, a UI
            // test's file); the user's default config is for a surface
            // without an app.
            let baseTheme = theme ?? app?.config.theme ?? TerminalTheme.loadUserConfig()
            // `window-inherit-font-size` (default true): a new window, tab or
            // split starts at the focused terminal's current, possibly
            // zoomed, size rather than the configured default.
            let explicitFontSize = baseConfig?.fontSize.map(CGFloat.init)
            let inheritedFontSize = (app?.config.windowInheritFontSize ?? true) ? Tako.focusedFontSize : nil
            let initialTheme = (explicitFontSize ?? inheritedFontSize)
                .map { Self.scaledTheme(baseTheme, toFontSize: $0) } ?? baseTheme
            super.init(frame: .zero, theme: initialTheme)
            // The surface produces input bytes and hands them to its delegate.
            // Without this every keystroke, mouse report and scroll report is
            // computed and then dropped on the floor.
            delegate = self
            if let app {
                applySurfaceConfig(app.config)
            }
            observeConfigReload()
            // A new tab, split or window opens where the focused one is
            // (`window-inherit-working-directory`, default true); otherwise
            // (including the app's very first terminal, which has no focused
            // one to inherit from) it falls back to `working-directory`.
            let inheritWorkingDirectory = app?.config.windowInheritWorkingDirectory ?? true
            let inherited = baseConfig?.workingDirectory
                ?? (inheritWorkingDirectory ? Tako.focusedWorkingDirectory : nil)
                ?? app.map { Tako.resolvedWorkingDirectory($0.config) }
            setupCoreAndPty(workingDir: inherited, restoring: baseConfig?.restoredSnapshot,
                            restored: baseConfig?.isRestored ?? false,
                            hadPersistentSession: baseConfig?.hadPersistentSession ?? false,
                            allowsPersistence: baseConfig?.allowsSessionPersistence ?? true,
                            program: baseConfig?.program,
                            programEnvironment: baseConfig?.environmentVariables ?? [:])
            if let initial = baseConfig?.initialInput, !initial.isEmpty {
                write(initial)
            }
            setupAttentionObservation()
            setupPassiveRegexTriggers()
        }

        var attentionCancellables: [AnyCancellable] = []

        required public init?(coder: NSCoder) {
            nil
        }

        public enum CodingKeys: String, CodingKey { case id, pwd, persistent }

        public required convenience init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let savedID = try? container.decode(String.self, forKey: .id)
            let savedPwd = try? container.decode(String.self, forKey: .pwd)
            let persistent = (try? container.decode(Bool.self, forKey: .persistent)) ?? false
            let (app, base, uuid) = Self.decodeRestorationConfig(savedID: savedID, savedPwd: savedPwd, persistent: persistent)
            self.init(app, baseConfig: base, uuid: uuid)
            self.restoredID = savedID
        }

        var commandFinishSignals = 0

        /// Counts the PTY reads this surface has parsed; a snapshot is
        /// written again only when it moved. Bumped on `parserQueue`, read on
        /// the main thread.
        var contentGeneration: UInt64 = 0
        let generationLock = NSLock()

        public private(set) lazy var cachedScreenContents = CachedValue<String> { [weak self] in
            guard let self else { return "" }
            let total = Int(self.core.scrollbackLen()) + self.rows
            return (0..<total)
                .map { row in
                    String(String.UnicodeScalarView(
                        self.core.viewportRow(row: UInt32(row))
                            .compactMap { UnicodeScalar($0.ch) }))
                }
                .joined(separator: "\n")
        }

        /// Just what the viewport is showing.
        public private(set) lazy var cachedVisibleContents = CachedValue<String> { [weak self] in
            guard let self else { return "" }
            return (0..<self.rows)
                .map { row in
                    String(String.UnicodeScalarView(
                        self.core.viewportRow(row: UInt32(row))
                            .compactMap { UnicodeScalar($0.ch) }))
                }
                .joined(separator: "\n")
        }

        /// Command lifecycle for this surface, which is what the tab's crab
        /// indicator draws.
        public let crab = Tako.CrabTracker()

        /// Keeps the crab in this surface's tab. Held here so it lives as
        /// long as the surface does.
        private var crabBinding: Tako.CrabTabBinding?

        /// The window this surface's crab is currently bound to, so moving
        /// between windows rebinds but staying put does not.
        private weak var crabWindow: NSWindow?

        override open func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { crabBinding = nil; crabWindow = nil; return }
            guard window !== crabWindow else { return }
            crabWindow = window
            crabBinding = Tako.CrabTabBinding(surface: self, window: window)
            Tako.TabBarController.install(in: window)
        }

        /// The surface's own background, which the window matches so the
        /// titlebar and padding blend with the terminal.
        @Published public var backgroundColor: Color?

        /// Whether the window showing this surface is currently on screen.
        /// The controller keeps this in sync so the core can stop rendering
        /// for hidden windows.
        public var isWindowVisible: Bool = true

        /// Set while the terminal has rung its bell and the user has not yet
        /// looked at it. Published so the title and dock badge can follow.
        @Published public var bell: Bool = false

        // Find, font size, reset and binding dispatch live in
        // Tako+SurfaceActions.swift; this is the state they keep.

        /// The theme the configuration asked for. Font size changes are made
        /// relative to it, and resetting the font size returns to it.


        var commandStartedAt: TimeInterval?
        var runProgram: [String]?
        var runEndNote: String?
        var activeRunningCommandText: String?
        var onPtyReply: ((String) -> Void)?
        var sessionRetry: (() -> Void)?
        var hadPersistentSession = false

        deinit {
            searchHitDebounceItem?.cancel()
            pty?.terminate()
            if let configObserver {
                NotificationCenter.default.removeObserver(configObserver)
            }
            if let triggersObserver {
                NotificationCenter.default.removeObserver(triggersObserver)
            }
        }

        var app: Tako.App? { owningApp }

        /// Evaluates safe paste guard before sending text to the shell.
        /// If the clipboard contains newlines, safe paste is enabled, and the terminal
        /// is idle at a shell prompt, posts a confirmation request instead of pasting immediately.
        @objc override public func handlePaste(_ text: String) {
            let isMultiLine = text.contains("\n") || text.contains("\r")
            if safePaste && isMultiLine && core.cursorIsAtPrompt() && !isCommandRunning {
                NotificationCenter.default.post(
                    name: Tako.Notification.confirmClipboard,
                    object: self,
                    userInfo: [
                        Tako.Notification.ConfirmClipboardStrKey: text,
                        Tako.Notification.ConfirmClipboardRequestKey: Tako.ClipboardRequest.paste,
                    ]
                )
                return
            }
            pasteText(text)
        }

        override public func selectionDidFinish() {
            guard copyOnSelect != .off, let text = core.selectedText(), !text.isEmpty else { return }
            var targets = [Self.selectionPasteboard]
            if copyOnSelect == .clipboard {
                targets.append(clipboard)
            }
            for pasteboard in targets {
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }

        override open func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result {
                BroadcastInputStore.shared.setLeader(paneId: id)
                if isSecureInput {
                    SecureInput.shared.setScoped(self, isSecure: true, focused: true)
                }
                crab.focused()
                NotificationStore.shared.markRead(surfaceId: self.id)
                reflowToCurrentBounds(forcePtyResize: true)
            }
            return result
        }

        override open func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result {
                if isSecureInput {
                    SecureInput.shared.setScoped(self, isSecure: true, focused: false)
                }
                crab.unfocused()
            }
            return result
        }

        override open var isAtShellPrompt: Bool {
            guard !isCommandRunning else { return false }
            return super.isAtShellPrompt
        }

        @objc override public func copy(_ sender: Any?) {
            super.copy(sender)
        }

        override public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
            validateFindItem(item.action) ?? super.validateUserInterfaceItem(item)
        }

        @objc override public func paste(_ sender: Any?) {
            guard let text = NSPasteboard.general.string(forType: .string) else { return }
            self.handlePaste(text)
        }

        open override func toggleOutputFilter() {
            if outputFilterState != nil {
                closeOutputFilter()
            } else {
                openOutputFilter()
                if outputFilterState?.query.isEmpty ?? true {
                    super.toggleOutputFilter()
                }
            }
        }

        @objc override public func insertInputText(_ text: String) {
            insertInputText(text, isBroadcastRecipient: false)
        }

        override open func keyDown(with event: NSEvent) {
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == 53 && mods.isEmpty {
                // Escape key with no modifiers: if an overlay or diff review is open on this pane, dismiss it
                if OverlayStore.shared.overlay(for: id) != nil {
                    OverlayStore.shared.closeOverlay(paneId: id)
                    return
                }
                if DiffReviewStore.shared.session(for: id) != nil {
                    DiffReviewStore.shared.closeReview(paneId: id)
                    return
                }
            }
            super.keyDown(with: event)
        }
    }
}
