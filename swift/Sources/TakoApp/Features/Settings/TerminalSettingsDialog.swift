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

    public enum SettingsTab: Int, CaseIterable, Sendable {
        case keybindings = 0
        case terminalSettings = 1
        case themes = 2
        case fonts = 3
        case fontSize = 4

        public var title: String {
            switch self {
            case .keybindings: return "Keybindings"
            case .terminalSettings: return "Terminal Settings"
            case .themes: return "Themes"
            case .fonts: return "Fonts"
            case .fontSize: return "Font Size"
            }
        }
    }

    let style: Style
    let configFile: KeybindConfigFile
    let scopedAppearance: ScopedAppearanceContext?
    var activeTab: SettingsTab = .keybindings
    var isTabBarFocused: Bool = false

    // Keybindings state
    var allItems: [KeybindActionItem] = KeybindRegistry.allActions
    var filteredItems: [KeybindActionItem] = []
    var selectedIndex: Int = 0
    var scrollOffset: Int = 0

    // Terminal Settings state
    var allSettingItems: [TerminalSettingItem] = TerminalSettingRegistry.allSettings
    var filteredSettingItems: [TerminalSettingItem] = []
    var selectedSettingIndex: Int = 0
    var scrollSettingOffset: Int = 0
    var fontFamilies: [String] = []
    var themePreviews: [String: TerminalTheme] = [:]
    var themeWarning: String?

    var searchField: NSTextField?
    var colorEditField: NSTextField?
    var colorEditItem: TerminalSettingItem?
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

    static func show(
        in window: NSWindow,
        theme: TerminalTheme? = nil,
        configPath: String? = nil,
        tab: SettingsTab = .keybindings,
        appearance: ScopedAppearanceContext? = nil
    ) {
        if let existing = window.contentView?.subviews.first(where: { $0 is TerminalSettingsDialog }) {
            let dialog = existing as? TerminalSettingsDialog
            if dialog?.scopedAppearance?.scope != appearance?.scope {
                dialog?.withdraw()
            } else if dialog?.activeTab != tab {
                dialog?.switchTab(to: tab)
                return
            } else {
                dialog?.withdraw()
                return
            }
        }

        guard let content = window.contentView else { return }
        let resolvedPath = configPath
            ?? (NSApp.delegate as? AppDelegate)?.tako.activeConfigPath
            ?? ProcessInfo.processInfo.environment["TAKO_CONFIG_PATH"]

        let configFile = KeybindConfigFile(configPath: resolvedPath)
        configFile.reload()

        let dialog = TerminalSettingsDialog(style: .from(theme), configFile: configFile, initialTab: tab,
                                            appearance: appearance)
        dialog.frame = content.bounds
        dialog.autoresizingMask = [.width, .height]
        dialog.previousResponder = window.firstResponder

        content.addSubview(dialog, positioned: .above, relativeTo: nil)
        window.makeFirstResponder(dialog)
        dialog.needsLayout = true
    }

    init(style: Style, configFile: KeybindConfigFile? = nil, initialTab: SettingsTab = .keybindings,
         appearance: ScopedAppearanceContext? = nil) {
        self.style = style
        self.configFile = configFile ?? .shared
        self.scopedAppearance = appearance
        self.activeTab = appearance != nil && initialTab.rawValue < 2 ? .themes : initialTab
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = TakoTUI.deep.withAlphaComponent(0.65).cgColor

        filteredItems = allItems
        filteredSettingItems = allSettingItems

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("TerminalSettingsDialog")
        setAccessibilityLabel(settingsTitle)
        setAccessibilityTitle(settingsTitle)

        setupSearchField()
        setupButtons()
        updateButtonsForActiveTab()
        filterItems("")
        updateAccessibilityState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    var isWithdrawing: Bool = false

    private func setupSearchField() {
        let field = NSTextField()
        field.placeholderString = "Filter actions, settings, or shortcuts (type to search)…"
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
        let primaryChoice = TerminalDialogView.Choice(
            title: activeTab == .keybindings ? "Record (R)" : "Change (Space)",
            kind: .primary
        )
        let resetChoice = TerminalDialogView.Choice(title: "Reset (D)", kind: .normal)
        let closeChoice = TerminalDialogView.Choice(title: "Close (Esc)", kind: .normal)

        buttons = [primaryChoice, resetChoice, closeChoice].enumerated().map { index, choice in
            let btn = DialogButton(choice: choice, style: .init(
                font: style.font, background: style.background, foreground: style.foreground,
                accent: style.accent, accentEnd: style.accentEnd, muted: style.muted
            ))
            btn.target = self
            btn.action = #selector(buttonPressed(_:))
            btn.tag = index
            switch index {
            case 0: btn.setAccessibilityIdentifier("SettingsPrimaryActionButton")
            case 1: btn.setAccessibilityIdentifier("SettingsResetButton")
            case 2: btn.setAccessibilityIdentifier("SettingsCloseButton")
            default: break
            }
            addSubview(btn)
            return btn
        }
    }

    func updateButtonsForActiveTab() {
        guard buttons.count >= 3 else { return }
        if activeTab == .keybindings {
            buttons[0].title = "Record (R)"
            buttons[0].setAccessibilityIdentifier("SettingsRecordButton")
        } else {
            buttons[0].title = "Change (Space)"
            buttons[0].setAccessibilityIdentifier("SettingsChangeButton")
        }
        needsLayout = true
        needsDisplay = true
    }

    @objc private func buttonPressed(_ sender: DialogButton) {
        switch sender.tag {
        case 0:
            if activeTab == .keybindings {
                startRecording()
            } else {
                toggleOrCycleSelectedSetting()
            }
        case 1:
            if activeTab == .keybindings {
                resetSelected()
            } else {
                resetSelectedSetting()
            }
        case 2:
            withdraw()
        default: break
        }
    }

    func toggleOrCycleSelectedSetting(reverse: Bool = false) {
        if colorEditField != nil { saveEditedColor(); return }
        guard selectedSettingIndex < filteredSettingItems.count else { return }
        let item = filteredSettingItems[selectedSettingIndex]
        if item.category == TerminalAppearanceCatalog.themeCategory || item.category == TerminalAppearanceCatalog.fontCategory {
            applyAppearanceChoice(item)
            return
        }
        if case .color = item.type { beginEditingColor(item); return }
        let current = effectiveSettingValue(for: item)
        let next: String
        if activeTab == .fontSize, item.id == "font-size" {
            let currentSize = Double(current).flatMap { $0.isFinite ? $0 : nil } ?? 13
            let adjusted = min(72, max(6, currentSize + (reverse ? -1 : 1)))
            next = adjusted.rounded() == adjusted ? String(Int(adjusted)) : String(adjusted)
        } else {
            next = reverse ? item.type.previousValue(current: current) : item.type.nextValue(current: current)
        }
        if scopedAppearance == nil && next == item.type.defaultStringValue {
            if removeSettingValue(for: item) {
                statusMessage = "Default: \(item.id) = \(next)"
                setAccessibilityValue("setting_reset_success: \(item.id)")
            } else {
                statusMessage = "Error: Failed to reset \(item.id) in config file."
                setAccessibilityValue("setting_write_error: \(item.id)")
            }
        } else {
            if setSettingValue(next, for: item) {
                statusMessage = "Custom: \(item.id) = \(next)"
                setAccessibilityValue("setting_custom_success: \(item.id)")
            } else {
                statusMessage = scopedAppearance?.writeError ?? "Error: Failed to write \(item.id) to config file."
                setAccessibilityValue("setting_write_error: \(item.id)")
            }
        }
        needsDisplay = true
    }

    func resetSelectedSetting() {
        cancelEditingColor()
        guard selectedSettingIndex < filteredSettingItems.count else { return }
        let item = filteredSettingItems[selectedSettingIndex]
        let wasCustom = storedSettingValue(for: item) != nil
        if removeSettingValue(for: item) {
            if item.id == "theme" { themeWarning = nil }
            Tako.TabBarController.refreshAll()
            if wasCustom {
                statusMessage = "\(scopedAppearance == nil ? "Reset to default" : "Inherit"): \(item.id)"
            } else {
                statusMessage = "\(item.id) is already at default."
            }
            setAccessibilityValue("setting_reset_success: \(item.id)")
        } else {
            statusMessage = scopedAppearance?.writeError ?? "Error: Failed to reset \(item.id) in config file."
            setAccessibilityValue("setting_reset_error: \(item.id)")
        }
        needsDisplay = true
    }

    func withdraw() {
        cancelEditingColor()
        guard !isWithdrawing else { return }
        isWithdrawing = true
        setAccessibilityValue("closed")
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
        layoutColorEditor()
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
