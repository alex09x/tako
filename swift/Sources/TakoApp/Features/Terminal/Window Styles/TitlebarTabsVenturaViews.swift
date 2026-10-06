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

// Passes mouseDown events from this view to window.performDrag so that you can drag the window by it.
class WindowDragView: NSView {
    override public func mouseDown(with event: NSEvent) {
        // Drag the window for single left clicks, double clicks should bypass the drag handle.
        if event.type == .leftMouseDown && event.clickCount == 1 {
            window?.performDrag(with: event)
            NSCursor.closedHand.set()
        } else {
            super.mouseDown(with: event)
        }
    }

    override public func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        window?.disableCursorRects()
        NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        window?.enableCursorRects()
        NSCursor.arrow.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}


// A view that matches the color of selected and unselected tabs in the adjacent tab bar.
class WindowButtonsBackdropView: NSView {
    // This must be weak because the window has this view. Otherwise
    // a retain cycle occurs.
	private weak var terminalWindow: TitlebarTabsVenturaTerminalWindow?
    private var isLightTheme: Bool {
        // using up-to-date value from hosting window directly
        terminalWindow?.isLightTheme ?? false
    }
    private let overlayLayer = VibrantLayer()

    var isHighlighted: Bool = true {
        didSet {
            guard let terminalWindow else { return }

            if isLightTheme {
                overlayLayer.isHidden = isHighlighted
                layer?.backgroundColor = .clear
            } else {
				let systemOverlayColor = NSColor(cgColor: CGColor(genericGrayGamma2_2Gray: 0.0, alpha: 0.45))!
				let titlebarBackgroundColor = terminalWindow.titlebarColor.blended(withFraction: 1, of: systemOverlayColor)

				let highlightedColor = terminalWindow.hasVeryDarkBackground ? terminalWindow.backgroundColor : .clear
				let backgroundColor = terminalWindow.hasVeryDarkBackground ? titlebarBackgroundColor : systemOverlayColor

                overlayLayer.isHidden = true
				layer?.backgroundColor = isHighlighted ? highlightedColor?.cgColor : backgroundColor?.cgColor
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    init(window: TitlebarTabsVenturaTerminalWindow) {
		self.terminalWindow = window

        super.init(frame: .zero)

        wantsLayer = true

        overlayLayer.frame = layer!.bounds
        overlayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        overlayLayer.backgroundColor = CGColor(genericGrayGamma2_2Gray: 0.95, alpha: 1)

        layer?.addSublayer(overlayLayer)
    }
}


/// A label that expands to fit whatever text you put in it and horizontally centers itself in the current window.
class CenteredDynamicLabel: NSTextField {
    override func viewDidMoveToSuperview() {
        // Configure the text field
        isEditable = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        lineBreakMode = .byTruncatingTail
        cell?.truncatesLastVisibleLine = true

        // Use Auto Layout
        translatesAutoresizingMaskIntoConstraints = false

        // Set content hugging and compression resistance priorities
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    /// Click through, so we can double click here to enlarge current window
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    // Vertically center the text
    override func draw(_ dirtyRect: NSRect) {
        guard let attributedString = self.attributedStringValue.mutableCopy() as? NSMutableAttributedString else {
            super.draw(dirtyRect)
            return
        }

        let textSize = attributedString.size()

        let yOffset = (self.bounds.height - textSize.height) / 2 - 1 // -1 to center it better

        let centeredRect = NSRect(x: self.bounds.origin.x, y: self.bounds.origin.y + yOffset,
                                  width: self.bounds.width, height: textSize.height)

        attributedString.draw(in: centeredRect)
    }
}

extension NSToolbarItem.Identifier {
    static let resetZoom = NSToolbarItem.Identifier("ResetZoom")
    static let titleText = NSToolbarItem.Identifier("TitleText")
}
