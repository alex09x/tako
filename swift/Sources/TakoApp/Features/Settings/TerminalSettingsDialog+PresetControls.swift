/*
 * tako — Theme preset editor controls
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

extension TerminalSettingsDialog: NSTextViewDelegate {
    func setupPresetControls() {
        guard let editor = presetEditor else {
            let labels = ["New Theme (⌘N)", "Edit / Copy (⌘E)"]
            presetActionButtons = labels.enumerated().map { index, title in
                let button = DialogButton(choice: .init(title: title, kind: .normal), style: .init(
                    font: style.font, background: style.background, foreground: style.foreground,
                    accent: style.accent, accentEnd: style.accentEnd, muted: style.muted))
                button.target = self
                button.action = #selector(presetActionPressed(_:))
                button.tag = index
                button.setAccessibilityIdentifier(index == 0 ? "ThemePresetNewButton" : "ThemePresetEditButton")
                addSubview(button)
                return button
            }
            return
        }
        let name = NSTextField(string: editor.name)
        name.font = style.font
        name.textColor = TakoTUI.text
        name.backgroundColor = TakoTUI.field
        name.isBordered = false
        name.focusRingType = .none
        name.usesSingleLineMode = true
        name.delegate = self
        name.setAccessibilityIdentifier("ThemePresetName")
        name.setAccessibilityLabel("Theme name")
        addSubview(name)
        presetNameField = name

        let text = NSTextView()
        text.string = editor.config
        text.font = style.font
        text.textColor = TakoTUI.text
        text.backgroundColor = TakoTUI.field
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 8, height: 6)
        text.delegate = self
        text.setAccessibilityIdentifier("ThemePresetConfiguration")
        text.setAccessibilityLabel("Complete theme configuration")
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.documentView = text
        addSubview(scroll)
        presetConfigScroll = scroll
        presetConfigText = text
    }

    func layoutPresetControls() {
        if let field = presetNameField {
            let origin = cell(10, 3)
            field.frame = NSRect(x: origin.x, y: origin.y, width: CGFloat(columns - 14) * cellWidth, height: cellHeight)
        }
        if let scroll = presetConfigScroll {
            let origin = cell(3, 5)
            scroll.frame = NSRect(x: origin.x, y: origin.y, width: CGFloat(columns - 6) * cellWidth,
                                  height: CGFloat(visibleRows) * cellHeight)
            presetConfigText?.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, presetConfigText?.frame.height ?? 0)))
        }
        var column = 3
        for button in presetActionButtons {
            let origin = cell(column, 3)
            let width = button.title.count + 4
            button.frame = NSRect(x: origin.x, y: origin.y, width: CGFloat(width) * cellWidth, height: cellHeight)
            column += width + 2
        }
    }

    func updatePresetControlVisibility() {
        presetActionButtons.forEach { $0.isHidden = activeTab != .themes }
        let raw = presetEditor != nil && activeTab == .themeConfig
        presetConfigScroll?.isHidden = !raw
        if raw { presetConfigText?.string = presetEditor?.config ?? "" }
        searchField?.isHidden = raw
        needsLayout = true
    }

    func updatePresetEditorControls() {
        buttons[0].title = "Preview (⌘P)"
        buttons[1].title = "Save (⌘S)"
        buttons[2].title = "Cancel (Esc)"
        for (button, id) in zip(buttons, ["ThemePresetPreviewButton", "ThemePresetSaveButton", "ThemePresetCancelButton"]) {
            button.setAccessibilityIdentifier(id)
        }
        needsLayout = true
    }

    @objc func presetActionPressed(_ sender: DialogButton) { beginPresetEditor(createNew: sender.tag == 0) }

    func handlePresetKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if presetEditor != nil {
            if key == "s" { savePreset(); return true }
            if key == "p" { previewPreset(); return true }
        } else if activeTab == .themes {
            if key == "n" { beginPresetEditor(createNew: true); return true }
            if key == "e" { beginPresetEditor(createNew: false); return true }
        }
        return false
    }

    func handlePresetEditorButton(_ tag: Int) -> Bool {
        guard presetEditor != nil else { return false }
        switch tag {
        case 0: previewPreset()
        case 1: savePreset()
        default: withdraw()
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard let text = presetConfigText, (notification.object as? NSTextView) === text else { return }
        presetEditor?.config = text.string
        statusMessage = nil
        needsDisplay = true
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            withdraw(); return true
        }
        return false
    }
}
