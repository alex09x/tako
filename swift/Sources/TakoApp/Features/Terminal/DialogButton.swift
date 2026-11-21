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

/// A dialog button in the desktop style: the action is filled -- red for a
/// destructive one, Claw otherwise -- the safe one is plain; the one
/// Return would press wears a ring.
@MainActor
final class DialogButton: NSButton {
    private let style: TerminalDialogView.Style
    private let kind: TerminalDialogView.Choice.Kind
    var isChosen = false { didSet { needsDisplay = true } }
    var isConfirm: Bool { kind != .normal }
    var isDestructive: Bool { kind == .destructive }

    init(choice: TerminalDialogView.Choice, style: TerminalDialogView.Style) {
        self.style = style
        self.kind = choice.kind
        super.init(frame: .zero)
        self.title = choice.title
        setAccessibilityTitle(choice.title)
        setAccessibilityLabel(choice.title)
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // A desktop button: the action filled -- red for a destructive one,
        // Claw otherwise -- the safe one on the button colour with a hairline.
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 6, yRadius: 6)
        let font: NSFont
        let color: NSColor
        if kind == .normal {
            TerminalDialogView.Palette.button.setFill()
            shape.fill()
            TerminalDialogView.Palette.hairline.setStroke()
            shape.lineWidth = 1
            shape.stroke()
            font = TerminalDialogView.buttonFont
            color = TerminalDialogView.Palette.title
        } else {
            (kind == .destructive ? TakoTUI.danger : TakoTUI.claw).setFill()
            shape.fill()
            font = NSFont.systemFont(ofSize: TerminalDialogView.buttonFont.pointSize, weight: .semibold)
            color = kind == .destructive ? TakoTUI.bright : TakoTUI.deep
        }
        // The one Return presses wears a ring, whatever it is filled with.
        if isChosen {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            ring.lineWidth = 2
            TakoTUI.claw.withAlphaComponent(0.55).setStroke()
            ring.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let label = title as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                   withAttributes: attributes)
    }
}
