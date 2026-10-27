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

extension Tako {
    /// The workspace pill's list, drawn as the pill is: a row per workspace --
    /// its colour dot, its name, what waits in it -- then "New Workspace...".
    /// A click switches at once and the list is gone in the same moment. The
    /// system menu it replaces blinked the chosen item and faded out before
    /// answering, some 470 ms of a workspace switch.
    @MainActor
    final class WorkspacePicker: NSPanel {
        struct Row {
            var title: String
            var color: NSColor?
            var attention: Int = 0
            var isCurrent = false
            var action: () -> Void
        }

        static let rowHeight: CGFloat = 26
        static let padding: CGFloat = 5
        /// The list on screen, if any: one at a time.
        private(set) static weak var shown: WorkspacePicker?

        let rows: [Row]
        private(set) var rowViews: [RowView] = []
        /// The row the keyboard is on; the mouse moves it too.
        private(set) var highlighted: Int?
        private var dismissed = false
        /// The list never takes the key window: a click that opened it while
        /// its window was not key makes that window key a moment later. The
        /// keyboard and clicks elsewhere reach it through these.
        private var monitors: [Any] = []
        private var observers: [NSObjectProtocol] = []

        init(rows: [Row], width: CGFloat) {
            self.rows = rows
            let height = CGFloat(rows.count) * Self.rowHeight + Self.padding * 2
            super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            becomesKeyOnlyIfNeeded = true
            isReleasedWhenClosed = false
            animationBehavior = .none
            hasShadow = true
            level = .popUpMenu
            backgroundColor = .clear
            isOpaque = false
            setAccessibilityRole(.menu)
            setAccessibilityLabel("Workspaces")

            let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            content.wantsLayer = true
            content.layer?.backgroundColor = Tako.LivingTokens.chrome.cgColor
            content.layer?.cornerRadius = 8
            content.layer?.borderWidth = 1
            content.layer?.borderColor = Tako.LivingTokens.hairline.cgColor
            for (index, row) in rows.enumerated() {
                let y = height - Self.padding - CGFloat(index + 1) * Self.rowHeight
                let view = RowView(row: row, index: index,
                                   frame: NSRect(x: Self.padding, y: y, width: width - Self.padding * 2, height: Self.rowHeight))
                view.picker = self
                content.addSubview(view)
                rowViews.append(view)
            }
            contentView = content
        }

        /// Shows the list under `anchor` (screen coordinates), attached to `parent`.
        @discardableResult
        static func show(rows: [Row], below anchor: NSRect, in parent: NSWindow) -> WorkspacePicker {
            shown?.dismiss()
            let font = Tako.LivingTokens.monoFont(size: 12, weight: .medium)
            let widest = rows.map { Tako.TabText.width(of: $0.title, font: font) + ($0.attention > 0 ? 30 : 0) }.max() ?? 120
            let picker = WorkspacePicker(rows: rows, width: max(190, ceil(widest) + 60))
            picker.setFrameTopLeftPoint(NSPoint(x: anchor.minX, y: anchor.minY - 4))
            parent.addChildWindow(picker, ordered: .above)
            picker.orderFront(nil)
            picker.watch(parent)
            shown = picker
            return picker
        }

        override var canBecomeKey: Bool { false }

