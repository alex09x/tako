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
import SwiftUI
import TakoKit

/// The base class for all standalone, "normal" terminal windows. This sets the basic
/// style and configuration of the window based on the app configuration.
class TerminalWindow: NSWindow {
    /// Posted when a terminal window awakes from nib.
    static let terminalDidAwake = Notification.Name("TerminalWindowDidAwake")

    /// Posted when a terminal window will close
    static let terminalWillCloseNotification = Notification.Name("TerminalWindowWillClose")

    /// This is the key in UserDefaults to use for the default `level` value. This is
    /// used by the manual float on top menu item feature.
    static let defaultLevelKey: String = "TerminalDefaultLevel"

    /// The view model for SwiftUI views
    var viewModel = ViewModel()

    /// Reset split zoom button in titlebar
    let resetZoomAccessory = NSTitlebarAccessoryViewController()

    /// Visual indicator that mirrors the selected tab color.
    private lazy var tabColorIndicator: NSHostingView<TabColorIndicatorView> = {
        let view = NSHostingView(rootView: TabColorIndicatorView(tabColor: tabColor))
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    /// The configuration derived from the Tako config so we don't need to rely on references.
    private(set) var derivedConfig: DerivedConfig = .init()

    /// Sets up our tab context menu
    private var tabMenuObserver: NSObjectProtocol?

    /// Handles inline tab title editing for this host window.
    private(set) lazy var tabTitleEditor = TabTitleEditor(
        hostWindow: self,
        delegate: self
    )

    /// Glass effect view for liquid glass background when transparency is enabled
    private var glassEffectView: NSView?

    /// Gets the terminal controller from the window controller.
    var terminalController: TerminalController? {
        windowController as? TerminalController
    }

    var titlebarFont: NSFont? {
        didSet {
            let font = titlebarFont ?? NSFont.titleBarFont(ofSize: NSFont.systemFontSize)

            titlebarTextField?.font = font
            /// We check `hasMoreThanOneTabs` here because the system
            /// may copy this setting to the tab’s text field at some point(e.g. entering/exiting fullscreen),
            /// which can cause the title to be vertically misaligned (shifted downward).
            ///
            /// This behaviour is the opposite of what happens in the title bar’s text field, which is quite odd...
            titlebarTextField?.usesSingleLineMode = !hasMoreThanOneTabs
            tab.attributedTitle = attributedTitle
        }
    }

    /// The color assigned to this window's tab. Setting this updates the tab color indicator
    /// and marks the window's restorable state as dirty.
    var tabColor: TerminalTabColor = .none {
        didSet {
            guard tabColor != oldValue else { return }
            tabColorIndicator.rootView = TabColorIndicatorView(tabColor: tabColor)
            invalidateRestorableState()
        }
    }

    // MARK: NSWindow Overrides

    override var toolbar: NSToolbar? {
        didSet {
            DispatchQueue.main.async {
                // When we have a toolbar, our SwiftUI view needs to know for layout
                self.viewModel.hasToolbar = self.toolbar != nil
            }
        }
    }

    override func awakeFromNib() {
        // Notify that this terminal window has loaded
        NotificationCenter.default.post(name: Self.terminalDidAwake, object: self)

        // This is fragile, but there doesn't seem to be an official API for customizing
        // native tab bar menus.
        tabMenuObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name(rawValue: "NSMenuWillOpenNotification"),
            object: nil,
            queue: .main
        ) { [weak self] n in
            guard let self, let menu = n.object as? NSMenu else { return }
            self.configureTabContextMenuIfNeeded(menu)
        }

        // AppKit's native tab bar cannot be kept hidden while a window's
        // tabbingMode allows tabbing at all -- confirmed live: it re-shows
        // itself regardless of any titlebar-accessory trick, on its own
        // schedule. `.disallowed` means AppKit never manages tabbing for
        // this window; `Tako.CustomTabGroup` models grouping/order/
        // selection instead (set again, idempotently, in
        // `TabBarController.install`), and `TerminalController.UndoState`/
        // `Fullscreen.SavedState` persist it across undo and fullscreen
        // exit since there's no native group left to fall back on.
        tabbingMode = .disallowed

        // Chrome-style tab strip lives in the titlebar row itself, so the
        // content view has to extend under the titlebar. Confirmed live this
        // has to happen here, at nib-awake, rather than later in
        // `TabBarController.install` (which fires once the surface view deep
        // in the SwiftUI tree finally attaches to the window): setting these
        // after the window's initial layout has already run left
        // `styleMask.contains(.fullSizeContentView)` reporting true while
        // `contentView.frame` still reserved a plain ~28px titlebar band and
        // the native titlebar stayed a solid opaque gray, hiding the custom
        // bar entirely even though it was drawing correctly underneath.
        styleMask.insert(.fullSizeContentView)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden

        // All new windows are based on the app config at the time of creation.
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        let config = appDelegate.tako.config

        // Setup our initial config
        derivedConfig = .init(config)

        // If there is a hardcoded title in the configuration, we set that
        // immediately. A title the terminal sets later overrides this,
        // but this ensures our window loads with the proper
        // title immediately rather than on another event loop tick.
        if let title = derivedConfig.title {
            self.title = title
        }

        // If window decorations are disabled, remove our title
        if !config.windowDecorations { styleMask.remove(.titled) }

        // NOTE: setInitialWindowPosition is NOT called here because subclass
        // awakeFromNib may add decorations (e.g. toolbar for tabs style) that
        // change the frame. It is called from TerminalController.windowDidLoad
        // after the window is fully set up.

        // If our traffic buttons should be hidden, then hide them
        if config.macosWindowButtons == .hidden {
            hideWindowButtons()
        }

        // We deliberately do NOT add resetZoomAccessory as an
        // NSTitlebarAccessoryViewController child here. Confirmed live:
        // having *any* titlebar accessory view controller forces AppKit to
        // keep the native NSTitlebarView layer opaque and drawn above the
        // content view, no matter what titlebarAppearsTransparent/
        // fullSizeContentView say -- which hid Tako.TabBarController's
        // custom strip completely (it drew correctly underneath, just never
        // visible). Upstream hit a related symptom already: tabBarDidAppear()
        // below removes resetZoomAccessory specifically because a titlebar
        // accessory "causes our content view scaling to be wrong" once a tab
        // bar is showing. Now that the custom bar is the only tab bar and is
        // always showing, the accessory just stays off; the reset-zoom
        // titlebar button is lost until that UI is rebuilt inside the custom
        // bar itself.

        // Setup the accessory view for tabs that shows our keyboard shortcuts,
        // zoomed state, etc. Note I tried to use SwiftUI here but ran into issues
        // where buttons were not clickable.
        tabColorIndicator.rootView = TabColorIndicatorView(tabColor: tabColor)

        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.setHuggingPriority(.defaultHigh, for: .horizontal)
        stackView.spacing = 4
        stackView.alignment = .centerY
        stackView.addArrangedSubview(tabColorIndicator)
        stackView.addArrangedSubview(keyEquivalentLabel)
        stackView.addArrangedSubview(resetZoomTabButton)
        tab.accessoryView = stackView

        // Get our saved level
        level = UserDefaults.tako.value(forKey: Self.defaultLevelKey) as? NSWindow.Level ?? .normal
    }

