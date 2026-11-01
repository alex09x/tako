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
        cancelEditingColor()
        pendingConflict = nil
        let pt = convert(event.locationInWindow, from: nil)
        guard cardRect.contains(pt) else {
            // Modal: clicks on backdrop do not dismiss and do not pass through to terminal
            return
        }

        // Check Row 1 clicks for tab switching.
        let tabY = cell(0, 1).y
        if pt.y >= tabY && pt.y < tabY + cellHeight {
            let relCol = Int((pt.x - cell(0, 0).x) / cellWidth)
            if let entry = tabLayout.first(where: { relCol >= $0.column && relCol < $0.column + $0.label.count }) {
                switchTab(to: entry.tab)
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
        cancelEditingColor()
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
