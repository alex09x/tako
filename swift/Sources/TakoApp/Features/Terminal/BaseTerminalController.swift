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

    /// The currently focused surface.
    var focusedSurface: Tako.SurfaceView? {
        didSet {
            syncFocusToSurfaceTree()
            if let focusedSurface, focusedSurface != oldValue {
                focusedSurface.publishEvent(type: "pane_focused", payload: [:])
            }
        }
    }

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

    /// Whether the Session Sidebar panel is showing for this window (B5).
    @Published var sessionSidebarIsShowing: Bool = SessionSidebarStore.shared.isShowing {
        didSet {
            if SessionSidebarStore.shared.isShowing != sessionSidebarIsShowing {
                SessionSidebarStore.shared.isShowing = sessionSidebarIsShowing
            }
            guard oldValue, !sessionSidebarIsShowing else { return }
            DispatchQueue.main.async { [weak self] in
                Tako.moveFocus(to: self?.focusedSurface)
            }
        }
    }

    /// Whether the Pane Overview overlay is showing for this window (B6).
    @Published var paneOverviewIsShowing: Bool = false {
        didSet {
            guard oldValue, !paneOverviewIsShowing else { return }
            DispatchQueue.main.async { [weak self] in
                Tako.moveFocus(to: self?.focusedSurface)
            }
        }
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
        self.surfaceTree = tree ?? .init(view: Tako.SurfaceView(tako, baseConfig: base))
        for view in surfaceTree { view.adopt(by: tako) }
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

    /// Create a new split.
    @discardableResult
    func newSplit(
        at oldView: Tako.SurfaceView,
        direction: SplitTree<Tako.SurfaceView>.NewDirection,
        baseConfig config: Tako.SurfaceConfiguration? = nil
    ) -> Tako.SurfaceView? {
        // We can only create new splits for surfaces in our tree.
        guard surfaceTree.root?.node(view: oldView) != nil else { return nil }

        // Create a new surface view
        let newView = Tako.SurfaceView(tako, baseConfig: config)

        // Do the split
        let newTree: SplitTree<Tako.SurfaceView>
        do {
            newTree = try surfaceTree.inserting(
                view: newView,
                at: oldView,
                direction: direction)
        } catch {
            // If splitting fails for any reason (it should not), then we just log
            // and return. The new view we created will be deinitialized and its
            // no big deal.
            Tako.logger.warning("failed to insert split: \(error, privacy: .public)")
            return nil
        }

        replaceSurfaceTree(
            newTree,
            moveFocusTo: newView,
            moveFocusFrom: oldView,
            undoAction: "New Split")

        return newView
    }

    func focusSurface(_ view: Tako.SurfaceView) {
        // Check if target surface is in our tree
        guard surfaceTree.contains(view) else { return }

        // Move focus to the target surface and activate the window/app
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
        let added = Set(to).subtracting(Set(from))
        let removed = Set(from).subtracting(Set(to))
        for view in added {
            view.publishEvent(type: "pane_created", payload: ["title": .string(view.title), "cwd": view.pwd.map(JSON.string) ?? .null])
        }
        for view in removed {
            view.publishEvent(type: "pane_closed", payload: [:])
        }
        // If our surface tree becomes empty then we have no focused surface.
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
            let totalChildren = parentSurfaces.reduce(0) { $0 + SubagentHierarchyStore.shared.children(of: $1.id).count }
            confirmClose(
                messageText: "Close Parent Pane and Subagents?",
                informativeText: "This pane has \(totalChildren) child subagent\(totalChildren == 1 ? "" : "s"). Closing it will also close its child panes."
            ) { [weak self] in
                guard let self else { return }
                for parent in parentSurfaces {
                    let childIds = SubagentHierarchyStore.shared.children(of: parent.id)
                    for cid in childIds {
                        if let childSurface = self.surfaceTree.first(where: { $0.id == cid }),
                           let childNode = self.surfaceTree.root?.node(view: childSurface) {
                            self.removeSurfaceNode(childNode)
                        }
                    }
                }
                self.removeSurfaceNode(node)
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
        // Setup our new split tree
        let oldTree = surfaceTree
        surfaceTree = newTree
        if let newView {
            DispatchQueue.main.async {
                Tako.moveFocus(to: newView, from: oldView)
            }
        }

        // Setup our undo
        guard let undoManager else { return }
        if let undoAction {
            undoManager.setActionName(undoAction)
        }

        undoManager.registerUndo(
            withTarget: self,
            expiresAfter: undoExpiration
        ) { target in
            target.surfaceTree = oldTree
            if let oldView {
                DispatchQueue.main.async {
                    Tako.moveFocus(to: oldView, from: target.focusedSurface)
                }
            }

            undoManager.registerUndo(
                withTarget: target,
                expiresAfter: target.undoExpiration
            ) { target in
                target.replaceSurfaceTree(
                    newTree,
                    moveFocusTo: newView,
                    moveFocusFrom: target.focusedSurface,
                    undoAction: undoAction)
            }
        }
    }


    func focusedSurfaceDidChange(to: Tako.SurfaceView?) {
        let lastFocusedSurface = focusedSurface
        focusedSurface = to

        if let focused = to {
            NotificationStore.shared.markRead(surfaceId: focused.id)
            AttentionManager.shared.markSeen(surfaceId: focused.id)
        }
        SessionSidebarStore.shared.objectWillChange.send()

        // Important to cancel any prior subscriptions
        focusedSurfaceCancellables = []

        // Setup our title listener. If we have a focused surface we always use that.
        // Otherwise, we try to use our last focused surface. In either case, we only
        // want to care if the surface is in the tree so we don't listen to titles of
        // closed surfaces.
        if let titleSurface = focusedSurface ?? lastFocusedSurface,
           surfaceTree.contains(titleSurface) {
            // If we have a surface, we want to listen for title changes.
            titleSurface.$titleText
                .combineLatest(titleSurface.$bell)
                .map { [weak self] in self?.computeTitle(title: $0, bell: $1) ?? "" }
                .sink { [weak self] in self?.titleDidChange(to: $0) }
                .store(in: &focusedSurfaceCancellables)
        } else {
            // There is no surface to listen to titles for.
            titleDidChange(to: "👻")
        }
    }


    /// Override this to resync any appearance related properties. This will be called automatically
    /// when certain window properties change that affect appearance. The list below should be updated
    /// as we add new things:
    ///
}
