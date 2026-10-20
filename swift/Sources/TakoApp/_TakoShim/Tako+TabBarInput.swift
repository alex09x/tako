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

extension Tako.TabBarView {
    // MARK: - Input

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    /// Full-height hit-test for tabs across the titlebar row so clicks and drags
    /// in the upper pixels don't fall through to native window dragging.
    func hitTab(at point: CGPoint) -> Tab? {
        guard showsStrip else { return nil }
        guard point.x >= effectiveFirstTabX && point.x < bounds.width - buttonsReservedWidth else { return nil }
        guard point.y >= 0 && point.y <= bounds.height else { return nil }
        if tabs.isEmpty || tabs.count != windows.count {
            layoutTabs()
        }
        return tabs.first { $0.frame.minX <= point.x && point.x <= $0.frame.maxX }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Do NOT call layoutTabs() here: it calls NSString.sizeWithAttributes
        // which crashes in CoreText when invoked outside a draw pass
        // (SIGABRT in TAttributes::ApplyFont, seen in TakoCore-2026-08-06*.ips).
        // The tabs array is kept current by draw(), which is always called
        // before user interaction reaches us.
        let previousTab = hovered
        let previousPlus = plusHovered
        let previousSplit = splitHovered
        let previousInfo = infoHovered
        let previousWorkspace = workspaceHovered
        workspaceHovered = showsWorkspacePill && workspacePillRect.contains(point)
        hovered = hitTab(at: point)?.index
        hoveredClose = hovered.map { closeRect(of: tabs[$0]).contains(point) } ?? false
        plusHovered = plusRect.contains(point)
        splitHovered = splitRect.contains(point)
        infoHovered = infoRect.contains(point)

        if workspaceHovered {
            let ws = WorkspaceStore.shared.activeWorkspace
            let count = WorkspaceStore.shared.attentionCount(for: ws)
            toolTip = "Project Workspace: \(ws.name)\(count > 0 ? " (\(count) needing attention)" : "") — Click to switch"
        } else if infoHovered {
            let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            toolTip = v.isEmpty ? "About Tako & Settings" : "About Tako & Settings (v\(v))"
        } else if splitHovered {
            toolTip = "Split Terminal Right (⌘D)"
        } else if plusHovered {
            toolTip = "New Tab (⌘T)"
        } else {
            toolTip = nil
        }

        if hovered != previousTab || plusHovered != previousPlus || splitHovered != previousSplit || infoHovered != previousInfo || workspaceHovered != previousWorkspace {
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        plusHovered = false
        splitHovered = false
        infoHovered = false
        workspaceHovered = false
        toolTip = nil
        needsDisplay = true
    }

    /// The close button's hit area is larger than the glyph.
    func closeRect(of tab: Tab) -> CGRect {
        if effectiveTabStyle == .pill {
            let rect = pillRect(for: tab)
            guard rect.width >= Metrics.pillCloseMinWidth else { return .null }
            return CGRect(
                x: rect.maxX - 8 - 10 - 5,
                y: rect.midY - 10,
                width: 20,
                height: 20
            )
        }
        guard tab.frame.width >= Metrics.compactTabWidth else { return .null }
        let inset = (Metrics.closeHitSize - Metrics.closeSize) / 2
        return CGRect(x: tab.frame.maxX - Metrics.tabPaddingRight - Metrics.closeSize - inset,
                      y: tab.frame.midY - Metrics.closeHitSize / 2,
                      width: Metrics.closeHitSize, height: Metrics.closeHitSize)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Same as mouseMoved: use the cached tabs from the last draw() pass.
        if showsWorkspacePill && workspacePillRect.contains(point) {
            showWorkspaceMenu(at: point)
            return
        }
        if infoRect.contains(point) {
            AboutNotice.show(in: self.window, theme: (NSApp.delegate as? AppDelegate)?.tako.config.theme)
            NSApp.sendAction(#selector(AppDelegate.showAbout(_:)), to: nil, from: self)
            return
        }
        if plusRect.contains(point) {
            NSApp.sendAction(#selector(TerminalController.newTab(_:)), to: nil, from: self)
            return
        }
        if splitRect.contains(point) {
            NSApp.sendAction(#selector(BaseTerminalController.splitRight(_:)), to: nil, from: self)
            return
        }
        guard let tab = hitTab(at: point) else {
            // Empty bar: drag the window, or zoom it on a double click.
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.isMovable = true
                window?.performDrag(with: event)
                window?.isMovable = false
            }
            return
        }
        if closeRect(of: tab).contains(point) {
            let controller = (tab.window.windowController as? TerminalController)
                ?? (tab.window.delegate as? TerminalController)
            if let controller {
                if controller.surfaceTree.contains(where: { $0.needsConfirmClose }) {
                    group?.select(tab.window)
                }
                controller.closeTab(self)
            } else {
                tab.window.performClose(nil)
            }
        } else {
            group?.select(tab.window)
            Tako.TabBarController.setDragState(in: group, draggedWindow: tab.window, index: tab.index, start: point, isDragging: false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let fromIndex = draggingTabIndex, let dragStart = dragStartPoint, let group else {
            super.mouseDragged(with: event)
            return
        }
        if tabs.isEmpty || tabs.count != windows.count {
            layoutTabs()
        }
        let currentPoint = convert(event.locationInWindow, from: nil)
        if !isTabDragging {
            let dx = currentPoint.x - dragStart.x
            let dy = currentPoint.y - dragStart.y
            if hypot(dx, dy) > 4 {
                Tako.TabBarController.setDragState(in: group, draggedWindow: draggingWindow, index: fromIndex, start: dragStart, isDragging: true)
            }
        }
        guard isTabDragging else { return }

        let targetIndex: Int?
        if let first = tabs.first, currentPoint.x < first.frame.minX {
            targetIndex = first.index
        } else if let last = tabs.last, currentPoint.x > last.frame.maxX {
            targetIndex = last.index
        } else {
            targetIndex = tabs.first(where: { $0.frame.minX <= currentPoint.x && currentPoint.x <= $0.frame.maxX })?.index
        }

        if let toIndex = targetIndex {
            let visible = group.visibleWindows
            if toIndex != fromIndex && toIndex >= 0 && toIndex < visible.count && fromIndex < visible.count,
               fromIndex < tabs.count && toIndex < tabs.count {
                let fromTab = tabs[fromIndex]
                let toTab = tabs[toIndex]
                let crossesThreshold: Bool
                if toIndex > fromIndex {
                    crossesThreshold = currentPoint.x > max(toTab.frame.minX, fromTab.frame.minX + toTab.frame.width)
                } else {
                    crossesThreshold = currentPoint.x < min(toTab.frame.maxX, toTab.frame.minX + fromTab.frame.width)
                }
                if crossesThreshold {
                    let draggedWin = draggingWindow ?? visible[fromIndex]
                    guard visible.contains(where: { $0 === draggedWin }) else {
                        Tako.TabBarController.setDragState(in: nil, index: nil, start: nil, isDragging: false)
                        return
                    }
                    Tako.CustomTabGroup.move(draggedWin, to: toIndex, in: group)
                    Tako.TabBarController.setDragState(in: group, draggedWindow: draggedWin, index: toIndex, start: dragStart, isDragging: true)
                    needsDisplay = true
                }
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = isTabDragging
        Tako.TabBarController.setDragState(in: nil, index: nil, start: nil, isDragging: false)
        if wasDragging {
            LayoutRecorder.record()
        }
        super.mouseUp(with: event)
    }

    /// How long ⌘ is held before the tab numbers show (Terminal UI: "задержка 150ms"),
    /// so a ⌘ shortcut typed at speed does not flash them.
    static let commandBadgeDelay: TimeInterval = 0.15

    /// Show the command-number badges while the key is held, provided multiple tabs exist.
    func commandKeyChanged(held: Bool) {
        badgeWork?.cancel()
        guard held, windows.count > 1 else {
            if showingBadges {
                showingBadges = false
                needsDisplay = true
            }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.windows.count > 1 else { return }
            self.showingBadges = true
            self.needsDisplay = true
        }
        badgeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commandBadgeDelay, execute: work)
    }
}
