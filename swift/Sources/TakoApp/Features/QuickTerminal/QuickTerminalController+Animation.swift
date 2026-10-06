/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Cocoa
import SwiftUI
import TakoKit

extension QuickTerminalController {

    func toggle() {
        if visible {
            animateOut()
        } else {
            animateIn()
        }
    }

    func animateIn() {
        guard let window = self.window else { return }

        // Set our visibility state
        guard !visible else { return }
        visible = true

        // Notify the change
        NotificationCenter.default.post(
            name: .quickTerminalDidChangeVisibility,
            object: self
        )

        // If we have a previously focused application and it isn't us, then
        // we want to store it so we can restore state later.
        if !NSApp.isActive {
            if let previousApp = NSWorkspace.shared.frontmostApplication,
               previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.previousApp = previousApp
            }
        }

        // Set previous active space
        self.previousActiveSpace = CGSSpace.active()

        // If our surface tree is empty then we initialize a new terminal. The surface
        // tree can be empty if for example we run "exit" in the terminal and force
        // animate out.
        if surfaceTree.isEmpty {
            if let tree = restorationState?.surfaceTree, !tree.isEmpty {
                surfaceTree = tree
                let view = tree.first(where: { $0.id.uuidString == restorationState?.focusedSurface }) ?? tree.first!
                focusedSurface = view
                // Add a short delay to check if the correct surface is focused.
                // Each SurfaceWrapper defaults its FocusedValue to itself; without this delay,
                // the tree often focuses the first surface instead of the intended one.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if !view.focused {
                        self.focusedSurface = view
                        self.makeWindowKey(window)
                    }
                }
            } else {
                let view = Tako.SurfaceView(tako, baseConfig: Self.surfaceConfiguration(nil))
                surfaceTree = SplitTree(view: view)
                focusedSurface = view
            }
        }

        // Animate the window in
        animateWindowIn(window: window, from: position)
        // Clear the restoration state after first use
        restorationState = nil
    }

    func animateOut() {
        guard let window = self.window else { return }

        // Set our visibility state
        guard visible else { return }
        visible = false

        // Notify the change
        NotificationCenter.default.post(
            name: .quickTerminalDidChangeVisibility,
            object: self
        )

        animateWindowOut(window: window, to: position)
    }

    func saveScreenState(exitFullscreen: Bool) {
        // If we are in fullscreen, then we exit fullscreen. We do this immediately so
        // we have th correct window.frame for the save state below.
        if exitFullscreen, let fullscreenStyle, fullscreenStyle.isFullscreen {
            fullscreenStyle.exit()
        }
        guard let window else { return }
        // Save the current window frame before animating out. This preserves
        // the user's preferred window size and position for when the quick
        // terminal is reactivated with a new surface. Without this, SwiftUI
        // would reset the window to its minimum content size.
        if window.frame.width > 0 && window.frame.height > 0, let screen = window.screen {
            screenStateCache.save(frame: window.frame, for: screen)
        }
    }

    func animateWindowIn(window: NSWindow, from position: QuickTerminalPosition) {
        guard let screen = derivedConfig.quickTerminalScreen.screen else { return }

        // Grab our last closed frame to use from the cache.
        let closedFrame = screenStateCache.frame(for: screen)

        // Move our window off screen to the initial animation position.
        position.setInitial(
            in: window,
            on: screen,
            terminalSize: derivedConfig.quickTerminalSize,
            closedFrame: closedFrame)

        // We need to set our window level to a high value. In testing, only
        // popUpMenu and above do what we want. This gets it above the menu bar
        // and lets us render off screen.
        window.level = .popUpMenu

        // Move it to the visible position since animation requires this
        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
        }

        // If our dock position would conflict with our target location then
        // we autohide the dock.
        if position.conflictsWithDock(on: screen) {
            if hiddenDock == nil {
                hiddenDock = .init()
            }

            hiddenDock?.hide()
        } else {
            // Ensure we don't have any hidden dock if we don't conflict.
            // The deinit will restore.
            hiddenDock = nil
        }

        // Run the animation that moves our window into the proper place and makes
        // it visible.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = derivedConfig.quickTerminalAnimationDuration
            context.timingFunction = .init(name: .easeIn)
            position.setFinal(
                in: window.animator(),
                on: screen,
                terminalSize: derivedConfig.quickTerminalSize,
                closedFrame: closedFrame)
        }, completionHandler: {
            // There is a very minor delay here so waiting at least an event loop tick
            // keeps us safe from the view not being on the window.
            DispatchQueue.main.async {
                // If we canceled our animation clean up some state.
                guard self.visible else {
                    self.hiddenDock = nil
                    return
                }

                // After animating in, we reset the window level to a value that
                // is above other windows but not as high as popUpMenu. This allows
                // things like IME dropdowns to appear properly.
                window.level = .floating

                // Now that the window is visible, sync our appearance. This function
                // requires the window is visible.
                self.syncAppearance()

                // Once our animation is done, we must grab focus since we can't grab
                // focus of a non-visible window.
                self.makeWindowKey(window)

                // If our application is not active, then we grab focus. Its important
                // we do this AFTER our window is animated in and focused because
                // otherwise macOS will bring forward another window.
                if !NSApp.isActive {
                    NSApp.activate(ignoringOtherApps: true)

                    // This works around a really funky bug where if the terminal is
                    // shown on a screen that has no other Tako windows, it takes
                    // a few (variable) event loop ticks until we can actually focus it.
                    //
                    // We wait one event loop tick to try it because under the happy
                    // path (we have windows on this screen) it takes one event loop
                    // tick for window.isKeyWindow to return true.
                    DispatchQueue.main.async {
                        guard !window.isKeyWindow else { return }
                        self.makeWindowKey(window, retries: 10)
                    }
                }
            }
        })
    }

    /// Attempt to make a window key, supporting retries if necessary. The retries will be attempted
    /// on a separate event loop tick.
    ///
    /// The window must contain the focused surface for this terminal controller.
    private func makeWindowKey(_ window: NSWindow, retries: UInt8 = 0) {
        // We must be visible
        guard visible else { return }

        // If our focused view is somehow not connected to this window then the
        // function calls below do nothing. I don't think this is possible but
        // we should guard against it because it is a Cocoa assertion.
        guard let focusedSurface, focusedSurface.window == window else { return }

        // The window must become top-level
        window.makeKeyAndOrderFront(nil)

        // The view must gain our keyboard focus
        window.makeFirstResponder(focusedSurface)

        // If our window is already key then we're done!
        guard !window.isKeyWindow else { return }

        // If we don't have retries then we're done
        guard retries > 0 else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) {
            self.makeWindowKey(window, retries: retries - 1)
        }
    }

    func animateWindowOut(window: NSWindow, to position: QuickTerminalPosition) {
        saveScreenState(exitFullscreen: true)

        // If we hid the dock then we unhide it.
        hiddenDock = nil

        // If the window isn't on our active space then we don't animate, we just
        // hide it.
        if !window.isOnActiveSpace {
            self.previousApp = nil
            window.orderOut(self)
            // If our application is hidden previously, we hide it again
            if (NSApp.delegate as? AppDelegate)?.hiddenState != nil {
                NSApp.hide(nil)
            }
            return
        }

        // We always animate out to whatever screen the window is actually on.
        guard let screen = window.screen ?? NSScreen.main else { return }

        // If we have a previously active application, restore focus to it. We
        // do this BEFORE the animation below because when the animation completes
        // macOS will bring forward another window.
        if let previousApp = self.previousApp {
            // Make sure we unset the state no matter what
            self.previousApp = nil

            if !previousApp.isTerminated {
                // Ignore the result, it doesn't change our behavior.
                _ = previousApp.activate(options: [])
            }
        }

        // We need to set our window level to a high value. In testing, only
        // popUpMenu and above do what we want. This gets it above the menu bar
        // and lets us render off screen.
        window.level = .popUpMenu

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = derivedConfig.quickTerminalAnimationDuration
            context.timingFunction = .init(name: .easeIn)
            position.setInitial(
                in: window.animator(),
                on: screen,
                terminalSize: derivedConfig.quickTerminalSize,
                closedFrame: window.frame)
        }, completionHandler: {
            // This causes the window to be removed from the screen list and macOS
            // handles what should be focused next.
            window.orderOut(self)
            // If our application is hidden previously, we hide it again
            if (NSApp.delegate as? AppDelegate)?.hiddenState != nil {
                NSApp.hide(nil)
            }
        })
    }

}
