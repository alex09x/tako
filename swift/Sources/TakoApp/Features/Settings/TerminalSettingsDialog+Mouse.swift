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

extension TerminalSettingsDialog {
    // MARK: - Mouse Events (Modal containment)

    override func mouseDown(with event: NSEvent) {
        pendingConflict = nil
        let pt = convert(event.locationInWindow, from: nil)
        guard cardRect.contains(pt) else {
            // Modal: clicks on backdrop do not dismiss and do not pass through to terminal
            return
        }

        // Check Row 1 clicks for tab switching: [1] Keybindings, [2] Terminal Settings
        let tabY = cell(0, 1).y
        if pt.y >= tabY && pt.y < tabY + cellHeight {
            let tab1Title = " [1] Keybindings "
            let tab1Col = 3
            let tab2Col = tab1Col + tab1Title.count + 2
            let tab2Title = " [2] Terminal Settings "
            let relCol = Int((pt.x - cell(0, 0).x) / cellWidth)
            if relCol >= tab1Col && relCol < tab1Col + tab1Title.count {
                switchTab(to: .keybindings)
                isTabBarFocused = true
                window?.makeFirstResponder(self)
                needsDisplay = true
                return
            } else if relCol >= tab2Col && relCol < tab2Col + tab2Title.count {
                switchTab(to: .terminalSettings)
                isTabBarFocused = true
                window?.makeFirstResponder(self)
                needsDisplay = true
                return
            }
        }

        let startY = cell(0, 5).y
        let rowHeight = cellHeight
        if pt.y >= startY && pt.y < startY + CGFloat(visibleRows) * rowHeight {
            let clickedVisible = Int((pt.y - startY) / rowHeight)
            isTabBarFocused = false
            window?.makeFirstResponder(self)
            if activeTab == .keybindings {
                let targetIdx = scrollOffset + clickedVisible
                if targetIdx < filteredItems.count {
                    selectedIndex = targetIdx
                    if event.clickCount == 2 {
                        startRecording()
                    } else {
                        updateAccessibilityState()
                        needsDisplay = true
                    }
                }
            } else {
                let targetIdx = scrollSettingOffset + clickedVisible
                if targetIdx < filteredSettingItems.count {
                    selectedSettingIndex = targetIdx
                    let relCol = Int((pt.x - cell(0, 0).x) / cellWidth)
                    let isValueColumn = relCol >= 44

                    if isValueColumn || event.clickCount == 2 {
                        toggleOrCycleSelectedSetting()
                    } else {
                        updateAccessibilityState()
                        needsDisplay = true
                    }
                }
            }
        }
    }

    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        if activeTab == .keybindings {
            if delta > 0 {
                scrollOffset = max(scrollOffset - 1, 0)
            } else if delta < 0 {
                scrollOffset = min(scrollOffset + 1, max(filteredItems.count - visibleRows, 0))
            }
        } else {
            if delta > 0 {
                scrollSettingOffset = max(scrollSettingOffset - 1, 0)
            } else if delta < 0 {
                scrollSettingOffset = min(scrollSettingOffset + 1, max(filteredSettingItems.count - visibleRows, 0))
            }
        }
        needsDisplay = true
    }
}
