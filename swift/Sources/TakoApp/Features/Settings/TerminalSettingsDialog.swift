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

/// In-terminal TUI settings card displaying scrollable keybindings, search filter,
/// and live keyboard shortcut detection matching the TakoTUI brand palette.
@MainActor
final class TerminalSettingsDialog: NSView, NSTextFieldDelegate {
    struct Style {
        var font: NSFont
        var boldFont: NSFont
        var background: NSColor
        var foreground: NSColor
        var accent: NSColor
        var accentEnd: NSColor
        var muted: NSColor

        static func from(_ theme: TerminalTheme?) -> Style {
            let baseFont = TakoTUI.font(theme)
            let bold = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
            return Style(
                font: baseFont,
                boldFont: bold,
                background: TakoTUI.ink,
                foreground: TakoTUI.text,
                accent: TakoTUI.rust,
                accentEnd: TakoTUI.ember,
                muted: TakoTUI.dim
            )
        }
    }

    let style: Style
    let configFile: KeybindConfigFile
    var allItems: [KeybindActionItem] = KeybindRegistry.allActions
    var filteredItems: [KeybindActionItem] = []
    var selectedIndex: Int = 0
    var scrollOffset: Int = 0
    var searchField: NSTextField?
    var isRecording: Bool = false
    var recordingHeldModifiers: NSEvent.ModifierFlags = []
    struct ConflictInfo {
        let targetItem: KeybindActionItem
        let conflictingItem: KeybindActionItem
        let trigger: String
    }
    var pendingConflict: ConflictInfo?
    var statusMessage: String?
    var buttons: [DialogButton] = []
    weak var previousResponder: NSResponder?

    var cellHeight: CGFloat { ceil(style.font.ascender - style.font.descender + style.font.leading) }
    var cellWidth: CGFloat { ("M" as NSString).size(withAttributes: [.font: style.font]).width }

    let columns: Int = 68
    let visibleRows: Int = 14
    var totalRows: Int { visibleRows + 9 }

    static func show(in window: NSWindow, theme: TerminalTheme? = nil, configPath: String? = nil) {
        if let existing = window.contentView?.subviews.first(where: { $0 is TerminalSettingsDialog }) {
            (existing as? TerminalSettingsDialog)?.withdraw()
            return
        }

        guard let content = window.contentView else { return }
        let resolvedPath = configPath
            ?? (NSApp.delegate as? AppDelegate)?.tako.activeConfigPath
            ?? ProcessInfo.processInfo.environment["TAKO_CONFIG_PATH"]

        let configFile = KeybindConfigFile(configPath: resolvedPath)
        configFile.reload()

        let dialog = TerminalSettingsDialog(style: .from(theme), configFile: configFile)
        dialog.frame = content.bounds
        dialog.autoresizingMask = [.width, .height]
        dialog.previousResponder = window.firstResponder

        content.addSubview(dialog, positioned: .above, relativeTo: nil)
        window.makeFirstResponder(dialog)
        dialog.needsLayout = true
    }

    init(style: Style, configFile: KeybindConfigFile? = nil) {
        self.style = style
        self.configFile = configFile ?? .shared
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = TakoTUI.deep.withAlphaComponent(0.65).cgColor

        filteredItems = allItems

        setupSearchField()
        setupButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var isWithdrawing: Bool = false

    private func setupSearchField() {
        let field = NSTextField()
        field.placeholderString = "Filter actions or shortcuts (type to search)…"
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = TakoTUI.field
        field.textColor = TakoTUI.bright
        field.font = style.font
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.delegate = self
        field.nextKeyView = self
        addSubview(field)
        self.searchField = field
        self.nextKeyView = field
    }

    private func setupButtons() {
        let recordChoice = TerminalDialogView.Choice(title: "Record (R)", kind: .primary)
        let resetChoice = TerminalDialogView.Choice(title: "Reset (D)", kind: .normal)
        let closeChoice = TerminalDialogView.Choice(title: "Close (Esc)", kind: .normal)

        buttons = [recordChoice, resetChoice, closeChoice].enumerated().map { index, choice in
            let btn = DialogButton(choice: choice, style: .init(
                font: style.font, background: style.background, foreground: style.foreground,
                accent: style.accent, accentEnd: style.accentEnd, muted: style.muted
            ))
            btn.target = self
            btn.action = #selector(buttonPressed(_:))
            btn.tag = index
            addSubview(btn)
            return btn
        }
    }

    @objc private func buttonPressed(_ sender: DialogButton) {
        switch sender.tag {
        case 0: startRecording()
        case 1: resetSelected()
        case 2: withdraw()
        default: break
        }
    }

    func withdraw() {
        guard !isWithdrawing else { return }
        isWithdrawing = true
        if let previous = previousResponder {
            window?.makeFirstResponder(previous)
        }
        removeFromSuperview()
    }

    override func resignFirstResponder() -> Bool {
        if isWithdrawing { return true }
        if let next = window?.firstResponder as? NSView, next.isDescendant(of: self) {
            return true
        }
        return false
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func cell(_ col: Int, _ row: Int) -> NSPoint {
        let left = floor((bounds.width / cellWidth - CGFloat(columns)) / 2) * cellWidth
        let top = max(floor((bounds.height / cellHeight - CGFloat(totalRows)) / 2), 0) * cellHeight
        return NSPoint(x: left + CGFloat(col) * cellWidth, y: top + CGFloat(row) * cellHeight)
    }

    var cardRect: NSRect {
        let origin = cell(0, 0)
        return NSRect(x: origin.x, y: origin.y, width: CGFloat(columns) * cellWidth, height: CGFloat(totalRows) * cellHeight)
    }

    override func layout() {
        super.layout()
        if let field = searchField {
            let origin = cell(3, 2)
            field.frame = NSRect(x: origin.x, y: origin.y, width: CGFloat(columns - 6) * cellWidth, height: cellHeight)
        }

        var col = columns - 3
        for button in buttons.reversed() {
            let width = button.title.count + 4
            col -= width
            let origin = cell(col, totalRows - 3)
            button.frame = NSRect(x: origin.x, y: origin.y, width: CGFloat(width) * cellWidth, height: cellHeight)
            col -= 1
        }
    }
}
