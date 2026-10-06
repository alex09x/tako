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

extension TitlebarTabsVenturaTerminalWindow {
    func updateNewTabButtonOpacity() {
        guard let newTabButton: NSButton = titlebarContainer?.firstDescendant(withClassName: "NSTabBarNewTabButton") as? NSButton else { return }
        guard let newTabButtonImageView = newTabButton.firstDescendant(withClassName: "NSImageView") as? NSImageView else { return }

        newTabButtonImageView.alphaValue = isKeyWindow ? 1 : 0.5
    }

	func updateNewTabButtonImage() {
		guard let newTabButton: NSButton = titlebarContainer?.firstDescendant(withClassName: "NSTabBarNewTabButton") as? NSButton else { return }
        guard let newTabButtonImageView = newTabButton.firstDescendant(withClassName: "NSImageView") as? NSImageView else { return }
        guard let newTabButtonImage = newTabButtonImageView.image else { return }

        let imageLayer = newTabButtonImageLayer ?? VibrantLayer(forAppearance: isLightTheme ? .light : .dark)!
        imageLayer.frame = NSRect(origin: NSPoint(x: newTabButton.bounds.midX - newTabButtonImage.size.width/2, y: newTabButton.bounds.midY - newTabButtonImage.size.height/2), size: newTabButtonImage.size)
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.opacity = 0.5

        newTabButtonImageLayer = imageLayer

        newTabButton.layer?.sublayers?.first(where: { $0.className == "VibrantLayer" })?.removeFromSuperlayer()
        newTabButton.layer?.addSublayer(newTabButtonImageLayer!)
	}

	func updateTabsForVeryDarkBackgrounds() {
		guard hasVeryDarkBackground else { return }
        guard let titlebarContainer else { return }

		if let tabGroup = tabGroup, tabGroup.isTabBarVisible {
			guard let activeTabBackgroundView = titlebarContainer.firstDescendant(withClassName: "NSTabButton")?.superview?.subviews.last?.firstDescendant(withID: "_backgroundView")
			else { return }

			activeTabBackgroundView.layer?.backgroundColor = titlebarColor.cgColor
			titlebarContainer.layer?.backgroundColor = titlebarColor.highlight(withLevel: 0.14)?.cgColor
		} else {
			titlebarContainer.layer?.backgroundColor = titlebarColor.cgColor
		}
	}

	func generateResetZoomToolbarButton() -> NSButton {
		let button = NSButton()
		button.target = nil
		button.action = #selector(TerminalController.splitZoom(_:))
		button.isBordered = false
		button.allowsExpansionToolTips = true
		button.toolTip = "Reset Zoom"
		button.contentTintColor = .controlAccentColor
		button.state = .on
		button.image = NSImage(named: "ResetZoom")
		button.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
		button.translatesAutoresizingMaskIntoConstraints = false
		button.widthAnchor.constraint(equalToConstant: 20).isActive = true
		button.heightAnchor.constraint(equalToConstant: 20).isActive = true

		return button
	}

    func generateToolbar() {
        let terminalToolbar = TerminalToolbar(identifier: "Toolbar")

        toolbar = terminalToolbar
        toolbarStyle = .unifiedCompact
        if let resetZoomItem = terminalToolbar.items.first(where: { $0.itemIdentifier == .resetZoom }) {
            resetZoomItem.view = resetZoomToolbarButton
            resetZoomItem.view!.removeConstraints(resetZoomItem.view!.constraints)
            resetZoomItem.view!.widthAnchor.constraint(equalToConstant: 22).isActive = true
            resetZoomItem.view!.heightAnchor.constraint(equalToConstant: 20).isActive = true
        }
    }

    // For titlebar tabs, we want to hide the separator view so that we get rid
    // of an aesthetically unpleasing shadow.
    func hideTitleBarSeparators() {
        guard let titlebarContainer else { return }
        for v in titlebarContainer.descendants(withClassName: "NSTitlebarSeparatorView") {
            v.isHidden = true
        }
    }

    // HACK: hide the "collapsed items" marker from the toolbar if it's present.
    // idk why it appears in macOS 15.0+ but it does... so... make it go away. (sigh)
    func hideToolbarOverflowButton() {
        guard let windowButtonsBackdrop = windowButtonsBackdrop else { return }
        guard let titlebarView = windowButtonsBackdrop.superview else { return }
        guard titlebarView.className == "NSTitlebarView" else { return }
        guard let toolbarView = titlebarView.subviews.first(where: {
            $0.className == "NSToolbarView"
        }) else { return }

        toolbarView.subviews.first(where: { $0.className == "NSToolbarClippedItemsIndicatorViewer" })?.isHidden = true
    }

