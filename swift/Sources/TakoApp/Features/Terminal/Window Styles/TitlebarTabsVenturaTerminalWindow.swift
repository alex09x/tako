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

/// Titlebar tabs for macOS 13 to 15.
class TitlebarTabsVenturaTerminalWindow: TerminalWindow {
    /// This is used to determine if certain elements should be drawn light or dark and should
    /// be updated whenever the window background color or surrounding elements changes.
    var isLightTheme: Bool = false

    lazy var titlebarColor: NSColor = backgroundColor {
        didSet {
            guard let titlebarContainer else { return }
            titlebarContainer.wantsLayer = true
            titlebarContainer.layer?.backgroundColor = titlebarColor.cgColor
        }
    }

    // false if all three traffic lights are missing/hidden, otherwise true
    var hasWindowButtons: Bool {
        // if standardWindowButton(.theButton) == nil, the button isn't there, so coalesce to true
        let closeIsHidden = standardWindowButton(.closeButton)?.isHiddenOrHasHiddenAncestor ?? true
        let miniaturizeIsHidden = standardWindowButton(.miniaturizeButton)?.isHiddenOrHasHiddenAncestor ?? true
        let zoomIsHidden = standardWindowButton(.zoomButton)?.isHiddenOrHasHiddenAncestor ?? true
        return !(closeIsHidden && miniaturizeIsHidden && zoomIsHidden)
    }

    // MARK: NSWindow

    override func awakeFromNib() {
        super.awakeFromNib()

        titlebarTabs = true

        // Set the background color of the window
        backgroundColor = derivedConfig.backgroundColor

        // This makes sure our titlebar renders correctly when there is a transparent background
        titlebarColor = derivedConfig.backgroundColor.withAlphaComponent(derivedConfig.backgroundOpacity)
    }

    // We only need to set this once, but need to do it after the window has been created in order
    // to determine if the theme is using a very dark background, in which case we don't want to
    // remove the effect view if the default tab bar is being used since the effect created in
    // `updateTabsForVeryDarkBackgrounds` creates a confusing visual design.
    private var effectViewIsHidden = false

    override func becomeKey() {
        // This is required because the removeTitlebarAccessoryViewController hook does not
        // catch the creation of a new window by "tearing off" a tab from a tabbed window.
        if let tabGroup = self.tabGroup, tabGroup.windows.count < 2 {
            resetCustomTabBarViews()
        }

        super.becomeKey()

        updateNewTabButtonOpacity()
        resetZoomToolbarButton.contentTintColor = .controlAccentColor
        tab.attributedTitle = attributedTitle
    }

    override func resignKey() {
        super.resignKey()

        updateNewTabButtonOpacity()
        resetZoomToolbarButton.contentTintColor = .tertiaryLabelColor
        tab.attributedTitle = attributedTitle
    }

	override func layoutIfNeeded() {
		super.layoutIfNeeded()

		guard titlebarTabs else { return }

		// We need to be aggressive with this, and it has to be done as well in `update`,
		// otherwise things can get out of sync and flickering can occur.
		updateTabsForVeryDarkBackgrounds()
	}

    override func update() {
        super.update()

        if titlebarTabs {
            updateTabsForVeryDarkBackgrounds()
            // This is called when we open, close, switch, and reorder tabs, at which point we determine if the
            // first tab in the tab bar is selected. If it is, we make the `windowButtonsBackdrop` color the same
            // as that of the active tab (i.e. the titlebar's background color), otherwise we make it the same
            // color as the background of unselected tabs.
            if let index = windowController?.window?.tabbedWindows?.firstIndex(of: self) {
                windowButtonsBackdrop?.isHighlighted = index == 0
            }
        }

		titlebarSeparatorStyle = tabbedWindows != nil && !titlebarTabs ? .line : .none
        if titlebarTabs {
            hideToolbarOverflowButton()
            hideTitleBarSeparators()
        }

		if !effectViewIsHidden {
			// By hiding the visual effect view, we allow the window's (or titlebar's in this case)
			// background color to show through. If we were to set `titlebarAppearsTransparent` to true
			// the selected tab would look fine, but the unselected ones and new tab button backgrounds
			// would be an opaque color. When the titlebar isn't transparent, however, the system applies
			// a compositing effect to the unselected tab backgrounds, which makes them blend with the
			// titlebar's/window's background.
			if let effectView = titlebarContainer?.descendants(
                withClassName: "NSVisualEffectView").first {
				effectView.isHidden = titlebarTabs || !titlebarTabs && !hasVeryDarkBackground
			}

			effectViewIsHidden = true
		}

        updateNewTabButtonOpacity()
        updateNewTabButtonImage()
    }

    override func updateConstraintsIfNeeded() {
        super.updateConstraintsIfNeeded()

        if titlebarTabs {
            hideToolbarOverflowButton()
            hideTitleBarSeparators()
        }
    }

    override func mergeAllWindows(_ sender: Any?) {
        super.mergeAllWindows(sender)

        if let controller = self.windowController as? TerminalController {
            // It takes an event loop cycle to merge all the windows so we set a
            // short timer to relabel the tabs.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { controller.relabelTabs() }
        }
    }

