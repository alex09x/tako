/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Cocoa
import SwiftUI
import Combine
import TakoKit

/// A base class for windows that can contain Tako terminal surfaces, implementing
/// common window management, split tree hierarchy, focus, and clipboard/fullscreen delegates.
class BaseTerminalController: NSWindowController,
                              NSWindowDelegate,
                              TerminalViewDelegate,
                              TerminalViewModel,
                              ClipboardConfirmationViewDelegate,
                              FullscreenDelegate {
    /// The app instance that this terminal view will represent.
    let tako: Tako.App

    private var updatingFocusedSurfaceFromDelegate = false

    /// The currently focused surface.
    var focusedSurface: Tako.SurfaceView? {
        didSet {
            if usesFloatingCanvas, let focusedSurface {
                floatingCanvas.noteExplicitFocusChange(to: focusedSurface.id)
                floatingCanvas.bringToFront(focusedSurface.id)
            }
            syncFocusToSurfaceTree()
            if usesFloatingCanvas, focusedSurface !== oldValue {
                objectWillChange.send()
                if !updatingFocusedSurfaceFromDelegate { bindFocusedSurfaceSubscriptions(previous: oldValue) }
            }
            if let focusedSurface, focusedSurface != oldValue {
                focusedSurface.publishEvent(type: "pane_focused", payload: [:])
            }
        }
    }

    /// Whether this controller renders surfaces inside `FloatingTerminalCanvasView`.
    var usesFloatingCanvas: Bool { false }

    /// Layout state for freely floating, maximized, and minimized panes inside the session canvas.
    let floatingCanvas = FloatingCanvasStore()

    /// The tree of splits within this terminal window.
    @Published var surfaceTree: SplitTree<Tako.SurfaceView> = .init() {
        didSet { surfaceTreeDidChange(from: oldValue, to: surfaceTree) }
    }

    /// This can be set to show/hide the command palette.
    @Published var commandPaletteIsShowing: Bool = false

    /// Whether the Find in All Tabs panel is over this window. Closing it
    /// gives the keyboard back to the terminal, as the command palette does;
    /// otherwise the next keys go nowhere.
    @Published var findAllIsShowing: Bool = false {
        didSet {
            guard oldValue, !findAllIsShowing else { return }
            DispatchQueue.main.async { [weak self] in
                Tako.moveFocus(to: self?.focusedSurface)
            }
        }
    }

    /// Whether the Notification Center panel is over this window (B4).
    @Published var notificationCenterIsShowing: Bool = false {
        didSet {
            guard oldValue, !notificationCenterIsShowing else { return }
            DispatchQueue.main.async { [weak self] in
                Tako.moveFocus(to: self?.focusedSurface)
            }
        }
    }

    /// Whether this terminal window type hosts the permanent Session Sidebar.
    /// Desktop `TerminalController` windows always show it; `QuickTerminalController` stays separate.
    var supportsSessionSidebar: Bool { false }

    /// Permanent sidebar state for this window (`true` on desktop windows, `false` on Quick Terminal).
    @Published var sessionSidebarIsShowing: Bool = false {
        didSet {
            let expected = supportsSessionSidebar
            if sessionSidebarIsShowing != expected {
                sessionSidebarIsShowing = expected
            }
        }
    }

    /// Whether the Pane Overview overlay is showing for this window (B6).
    @Published var paneOverviewIsShowing: Bool = false {
        didSet {
            if !paneOverviewIsShowing {
                currentOverviewPresentationToken = nil
                paneOverviewOpenStartTime = 0
            }
            guard oldValue, !paneOverviewIsShowing else { return }
            DispatchQueue.main.async { [weak self] in
                Tako.moveFocus(to: self?.focusedSurface)
            }
        }
    }

    /// When true, suppresses rendering of the pane overview view even when paneOverviewIsShowing is true.
    /// Used for negative-control verification of presentation observation gates.
    @Published var paneOverviewRenderSuppressed: Bool = false

    /// Unique presentation token identifying the active pane overview presentation cycle.
    internal(set) var currentOverviewPresentationToken: UUID?

    /// Timestamp when pane overview was triggered to open via production action.
    internal(set) var paneOverviewOpenStartTime: CFAbsoluteTime = 0

    /// Callback invoked when pane overview presents its first interactive frame.
    /// Passes: (TimeInterval: elapsed since open trigger, Int: count of presented pane items)
    var onPaneOverviewPresented: ((TimeInterval, Int) -> Void)?

    /// Records an observed rendered/presented frame for the active overview opening cycle.
    /// - Parameters:
    ///   - token: The token matching the active presentation instance. If provided and does not match, the call is ignored.
    ///   - itemCount: The count of rendered pane overview items.
    /// - Returns: Total elapsed time from open trigger to the presented frame, or nil if no matching presentation was active.
    @discardableResult
    func recordOverviewPresentedFrame(
        token: UUID? = nil,
        itemCount: Int,
        observedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> TimeInterval? {
        guard paneOverviewIsShowing, paneOverviewOpenStartTime > 0 else { return nil }
        if let token, let currentToken = currentOverviewPresentationToken, token != currentToken {
            return nil
        }
        let elapsed = max(0, observedAt - paneOverviewOpenStartTime)
        currentOverviewPresentationToken = nil
        paneOverviewOpenStartTime = 0
        onPaneOverviewPresented?(elapsed, itemCount)
        return elapsed
    }

    /// The window hosting this terminal view controller (TerminalViewModel).
    /// True when any surface in this controller currently has an active bell.
    @Published internal(set) var bell: Bool = false

    /// Whether the terminal surface should focus when the mouse is over it.
    /// Non-nil when an alert is active so we don't overlap multiple.
    var alert: NSAlert?
    /// True while a confirmation is drawn in the window (`TerminalDialogView`).
    var asking = false

    /// The clipboard confirmation window, if shown.
    var clipboardConfirmation: ClipboardConfirmationController?

    /// The config file "Always Paste" writes to; nil means the user's own.
    /// Tests point it at a scratch file.
    var pasteGuardConfigFile: KeybindConfigFile?

    /// Fullscreen state management.
    internal(set) var fullscreenStyle: FullscreenStyle?

    /// Event monitor (see individual events for why)
    var eventMonitor: Any?

    /// The previous frame information from the window
    var savedFrame: SavedFrame?

    /// Cache previously applied appearance to avoid unnecessary updates
    var appliedColorScheme: tako_color_scheme_e?

    /// The configuration derived from the Tako config so we don't need to rely on references.
    var baseDerivedConfig: DerivedConfig

    /// Track whether background is forced opaque (true) or using config transparency (false)
    var isBackgroundOpaque: Bool = false

    /// The cancellables related to our focused surface.
    var focusedSurfaceCancellables: Set<AnyCancellable> = []

    /// Cancellable for aggregating bell state across all surfaces in this controller.
    var bellStateCancellable: AnyCancellable?

    /// Cancellable for synchronizing session sidebar visibility across all controllers (B5).
    var sidebarStateCancellable: AnyCancellable?

    /// An override title for the tab/window set by the user via prompt_tab_title.
    /// When set, this takes precedence over the computed title from the terminal.
    var titleOverride: String? {
        didSet { applyTitleToWindow() }
    }

    /// The last computed title from the focused surface (without the override).
    var lastComputedTitle: String = "👻"

    /// The time that undo/redo operations that contain running ptys are valid for.
    var undoExpiration: Duration {
        tako.config.undoTimeout
    }

    /// The undo manager for this controller is the undo manager of the window,
    /// which we set via the delegate method.
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    init(_ tako: Tako.App,
         baseConfig base: Tako.SurfaceConfiguration? = nil,
         surfaceTree tree: SplitTree<Tako.SurfaceView>? = nil
    ) {
        self.tako = tako
        self.baseDerivedConfig = DerivedConfig(tako.config)
        super.init(window: nil)
        self.sessionSidebarIsShowing = self.supportsSessionSidebar
        self.surfaceTree = tree ?? .init(view: Tako.SurfaceView(tako, baseConfig: base))
        for view in surfaceTree { view.adopt(by: tako) }
        configureFloatingCanvasPersistence()
        setupBellNotificationPublisher()
        setupSidebarStatePublisher()
        setupNotificationObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        undoManager?.removeAllActions(withTarget: self)
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    /// Create a new split. `focus` false (a script's `--no-select`) leaves
    /// the keyboard with the pane that has it.
    @discardableResult
    func newSplit(
        at oldView: Tako.SurfaceView,
        direction: SplitTree<Tako.SurfaceView>.NewDirection,
        baseConfig config: Tako.SurfaceConfiguration? = nil,
        focus: Bool = true
    ) -> Tako.SurfaceView? {
        guard surfaceTree.root?.node(view: oldView) != nil else { return nil }
        let newView = Tako.SurfaceView(tako, baseConfig: config)
        let newTree: SplitTree<Tako.SurfaceView>
        do {
            newTree = try surfaceTree.inserting(view: newView, at: oldView, direction: direction)
        } catch {
            Tako.logger.warning("failed to insert split: \(error, privacy: .public)")
            return nil
        }

        if usesFloatingCanvas {
            floatingCanvas.setPendingSplitHint(.init(anchorId: oldView.id, newId: newView.id, direction: direction))
        }
        replaceSurfaceTree(newTree, moveFocusTo: focus ? newView : nil, moveFocusFrom: oldView, undoAction: "New Split")
        return newView
    }

    func focusSurface(_ view: Tako.SurfaceView) {
        guard surfaceTree.contains(view) else { return }
        if usesFloatingCanvas {
            revealAndFocusFloatingPane(view)
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        DispatchQueue.main.async {
            Tako.moveFocus(to: view)
            if let window = view.window {
                Tako.CustomTabGroup.group(for: window).select(window)
            }
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func surfaceTreeDidChange(from: SplitTree<Tako.SurfaceView>, to: SplitTree<Tako.SurfaceView>) {
        for view in to { view.adopt(by: tako) }
        if usesFloatingCanvas {
            floatingCanvas.sync(with: to, fallbackSize: estimatedFloatingCanvasSize())
        }
        let added = Set(to).subtracting(Set(from))
        let removed = Set(from).subtracting(Set(to))
        for view in added {
            view.publishEvent(type: "pane_created", payload: ["title": .string(view.title), "cwd": view.pwd.map(JSON.string) ?? .null])
        }
        for view in removed {
            view.publishEvent(type: "pane_closed", payload: [:])
        }
        if to.isEmpty {
            focusedSurface = nil
        }
        syncSurfaceTreeOcclusionState()
    }

    /// Override this to resync any appearance related properties. This will be called automatically
    /// when certain window properties change that affect appearance.
    func syncAppearance() {
        // Purposely a no-op. This lets subclasses override this and we can call
        // it virtually from here.
    }

    /// Close a surface node (which may contain splits), requesting confirmation if necessary.
    ///
    /// This will also insert the proper undo stack information in.
    func closeSurface(
        _ node: SplitTree<Tako.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        // This node must be part of our tree
        guard surfaceTree.contains(node) else { return }

        // Check if closing a parent pane that has subagent children (C5)
        let parentSurfaces = node.filter { SubagentHierarchyStore.shared.hasChildren($0.id) }
        if !parentSurfaces.isEmpty {
            let totalChildren = parentSurfaces.reduce(0) { $0 + SubagentHierarchyStore.shared.descendants(of: $1.id).count }
            confirmClose(
                messageText: "Close Parent Pane and Subagents?",
                informativeText: "This pane has \(totalChildren) child subagent\(totalChildren == 1 ? "" : "s"). Closing it will also close its child panes."
            ) { [weak self] in
                guard let self else { return }
                for parent in parentSurfaces {
                    let descendantIds = SubagentHierarchyStore.shared.descendants(of: parent.id)
                    for cid in descendantIds.reversed() {
                        if let childSurface = self.surfaceTree.first(where: { $0.id == cid }),
                           let childNode = self.surfaceTree.root?.node(view: childSurface) {
                            self.removeSurfaceNode(childNode)
                        }
                    }
                    if let parentSurface = self.surfaceTree.first(where: { $0.id == parent.id }),
                       let pNode = self.surfaceTree.root?.node(view: parentSurface) {
                        self.removeSurfaceNode(pNode)
                    }
                }
                if self.surfaceTree.contains(node) {
                    self.removeSurfaceNode(node)
                }
            }
            return
        }

        // If the child process is not alive, then we exit immediately
        guard withConfirmation else {
            removeSurfaceNode(node)
            return
        }

        // Confirm close. We use an NSAlert instead of a SwiftUI confirmationDialog
        // due to a SwiftUI bug:
        // confirmationDialog allows the user to Cmd-W close the alert, but when doing
        // so SwiftUI does not update any of the bindings to note that window is no longer
        // being shown, and provides no callback to detect this.
        confirmClose(
            messageText: "Close Terminal?",
            informativeText: "The terminal still has a running process. If you close the terminal the process will be killed."
        ) { [weak self] in
            if let self {
                self.removeSurfaceNode(node)
            }
        }
    }

    func replaceSurfaceTree(
        _ newTree: SplitTree<Tako.SurfaceView>,
        moveFocusTo newView: Tako.SurfaceView? = nil,
        moveFocusFrom oldView: Tako.SurfaceView? = nil,
        undoAction: String? = nil
    ) {
        applySurfaceTreeReplacement(newTree, moveFocusTo: newView, moveFocusFrom: oldView, undoAction: undoAction)
    }

    func focusedSurfaceDidChange(to: Tako.SurfaceView?) {
        let lastFocusedSurface = focusedSurface
        updatingFocusedSurfaceFromDelegate = true
        focusedSurface = to
        updatingFocusedSurfaceFromDelegate = false
        bindFocusedSurfaceSubscriptions(previous: lastFocusedSurface)
    }

    private func bindFocusedSurfaceSubscriptions(previous lastFocusedSurface: Tako.SurfaceView?) {
        if let focused = focusedSurface {
            NotificationStore.shared.markRead(surfaceId: focused.id)
            AttentionManager.shared.markSeen(surfaceId: focused.id)
        }
        SessionSidebarStore.shared.objectWillChange.send()
        focusedSurfaceCancellables = []
        if let titleSurface = focusedSurface ?? lastFocusedSurface, surfaceTree.contains(titleSurface) {
            titleSurface.$titleText
                .combineLatest(titleSurface.$bell)
                .map { [weak self] in self?.computeTitle(title: $0, bell: $1) ?? "" }
                .sink { [weak self] in self?.titleDidChange(to: $0) }
                .store(in: &focusedSurfaceCancellables)
        } else {
            titleDidChange(to: "👻")
        }
    }
}