        /// Keys while it is up, and what takes it away: a click outside it,
        /// the app going to the back, its window closing.
        private func watch(_ parent: NSWindow) {
            if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, !self.dismissed else { return event }
                    return self.handle(event) ? nil : event
                }
            }) { monitors.append(keys) }
            if let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, event.window !== self else { return event }
                    self.dismiss()
                    return event
                }
            }) { monitors.append(clicks) }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }

        func dismiss() {
            guard !dismissed else { return }
            dismissed = true
            monitors.forEach(NSEvent.removeMonitor)
            monitors.removeAll()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            parent?.removeChildWindow(self)
            orderOut(nil)
            if Self.shown === self { Self.shown = nil }
        }

        /// Takes the row's action: the list goes first, so the switch runs
        /// with nothing of it on screen.
        func choose(_ index: Int) {
            guard rows.indices.contains(index), !dismissed else { return }
            let action = rows[index].action
            dismiss()
            action()
        }

        func highlight(_ index: Int?) {
            highlighted = index
            for view in rowViews { view.isHighlighted = view.index == index }
        }

        /// Up, down, return and escape act on the list; other keys go on.
        @discardableResult
        func handle(_ event: NSEvent) -> Bool {
            switch event.keyCode {
            case 126: highlight(((highlighted ?? rows.count) - 1 + rows.count) % rows.count)   // up
            case 125: highlight(((highlighted ?? -1) + 1) % rows.count)                       // down
            case 36, 76:                                                                        // return
                guard let highlighted else { return true }
                choose(highlighted)
            case 53: dismiss()                                                                  // escape
            default: return false
            }
            return true
        }

        /// One row: drawn, hovered, clicked, and a menu item to VoiceOver.
        final class RowView: NSView {
            let row: Row
            let index: Int
            weak var picker: WorkspacePicker?
            var isHighlighted = false { didSet { if oldValue != isHighlighted { needsDisplay = true } } }

            init(row: Row, index: Int, frame: NSRect) {
                self.row = row
                self.index = index
                super.init(frame: frame)
                setAccessibilityElement(true)
                setAccessibilityRole(.menuItem)
                let title = row.attention > 0 ? "\(row.title) (\(row.attention))" : row.title
                setAccessibilityTitle(title)
                setAccessibilityLabel(title)
                if row.isCurrent { setAccessibilityValue("current") }
                addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                               owner: self, userInfo: nil))
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

            override func accessibilityPerformPress() -> Bool {
                picker?.choose(index)
                return true
            }

            override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
            override func mouseEntered(with event: NSEvent) { picker?.highlight(index) }
            override func mouseExited(with event: NSEvent) { if picker?.highlighted == index { picker?.highlight(nil) } }
            override func mouseDown(with event: NSEvent) {}
            override func mouseUp(with event: NSEvent) {
                guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
                picker?.choose(index)
            }

            override func draw(_ dirtyRect: NSRect) {
                if isHighlighted {
                    Tako.LivingTokens.surfaceActive.setFill()
                    NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
                }
                var x: CGFloat = 10
                if let color = row.color {
                    color.setFill()
                    NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY - 3.5, width: 7, height: 7)).fill()
                }
                x += 15
                let font = Tako.LivingTokens.monoFont(size: 12, weight: row.isCurrent ? .semibold : .medium)
                let color = isHighlighted || row.isCurrent ? Tako.LivingTokens.textActive : Tako.LivingTokens.textInactive
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let size = (row.title as NSString).size(withAttributes: attributes)
                (row.title as NSString).draw(at: NSPoint(x: x, y: bounds.midY - size.height / 2), withAttributes: attributes)
                var right = bounds.maxX - 10
                if row.isCurrent {
                    let mark: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Tako.LivingTokens.ember]
                    let markSize = ("✓" as NSString).size(withAttributes: mark)
                    right -= markSize.width
                    ("✓" as NSString).draw(at: NSPoint(x: right, y: bounds.midY - markSize.height / 2), withAttributes: mark)
                    right -= 8
                }
                if row.attention > 0 {
                    let text = row.attention > 9 ? "9+" : "\(row.attention)"
                    let badgeFont = Tako.LivingTokens.monoFont(size: 9.5, weight: .bold)
                    let textWidth = Tako.TabText.width(of: text, font: badgeFont)
                    let badge = NSRect(x: right - max(14, ceil(textWidth + 8)), y: bounds.midY - 6.5,
                                       width: max(14, ceil(textWidth + 8)), height: 13)
                    Tako.LivingTokens.claw.setFill()
                    NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
                    let badgeAttributes: [NSAttributedString.Key: Any] = [.font: badgeFont, .foregroundColor: Tako.LivingTokens.ink]
                    let textSize = (text as NSString).size(withAttributes: badgeAttributes)
                    (text as NSString).draw(at: NSPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2),
                                            withAttributes: badgeAttributes)
                }
            }
        }
    }
}