    // MARK: Appearance

    override func syncAppearance(_ surfaceConfig: Tako.SurfaceView.DerivedConfig) {
        super.syncAppearance(surfaceConfig)
        // override appearance based on the terminal's background color
        if let preferredBackgroundColor {
            appearance = (preferredBackgroundColor.isLightColor ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua))
        }

        // Update our window light/darkness based on our updated background color
        let themeChanged = isLightTheme != OSColor(surfaceConfig.backgroundColor).isLightColor
        isLightTheme = OSColor(surfaceConfig.backgroundColor).isLightColor

        // Update our titlebar color
        if let preferredBackgroundColor {
            titlebarColor = preferredBackgroundColor
        } else {
            titlebarColor = derivedConfig.backgroundColor.withAlphaComponent(derivedConfig.backgroundOpacity)
        }

        if isOpaque || themeChanged {
            // If there is transparency, calling this will make the titlebar opaque
            // so we only call this if we are opaque.
            updateTabBar()
        }
    }

    // MARK: Tab Bar Styling

    var hasVeryDarkBackground: Bool {
        backgroundColor.luminance < 0.05
    }

    var newTabButtonImageLayer: VibrantLayer?

    func updateTabBar() {
        newTabButtonImageLayer = nil
        effectViewIsHidden = false

        // We can only update titlebar tabs if there is a titlebar. Without the
        // styleMask check the app will crash.
        if titlebarTabs && styleMask.contains(.titled) {
            guard let tabBarAccessoryViewController = titlebarAccessoryViewControllers.first(where: { $0.identifier == Self.tabBarIdentifier}) else { return }
            tabBarAccessoryViewController.layoutAttribute = .right
            pushTabsToTitlebar(tabBarAccessoryViewController)
        }
    }

    // Since we are coloring the new tab button's image, it doesn't respond to the
    // window's key status changes in terms of becoming less prominent visually,
    // so we need to do it manually.

    /// Update: This method only add a vibrant overlay now,
    /// since the image itself supports light/dark tint,
    /// and system could restore it any time,
    /// altering it will only cause maintenance burden for us.
    ///
    /// And if we hide original image,
    /// ``updateNewTabButtonOpacity`` will not work
    ///
    /// ~~Color the new tab button's image to match the color of the tab title/keyboard shortcut labels,~~
	/// ~~just as it does in the stock tab bar.~~
    // MARK: - Split Zoom Button

    lazy var resetZoomToolbarButton: NSButton = generateResetZoomToolbarButton()

    // MARK: - Titlebar Font

    // Used to set the titlebar font.
    override var titlebarFont: NSFont? {
        didSet {
            guard let toolbar = toolbar as? TerminalToolbar else { return }
            toolbar.titleFont = titlebarFont ?? .titleBarFont(ofSize: NSFont.systemFontSize)
        }
    }

    // MARK: - Titlebar Tabs

    var windowButtonsBackdrop: WindowButtonsBackdropView?

    var windowDragHandle: WindowDragView?

    // Used by the window controller to enable/disable titlebar tabs.
    var titlebarTabs = false {
        didSet {
            self.titleVisibility = titlebarTabs ? .hidden : .visible
			if titlebarTabs {
				generateToolbar()
            } else {
                toolbar = nil
            }
        }
    }

    override var title: String {
        didSet {
            // Updating the title text as above automatically reveals the
            // native title view in macOS 15.0 and above. Since we're using
            // a custom view instead, we need to re-hide it.
            titleVisibility = .hidden
            if let toolbar = toolbar as? TerminalToolbar {
                toolbar.titleText = title
            }
        }
    }

    // We have to regenerate a toolbar when the titlebar tabs setting changes since our
    // custom toolbar conditionally generates the items based on this setting. I tried to
    // invalidate the toolbar items and force a refresh, but as far as I can tell that
    // isn't possible.
    // This is called by macOS for native tabbing in order to add the tab bar. We hook into
    // this, detect the tab bar being added, and override its behavior.
    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        let isTabBar = self.titlebarTabs && isTabBar(childViewController)

        if isTabBar {
            // Ensure it has the right layoutAttribute to force it next to our titlebar
            childViewController.layoutAttribute = .right

            // If we don't set titleVisibility to hidden here, the toolbar will display a
            // "collapsed items" indicator which interferes with the tab bar.
            titleVisibility = .hidden

            // Mark the controller for future reference so we can easily find it. Otherwise
            // the tab bar has no ID by default.
            childViewController.identifier = Self.tabBarIdentifier
        }

        super.addTitlebarAccessoryViewController(childViewController)

        if isTabBar {
            pushTabsToTitlebar(childViewController)
        }
    }

    override func removeTitlebarAccessoryViewController(at index: Int) {
        let isTabBar = titlebarAccessoryViewControllers[index].identifier == Self.tabBarIdentifier
        super.removeTitlebarAccessoryViewController(at: index)
        if isTabBar {
            resetCustomTabBarViews()
        }
    }

    // To be called immediately after the tab bar is disabled.
}
