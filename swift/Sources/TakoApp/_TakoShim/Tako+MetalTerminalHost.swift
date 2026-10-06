/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import CoreGraphics

extension Tako {
    /// The host-side half of the GPU terminal path: everything an AppKit
    /// surface has to decide before handing a frame to the shared
    /// `MetalTerminalRenderer`.
    ///
    /// It is all pure functions over values -- no device, no layer, no view --
    /// so the geometry, the palette and the blink/fallback policy can be
    /// tested on a machine with no GPU and no window server, which is exactly
    /// what `swift test` is.
    enum MetalTerminalHost {
        /// Where the `CAMetalLayer` sits inside a padded surface, and how many
        /// real pixels it must render.
        struct LayerGeometry: Equatable {
            var frame: CGRect
            var drawableSize: CGSize
            var contentsScale: CGFloat

            /// False when the surface is too small to hold a single pixel of
            /// terminal, which is a frame to skip rather than to clamp.
            var isRenderable: Bool {
                drawableSize.width >= 1 && drawableSize.height >= 1
            }
        }

        /// The terminal itself occupies the surface inset by the configured
        /// window padding; the border around it stays the host's to fill.
        static func layerGeometry(
            bounds: CGRect,
            padding: CGFloat,
            scale: CGFloat
        ) -> LayerGeometry {
            let pad = max(padding, 0)
            let scale = max(scale, 1)
            let size = CGSize(
                width: max(bounds.width - pad * 2, 0),
                height: max(bounds.height - pad * 2, 0))
            return LayerGeometry(
                frame: CGRect(origin: CGPoint(x: pad, y: pad), size: size),
                // Whole pixels: a fractional drawable is rounded down by
                // CoreAnimation anyway, and rounding here keeps the viewport
                // the shaders see identical to the texture they write.
                drawableSize: CGSize(
                    width: (size.width * scale).rounded(.down),
                    height: (size.height * scale).rounded(.down)),
                contentsScale: scale)
        }

        /// The four padding bands around the terminal, in view coordinates.
        /// The GPU layer covers the middle, so only these are drawn by the
        /// CoreText overlay -- no band overlaps the Metal layer, which is what
        /// keeps the background from being painted twice.
        static func paddingRects(bounds: CGRect, padding: CGFloat) -> [CGRect] {
            let pad = max(padding, 0)
            guard pad > 0 else { return [] }
            let middleHeight = max(bounds.height - pad * 2, 0)
            return [
                CGRect(x: 0, y: 0, width: bounds.width, height: pad),
                CGRect(x: 0, y: bounds.height - pad, width: bounds.width, height: pad),
                CGRect(x: 0, y: pad, width: pad, height: middleHeight),
                CGRect(x: bounds.width - pad, y: pad, width: pad, height: middleHeight),
            ]
        }

        /// A theme color as the shared renderer wants it: straight (not
        /// premultiplied) sRGB components. Converting first matters -- a
        /// theme color built in another space would otherwise reach the GPU
        /// as raw component values in the wrong basis.
        static func color(_ color: CGColor, alpha: CGFloat = 1) -> SIMD4<Float> {
            let converted = color.converted(
                to: srgbSpace, intent: .defaultIntent, options: nil) ?? color
            let components = converted.components ?? [0, 0, 0, 1]
            let r = components.count > 0 ? components[0] : 0
            let g = components.count > 1 ? components[1] : r
            let b = components.count > 2 ? components[2] : r
            let a = (components.count > 3 ? components[3] : 1) * alpha
            return SIMD4<Float>(Float(r), Float(g), Float(b), Float(max(0, min(1, a))))
        }

        /// The renderer's fallback colors, taken from the user's theme rather
        /// than the shared renderer's built-in defaults.
        static func palette(for theme: TerminalTheme) -> TerminalMetalPalette {
            TerminalMetalPalette(
                background: color(theme.background),
                foreground: color(theme.foreground),
                selection: color(theme.selectionBackground),
                cursor: color(theme.cursorColor))
        }

        /// Cell geometry for the GPU, derived from the same CoreText metrics
        /// the fallback renderer measures the grid with, so both put a cell in
        /// the same place.
        static func metrics(
            for metrics: TerminalRenderer.Metrics,
            scale: CGFloat
        ) -> TerminalMetalCellMetrics {
            TerminalMetalCellMetrics(metrics, scale: max(scale, 1))
        }

        /// The CoreGraphics bottom edge for a preedit cell. Metal places row
        /// zero at the drawable's top, so the overlay must use the drawable
        /// height too. Falling back to the grid height preserves the
        /// bottom-anchored CoreText-only path.
        static func preeditCellBottom(
            cursorRow: Int,
            rows: Int,
            cellHeight: CGFloat,
            viewportHeight: CGFloat?
        ) -> CGFloat {
            guard rows > 0, cellHeight > 0 else { return 0 }
            let row = min(max(cursorRow, 0), rows - 1)
            let height = viewportHeight ?? CGFloat(rows) * cellHeight
            return max(0, height - CGFloat(row + 1) * cellHeight)
        }