    // Both of these must be true for windows without decorations to be able to
    // still become key/main and receive events.
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

    override func sendEvent(_ event: NSEvent) {
        if tabTitleEditor.handleMouseDown(event) {
            return
        }

        if tabTitleEditor.handleRightMouseDown(event) {
            return
        }

        super.sendEvent(event)
    }

    override func close() {
        tabTitleEditor.finishEditing(commit: true)
        NotificationCenter.default.post(name: Self.terminalWillCloseNotification, object: self)
        super.close()
    }

    override func becomeKey() {
        super.becomeKey()
        resetZoomTabButton.contentTintColor = .controlAccentColor
    }

    override func resignKey() {
        super.resignKey()
        resetZoomTabButton.contentTintColor = .secondaryLabelColor
        tabTitleEditor.finishEditing(commit: true)
    }

    override func becomeMain() {
        super.becomeMain()

        // Its possible we miss the accessory titlebar call so we check again
        // whenever the window becomes main. Both of these are idempotent.
        if tabBarView != nil {
            tabBarDidAppear()
        } else {
            tabBarDidDisappear()
        }
        viewModel.isMainWindow = true
    }

    override func resignMain() {
        super.resignMain()
        viewModel.isMainWindow = false
    }



    override func mergeAllWindows(_ sender: Any?) {
        super.mergeAllWindows(sender)

        // It takes an event loop cycle to merge all the windows so we set a
        // short timer to relabel the tabs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.terminalController?.relabelTabs()
        }
    }

    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        super.addTitlebarAccessoryViewController(childViewController)

        // Tab bar is attached as a titlebar accessory view controller (layout bottom). We
        // can detect when it is shown or hidden by overriding add/remove and searching for
        // it. This has been verified to work on macOS 12 to 26
        if isTabBar(childViewController) {
            childViewController.identifier = Self.tabBarIdentifier
            tabBarDidAppear()
        }
    }

    override func removeTitlebarAccessoryViewController(at index: Int) {
        if let childViewController = titlebarAccessoryViewControllers[safe: index], isTabBar(childViewController) {
            tabBarDidDisappear()
        }

        super.removeTitlebarAccessoryViewController(at: index)
    }

    // MARK: Tab Key Equivalents

    var keyEquivalent: String? {
        didSet {
            // When our key equivalent is set, we must update the tab label.
            guard let keyEquivalent else {
                keyEquivalentLabel.attributedStringValue = NSAttributedString()
                return
            }

            keyEquivalentLabel.attributedStringValue = NSAttributedString(
                string: "\(keyEquivalent) ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: isKeyWindow ? NSColor.labelColor : NSColor.secondaryLabelColor,
                ])
        }
    }

    /// The label that has the key equivalent for tab views.
    private lazy var keyEquivalentLabel: NSTextField = {
        let label = NSTextField(labelWithAttributedString: NSAttributedString())
        label.setContentCompressionResistancePriority(.windowSizeStayPut, for: .horizontal)
        label.postsFrameChangedNotifications = true
        return label
    }()

    // MARK: Surface Zoom

    /// Set to true if a surface is currently zoomed to show the reset zoom button.
    var surfaceIsZoomed: Bool = false {
        didSet {
            // Show/hide our reset zoom button depending on if we're zoomed.
            // We want to show it if we are zoomed.
            resetZoomTabButton.isHidden = !surfaceIsZoomed

            DispatchQueue.main.async {
                self.viewModel.isSurfaceZoomed = self.surfaceIsZoomed
            }
        }
    }

    private lazy var resetZoomTabButton: NSButton = generateResetZoomButton()

    private func generateResetZoomButton() -> NSButton {
        let button = NSButton()
        button.isHidden = true
        button.target = terminalController
        button.action = #selector(TerminalController.splitZoom(_:))
        button.isBordered = false
        button.allowsExpansionToolTips = true
        button.toolTip = "Reset Zoom"
        button.contentTintColor = isMainWindow ? .controlAccentColor : .secondaryLabelColor
        button.state = .on
        button.image = NSImage(named: "ResetZoom")
        button.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }

    // MARK: Title Text

    override var title: String {
        didSet {
            // Whenever we change the window title we must also update our
            // tab title if we're using custom fonts.
            tab.attributedTitle = attributedTitle
            /// We also needs to update this here, just in case
            /// the value is not what we want
            ///
            /// Check ``titlebarFont`` down below
            /// to see why we need to check `hasMoreThanOneTabs` here
            titlebarTextField?.usesSingleLineMode = !hasMoreThanOneTabs
        }
    }

    // Used to set the titlebar font.

    /// This is called by the controller when there is a need to reset the window appearance.
    func syncAppearance(_ surfaceConfig: Tako.SurfaceView.DerivedConfig) {
        syncWindowAppearance(surfaceConfig)
    }

    override func cancelOperation(_ sender: Any?) {
        if let tree = terminalController?.surfaceTree {
            for surface in tree {
                if OverlayStore.shared.overlay(for: surface.id) != nil {
                    OverlayStore.shared.closeOverlay(paneId: surface.id)
                    makeFirstResponder(surface)
                    return
                }
                if DiffReviewStore.shared.session(for: surface.id) != nil {
                    DiffReviewStore.shared.closeReview(paneId: surface.id)
                    makeFirstResponder(surface)
                    return
                }
            }
        }
        super.cancelOperation(sender)
    }

    deinit {
        if let observer = tabMenuObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

}
