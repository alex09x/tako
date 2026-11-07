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

extension TerminalWindow {
    /// Routes mouse events before `NSWindow.sendEvent(_:)` so `NSTitlebarContainerView`
    /// never swallows clicks/drags meant for the edge-to-edge right terminal or the
    /// permanent sidebar's top drag/zoom header while keeping native traffic lights intact.
    func handleInterceptedWindowEvent(_ event: NSEvent) -> Bool {
        if let bar = Tako.TabBarController.bar(for: self), bar.draggingTabIndex != nil {
            if event.type == .leftMouseDragged {
                bar.mouseDragged(with: event)
                return true
            } else if event.type == .leftMouseUp {
                bar.mouseUp(with: event)
                return true
            }
        }

        if tabTitleEditor.handleMouseDown(event) {
            return true
        }

        if tabTitleEditor.handleRightMouseDown(event) {
            return true
        }

        if event.type == .leftMouseDown,
           let bar = Tako.TabBarController.bar(for: self) {
            let pt = bar.convert(event.locationInWindow, from: nil)
            if bar.bounds.contains(pt), bar.hitTab(at: pt) != nil {
                bar.mouseDown(with: event)
                return true
            }
        }

        if let tracked = topBandMouseTarget {
            if event.type == .leftMouseDragged {
                tracked.mouseDragged(with: event)
                return true
            } else if event.type == .leftMouseUp {
                topBandMouseTarget = nil
                tracked.mouseUp(with: event)
                return true
            }
        }

        if Tako.TabBarController.bar(for: self) == nil,
           !styleMask.contains(.fullScreen),
           styleMask.contains(.titled) {
            let point = event.locationInWindow
            if !hitsStandardWindowButton(at: point),
               isInTitlebarBand(at: point),
               let target = contentHitTarget(at: point) {
                if let dragView = target as? SidebarTitlebarDragView {
                    if event.type == .leftMouseDown {
                        dragView.handleWindowChromeMouseDown(event)
                        return true
                    }
                    if event.type == .leftMouseDragged || event.type == .leftMouseUp {
                        return true
                    }
                } else if routeTopBandContentEvent(event, to: target) {
                    return true
                }
            }
        }

        return false
    }

    func hitsStandardWindowButton(at windowPoint: NSPoint) -> Bool {
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in buttonTypes {
            guard let button = standardWindowButton(type),
                  !button.isHiddenOrHasHiddenAncestor else { continue }
            let local = button.convert(windowPoint, from: nil)
            if button.bounds.insetBy(dx: -2, dy: -2).contains(local) {
                return true
            }
        }
        return false
    }

    func isInTitlebarBand(at windowPoint: NSPoint) -> Bool {
        guard let contentView else { return false }
        let contentRect = contentView.convert(contentView.bounds, to: nil)
        guard contentRect.contains(windowPoint) else { return false }
        if let titlebarContainer = self.titlebarContainer,
           !titlebarContainer.isHiddenOrHasHiddenAncestor {
            let tbRect = titlebarContainer.convert(titlebarContainer.bounds, to: nil)
            if tbRect.contains(windowPoint) {
                return true
            }
        }
        let layoutRect = contentLayoutRect
        if layoutRect.height > 0 && layoutRect.height < contentRect.height {
            return windowPoint.y >= layoutRect.maxY
        }
        return false
    }

    func contentHitTarget(at windowPoint: NSPoint) -> NSView? {
        guard let contentView else { return nil }
        let pointInSuper = contentView.superview?.convert(windowPoint, from: nil) ?? windowPoint
        return contentView.hitTest(pointInSuper)
    }

    private func routeTopBandContentEvent(_ event: NSEvent, to target: NSView) -> Bool {
        switch event.type {
        case .leftMouseDown:
            if isVisible && !isKeyWindow && !Tako.CustomTabGroup.suppressWindowOrderingForTesting {
                makeKeyAndOrderFront(nil)
            }
            if target.acceptsFirstResponder, firstResponder !== target {
                _ = makeFirstResponder(target)
            }
            topBandMouseTarget = target
            target.mouseDown(with: event)
            return true
        case .rightMouseDown:
            target.rightMouseDown(with: event)
            return true
        case .otherMouseDown:
            target.otherMouseDown(with: event)
            return true
        case .otherMouseUp:
            target.otherMouseUp(with: event)
            return true
        case .scrollWheel:
            target.scrollWheel(with: event)
            return true
        default:
            return false
        }
    }
}