        /// Whether the blinking half of the cursor is currently on.
        ///
        /// An unfocused pane does not blink at all -- it shows the outlined
        /// cursor continuously -- and a theme with blinking off has no timer
        /// driving `blinkOn` in the first place.
        static func cursorBlinkPhaseOn(
            isFocused: Bool,
            blinkOn: Bool,
            cursorBlinkEnabled: Bool
        ) -> Bool {
            guard isFocused, cursorBlinkEnabled else { return true }
            return blinkOn
        }

        /// Scrolled into the scrollback, the cursor belongs to a screen the
        /// user is not looking at, so it is not drawn. The planner reads
        /// visibility off the snapshot, so the decision is applied to the
        /// frame rather than carried alongside it.
        static func applyCursorVisibility(
            to frame: inout FfiRenderFrame,
            hasPreedit: Bool = false
        ) {
            frame.snapshot.cursorVisible =
                frame.snapshot.cursorVisible &&
                frame.snapshot.viewportOffset == 0 &&
                !hasPreedit
        }

        /// A layer display can already be queued when synchronized output
        /// opens. Keep the last complete drawable on screen until the engine
        /// closes mode 2026 and reports the accumulated damage.
        static func shouldRender(isSynchronizedOutputActive: Bool) -> Bool {
            !isSynchronizedOutputActive
        }

        // MARK: - Synchronized-output watchdog
        //
        // Suppressing renders for the whole of a mode 2026 frame is correct
        // only while frames are short. codex holds one open for the length of
        // an LLM response -- seconds -- and the display simply stops. The
        // watchdog below force-renders a frame that overstays.
        //
        // The policy lives in pure functions because both bugs this path has
        // shipped were scheduling bugs: a display frozen for the length of a
        // streaming response, and an 8ms busy-loop where the coalescing timer
        // re-entered the redraw request that had scheduled it. Neither was
        // reachable from a test.

        /// How long a mode 2026 frame may suppress drawing before the host
        /// paints it anyway. Long enough that an ordinary frame closes first,
        /// short enough that a stalled one still animates.
        static let syncOutputTimeout: TimeInterval = 0.200

        /// What one PTY batch means for the watchdog.
        enum WatchdogAction: Equatable {
            /// The frame is open and nothing is pending: start the timer.
            case arm
            /// The frame is open and the timer is already running. Re-arming
            /// here -- or requesting a redraw, as this path once did -- is
            /// what turns the coalescing timer into a busy-loop.
            case leaveArmed
            /// The frame closed. The close path redraws on its own.
            case disarm
        }

        static func watchdogAction(
            isSynchronizedOutputActive: Bool,
            watchdogArmed: Bool
        ) -> WatchdogAction {
            guard isSynchronizedOutputActive else { return .disarm }
            return watchdogArmed ? .leaveArmed : .arm
        }

        /// A fired watchdog repaints only while the frame it was armed for is
        /// still open. If the frame closed first, that path has already drawn
        /// the completed frame and repainting would duplicate it.
        static func watchdogShouldForceRender(
            isSynchronizedOutputActive: Bool
        ) -> Bool {
            isSynchronizedOutputActive
        }

        /// Upper bound on forced repaints while a frame stays open for
        /// `duration`. Each one must be re-armed by an incoming PTY batch, so
        /// a stalled frame produces fewer -- but this is the bound that
        /// separates "the display keeps moving" from both failure modes: a
        /// frozen display at 0, and the old busy-loop at one per 8ms.
        static func maxForcedRendersDuring(_ duration: TimeInterval) -> Int {
            guard duration > 0 else { return 0 }
            return Int(duration / syncOutputTimeout)
        }

        /// Ordinary terminal damage does not need a synchronous trip through
        /// Main. Device replies and host events do: they are externally
        /// observable and must stay ordered with later PTY batches.
        static func requiresSynchronousMainApplication(
            output: Data,
            events: [FfiEvent]
        ) -> Bool {
            !output.isEmpty || !events.isEmpty
        }

        /// Cap damage-driven drawing at the fastest display rate we support.
        /// This lets a burst parse ahead instead of interleaving a full frame
        /// between every PTY read, while keeping interactive latency below one
        /// 120 Hz frame.
        static let ptyRedrawCoalescingInterval: TimeInterval = 1.0 / 120.0

        /// Why a surface is drawing with CoreText instead of the GPU.
        enum Fallback: Equatable {
            /// No Metal device, no shader library, or no pipeline: the
            /// renderer never came up.
            case rendererUnavailable
            /// A see-through window. The GPU path clears to the default
            /// background and skips every cell that keeps it, which is only
            /// correct while that background is opaque -- at a lower opacity
            /// those cells would have to be drawn individually and would
            /// cover the very transparency they are meant to preserve. The
            /// whole frame goes back to CoreText, which composites it
            /// correctly, rather than losing content to a half-GPU frame.
            case transparentBackground
            /// The view is temporarily collapsed below its padding (common
            /// during installation and split resizing). CAMetalLayer rejects
            /// a zero-sized drawable, so CoreText owns this clipped frame.
            case unrenderableGeometry
        }

        /// nil when the GPU path is usable, otherwise the reason it is not.
        static func fallback(
            rendererAvailable: Bool,
            backgroundOpacity: Double,
            geometryRenderable: Bool
        ) -> Fallback? {
            guard rendererAvailable else { return .rendererUnavailable }
            guard geometryRenderable else { return .unrenderableGeometry }
            guard backgroundOpacity >= 1 else { return .transparentBackground }
            return nil
        }
    }
}