    func resetCustomTabBarViews() {
        // Hide the window buttons backdrop.
        windowButtonsBackdrop?.isHidden = true

        // Hide the window drag handle.
        windowDragHandle?.isHidden = true

        // Re-enable the main toolbar title
        if let toolbar = toolbar as? TerminalToolbar {
            toolbar.titleIsHidden = false
        }
    }

    func pushTabsToTitlebar(_ tabBarController: NSTitlebarAccessoryViewController) {
        // We need a toolbar as a target for our titlebar tabs.
        if toolbar == nil {
            generateToolbar()
        }

        // The main title conflicts with titlebar tabs, so hide it
        if let toolbar = toolbar as? TerminalToolbar {
            toolbar.titleIsHidden = true
        }

        // HACK: wait a tick before doing anything, to avoid edge cases during startup... :/
        // If we don't do this then on launch windows with restored state with tabs will end
        // up with messed up tab bars that don't show all tabs.
        DispatchQueue.main.async { [weak self] in
            let accessoryView = tabBarController.view
            guard let accessoryClipView = accessoryView.superview else { return }
            guard let titlebarView = accessoryClipView.superview else { return }
            guard titlebarView.className == "NSTitlebarView" else { return }
            guard let toolbarView = titlebarView.subviews.first(where: {
                $0.className == "NSToolbarView"
            }) else { return }

            self?.addWindowButtonsBackdrop(titlebarView: titlebarView, toolbarView: toolbarView)
            guard let windowButtonsBackdrop = self?.windowButtonsBackdrop else { return }

            self?.addWindowDragHandle(titlebarView: titlebarView, toolbarView: toolbarView)

            accessoryClipView.translatesAutoresizingMaskIntoConstraints = false
            accessoryClipView.leftAnchor.constraint(equalTo: windowButtonsBackdrop.rightAnchor).isActive = true
            accessoryClipView.rightAnchor.constraint(equalTo: toolbarView.rightAnchor).isActive = true
            accessoryClipView.topAnchor.constraint(equalTo: toolbarView.topAnchor).isActive = true
            accessoryClipView.heightAnchor.constraint(equalTo: toolbarView.heightAnchor).isActive = true
            accessoryClipView.needsLayout = true

            accessoryView.translatesAutoresizingMaskIntoConstraints = false
            accessoryView.leftAnchor.constraint(equalTo: accessoryClipView.leftAnchor).isActive = true
            accessoryView.rightAnchor.constraint(equalTo: accessoryClipView.rightAnchor).isActive = true
            accessoryView.topAnchor.constraint(equalTo: accessoryClipView.topAnchor).isActive = true
            accessoryView.heightAnchor.constraint(equalTo: accessoryClipView.heightAnchor).isActive = true
            accessoryView.needsLayout = true

            self?.hideToolbarOverflowButton()
            self?.hideTitleBarSeparators()
        }
    }

    func addWindowButtonsBackdrop(titlebarView: NSView, toolbarView: NSView) {
        guard windowButtonsBackdrop?.superview != titlebarView else {
            /// replacing existing backdrop aggressively
            /// may cause incorrect hierarchy
            ///
            /// because multiple windows are adding this around the 'same time'
            return
        }
        windowButtonsBackdrop?.removeFromSuperview()
        windowButtonsBackdrop = nil

        let view = WindowButtonsBackdropView(window: self)
        view.identifier = NSUserInterfaceItemIdentifier("_windowButtonsBackdrop")
        titlebarView.addSubview(view)

        view.translatesAutoresizingMaskIntoConstraints = false
        view.leftAnchor.constraint(equalTo: toolbarView.leftAnchor).isActive = true
        view.rightAnchor.constraint(equalTo: toolbarView.leftAnchor, constant: hasWindowButtons ? 78 : 0).isActive = true
        view.topAnchor.constraint(equalTo: toolbarView.topAnchor).isActive = true
        view.heightAnchor.constraint(equalTo: toolbarView.heightAnchor).isActive = true

        windowButtonsBackdrop = view
    }

    func addWindowDragHandle(titlebarView: NSView, toolbarView: NSView) {
        // If we already made the view, just make sure it's unhidden and correctly placed as a subview.
        guard windowDragHandle?.superview != titlebarView.superview else {
            // similar to `addWindowButtonsBackdrop`
            return
        }
        windowDragHandle?.removeFromSuperview()

        let view = WindowDragView()
        view.identifier = NSUserInterfaceItemIdentifier("_windowDragHandle")
        titlebarView.superview?.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.leftAnchor.constraint(equalTo: toolbarView.leftAnchor).isActive = true
        view.rightAnchor.constraint(equalTo: toolbarView.rightAnchor).isActive = true
        view.topAnchor.constraint(equalTo: toolbarView.topAnchor).isActive = true
        view.bottomAnchor.constraint(equalTo: toolbarView.topAnchor, constant: 12).isActive = true

        windowDragHandle = view
    }

}
