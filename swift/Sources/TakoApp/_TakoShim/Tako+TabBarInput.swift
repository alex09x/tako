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
        hovered = stripRect.contains(point) ? tabs.first { $0.frame.contains(point) }?.index : nil
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
            toolTip = v.isEmpty ? "About Tako" : "About Tako (v\(v))"
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
        // No close button is drawn on a tab this narrow, so none is hit.
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
        guard showsStrip, stripRect.contains(point), let tab = tabs.first(where: { $0.frame.contains(point) }) else {
            // Empty bar: drag the window, or zoom it on a double click.
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
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
            draggingTabIndex = tab.index
            dragStartPoint = point
            isTabDragging = false
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let fromIndex = draggingTabIndex, let dragStart = dragStartPoint, let group else {
            super.mouseDragged(with: event)
            return
        }
        let currentPoint = convert(event.locationInWindow, from: nil)
        if !isTabDragging {
            let dx = currentPoint.x - dragStart.x
            let dy = currentPoint.y - dragStart.y
            if hypot(dx, dy) > 4 {
                isTabDragging = true
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
            if toIndex != fromIndex && toIndex >= 0 && toIndex < visible.count && fromIndex < visible.count {
                let draggedWin = visible[fromIndex]
                Tako.CustomTabGroup.move(draggedWin, to: toIndex, in: group)
                draggingTabIndex = toIndex
                needsDisplay = true
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isTabDragging {
            isTabDragging = false
            draggingTabIndex = nil
            dragStartPoint = nil
            LayoutRecorder.record()
        } else {
            draggingTabIndex = nil
            dragStartPoint = nil
        }
        super.mouseUp(with: event)
    }

    /// Show the command-number badges while the key is held.
    func commandKeyChanged(held: Bool) {
        badgeWork?.cancel()
        guard held else {
            if showingBadges {
                showingBadges = false
                needsDisplay = true
            }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.showingBadges = true
            self.needsDisplay = true
        }
        badgeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
