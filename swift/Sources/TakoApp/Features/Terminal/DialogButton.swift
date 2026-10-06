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

/// A dialog button drawn in cells, as a terminal UI draws one: the chosen
/// one a filled block -- red for a destructive action, Ember otherwise -- the
/// other on the field colour.
@MainActor
final class DialogButton: NSButton {
    private let style: TerminalDialogView.Style
    private let kind: TerminalDialogView.Choice.Kind
    var isChosen = false { didSet { needsDisplay = true } }
    var isConfirm: Bool { kind != .normal }

    init(choice: TerminalDialogView.Choice, style: TerminalDialogView.Style) {
        self.style = style
        self.kind = choice.kind
        super.init(frame: .zero)
        self.title = choice.title
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let font: NSFont
        let color: NSColor
        if isChosen {
            (kind == .destructive ? TakoTUI.danger : TakoTUI.ember).setFill()
            font = NSFontManager.shared.convert(style.font, toHaveTrait: .boldFontMask)
            color = kind == .destructive ? TakoTUI.bright : TakoTUI.deep
        } else {
            TakoTUI.field.setFill()
            font = style.font
            color = TakoTUI.text
        }
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let label = title as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                   withAttributes: attributes)
    }
}
