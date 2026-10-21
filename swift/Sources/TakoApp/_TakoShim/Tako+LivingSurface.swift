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
import Combine
import CoreText
import SwiftUI

extension Tako {
    /// Canonical shared design tokens for Style 1b ("Living Surface") across Pill Tabs, Session Sidebar, and Pane Overview (§0).
    enum LivingTokens {
        static let body = NSColor(srgbRed: 0x14 / 255, green: 0x10 / 255, blue: 0x0E / 255, alpha: 1)
        static let chrome = NSColor(srgbRed: 0x1A / 255, green: 0x15 / 255, blue: 0x12 / 255, alpha: 1)
        static let surfaceActive = NSColor(srgbRed: 0x24 / 255, green: 0x1C / 255, blue: 0x16 / 255, alpha: 1)
        static let surfaceHover = NSColor(srgbRed: 0x1F / 255, green: 0x19 / 255, blue: 0x15 / 255, alpha: 1)
        static let hairline = NSColor(srgbRed: 0x2A / 255, green: 0x21 / 255, blue: 0x1B / 255, alpha: 1)
        static let badge = NSColor(srgbRed: 0x35 / 255, green: 0x2B / 255, blue: 0x23 / 255, alpha: 1)
        static let ghostBorder = NSColor(srgbRed: 0x3A / 255, green: 0x2F / 255, blue: 0x27 / 255, alpha: 1)
        static let ringIdle = NSColor(srgbRed: 0x5A / 255, green: 0x4D / 255, blue: 0x43 / 255, alpha: 1)
        static let progressTrack = NSColor(srgbRed: 0x3A / 255, green: 0x2E / 255, blue: 0x26 / 255, alpha: 1)
        static let textActive = NSColor(srgbRed: 0xFA / 255, green: 0xF7 / 255, blue: 0xF2 / 255, alpha: 1)
        static let text = NSColor(srgbRed: 0xED / 255, green: 0xE6 / 255, blue: 0xDF / 255, alpha: 1)
        static let textInactive = NSColor(srgbRed: 0xB7 / 255, green: 0xAC / 255, blue: 0xA1 / 255, alpha: 1)
        static let dim = NSColor(srgbRed: 0x8A / 255, green: 0x7F / 255, blue: 0x76 / 255, alpha: 1)
        static let faint = NSColor(srgbRed: 0x6B / 255, green: 0x62 / 255, blue: 0x59 / 255, alpha: 1)
        static let ember = NSColor(srgbRed: 0xF4 / 255, green: 0x58 / 255, blue: 0x1C / 255, alpha: 1)
        static let claw = NSColor(srgbRed: 0xFF / 255, green: 0x7A / 255, blue: 0x3D / 255, alpha: 1)
        static let rust = NSColor(srgbRed: 0xC2 / 255, green: 0x3E / 255, blue: 0x0E / 255, alpha: 1)
        static let ok = NSColor(srgbRed: 0x7B / 255, green: 0xD8 / 255, blue: 0x8F / 255, alpha: 1)
        static let error = NSColor(srgbRed: 0xD5 / 255, green: 0x4E / 255, blue: 0x53 / 255, alpha: 1)
        static let ink = NSColor(srgbRed: 0x14 / 255, green: 0x10 / 255, blue: 0x0E / 255, alpha: 1)

        // Tomorrow palette for workspaces (§0): no NSColor.systemBlue/systemPurple/systemYellow
        static let wsPurple = NSColor(srgbRed: 0xB2 / 255, green: 0x94 / 255, blue: 0xBB / 255, alpha: 1)
        static let wsYellow = NSColor(srgbRed: 0xF0 / 255, green: 0xC6 / 255, blue: 0x74 / 255, alpha: 1)
        static let wsTeal = NSColor(srgbRed: 0x8A / 255, green: 0xBE / 255, blue: 0xB7 / 255, alpha: 1)

        static func workspaceColor(for name: String?) -> NSColor {
            switch name?.lowercased() {
            case "red": return error
            case "green": return ok
            case "orange": return claw
            case "purple": return wsPurple
            case "yellow": return wsYellow
            default: return wsTeal
            }
        }

        private static let didRegisterFonts: Bool = {
            var fontDirs: [URL] = []
            if let resURL = Bundle.main.resourceURL {
                fontDirs.append(resURL.appendingPathComponent("fonts"))
                fontDirs.append(resURL)
            }
            let srcFontsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/fonts")
            fontDirs.append(srcFontsURL)
            for dir in fontDirs {
                guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
                for item in items where ["ttf", "otf"].contains(item.pathExtension.lowercased()) {
                    CTFontManagerRegisterFontsForURL(item as CFURL, .process, nil)
                }
            }
            return true
        }()

        nonisolated(unsafe) private static var monoCache: [Int: NSFont] = [:]

        static func monoFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
            _ = didRegisterFonts
            let key = Int(size * 10) * 100 + Int((weight.rawValue + 1.0) * 10)
            if let cached = monoCache[key] { return cached }
            let candidates: [String]
            switch weight {
            case .bold, .heavy, .black: candidates = ["JetBrainsMonoNF-Bold", "JetBrainsMono-SemiBold"]
            case .semibold: candidates = ["JetBrainsMono-SemiBold", "JetBrainsMono-Medium"]
            case .medium: candidates = ["JetBrainsMono-Medium", "JetBrainsMonoNF-Regular"]
            default: candidates = ["JetBrainsMonoNF-Regular"]
            }
            let font = candidates.lazy.compactMap { NSFont(name: $0, size: size) }.first ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            monoCache[key] = font
            return font
        }

        static func headerFont(size: CGFloat, weight: Font.Weight = .bold) -> Font {
            _ = didRegisterFonts
            let name = (weight == .medium || weight == .regular) ? "SpaceGrotesk-Medium" : "SpaceGrotesk-Bold"
            return NSFont(name: name, size: size) != nil ? .custom(name, fixedSize: size) : .system(size: size, weight: weight)
        }
    }
}

/// Shared animation clock & accessibility/occlusion state for Spec 1b (§7).
@MainActor
final class LivingAnimationState: ObservableObject {
    static let shared = LivingAnimationState()

    @Published private(set) var reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @Published private(set) var isOccludedOrIdle: Bool = false

    private var entries: [String: (state: Tako.SurfaceState, enteredAt: Date)] = [:]

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshReduceMotion()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recomputeOcclusion()
            }
        }
        // Another app in front is no reason to stop: a window that is still
        // on screen keeps moving. Only a window nobody can see pauses.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recomputeOcclusion()
            }
        }
    }

    var isTimelinePaused: Bool {
        reduceMotion || isOccludedOrIdle
    }

    /// Where the windows and the Reduce Motion setting are read from: the
    /// app's own, or a test's.
    var windowsToWatch: () -> [NSWindow] = { NSApp?.windows ?? [] }
    var reduceMotionSource: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func refreshReduceMotion() {
        let now = reduceMotionSource()
        guard reduceMotion != now else { return }
        reduceMotion = now
        Tako.TabBarController.refreshAll()
    }

    /// Nobody can see Tako: it has windows on screen and every one of them
    /// is covered. Being in the background is not that.
    static func nobodySees(_ windows: [NSWindow]) -> Bool {
        let shown = windows.filter { $0.isVisible }
        return !shown.isEmpty && !shown.contains { $0.occlusionState.contains(.visible) }
    }

    func recomputeOcclusion() {
        let hidden = Self.nobodySees(windowsToWatch())
        guard isOccludedOrIdle != hidden else { return }
        isOccludedOrIdle = hidden
        // The tab rings are layers, not a timeline: they learn of the pause on a redraw.
        Tako.TabBarController.refreshAll()
    }

    /// Told of each frame a SwiftUI clock draws ("overview", "row"): how a
    /// test counts the frames a second the Overview and the sidebar take.
    var onFrame: ((String) -> Void)?

    /// Optional deterministic time override (in seconds) for frame-by-frame visual verification.
    var fixedTimeOverride: TimeInterval?

    func effectiveDate(_ contextDate: Date) -> Date {
        if let fixed = fixedTimeOverride {
            return Date(timeIntervalSinceReferenceDate: fixed)
        }
        return contextDate
    }

    /// Returns elapsed seconds since `id` entered `state` (recording transition on first observation).
    func elapsedInState(for id: String, state: Tako.SurfaceState, now: Date) -> TimeInterval {
        if let fixed = fixedTimeOverride {
            return max(0, fixed)
        }
        if let existing = entries[id] {
            if existing.state == state {
                return max(0, now.timeIntervalSince(existing.enteredAt))
            }
            entries[id] = (state, now)
            return 0
        }
        entries[id] = (state, now)
        return 0
    }

    func resetEntries() {
        entries.removeAll()
    }

    // MARK: - Phase Math (§2, §3, §7 — Exact CSS cubic-bezier curves)

    static func cometDegrees(at t: TimeInterval) -> Double {
        let ms = CSSTiming.positiveMod(t * 1000.0, 2200.0)
        return (ms / 2200.0) * 360.0
    }

    static func spinDegrees(at t: TimeInterval) -> Double {
        let ms = CSSTiming.positiveMod(t * 1000.0, 900.0)
        return (ms / 900.0) * 360.0
    }

    static func breatheFactor(at t: TimeInterval) -> Double {
        let ms = CSSTiming.positiveMod(t * 1000.0, 1600.0)
        return CSSTiming.keyframes([(0, 0.0), (800, 1.0), (1600, 0.0)], ease: CSSTiming.easeInOut, atMs: ms)
    }

    static func blinkOpacity(at t: TimeInterval) -> Double {
        let ms = CSSTiming.positiveMod(t * 1000.0, 1600.0)
        return CSSTiming.keyframes([(0, 1.0), (800, 0.25), (1600, 1.0)], ease: CSSTiming.easeInOut, atMs: ms)
    }

    static func haloMetrics(at t: TimeInterval) -> (scale: CGFloat, opacity: Double) {
        let ms = CSSTiming.positiveMod(t * 1000.0, 1600.0)
        let k = CSSTiming.easeOut(ms / 1600.0)
        return (scale: CGFloat(1.0 + 1.1 * k), opacity: 0.75 * (1.0 - k))
    }

    static func donePopScale(elapsed: TimeInterval) -> CGFloat {
        guard elapsed >= 0, elapsed < 0.704 else { return 1.0 }
        let s = CSSTiming.keyframes(
            [(0, 1.0), (192, 0.55), (448, 1.25), (704, 1.0)],
            ease: CSSTiming.popOvershoot,
            atMs: elapsed * 1000.0
        )
        return CGFloat(s)
    }

    static func failedShakeOffset(elapsed: TimeInterval) -> CGFloat {
        guard elapsed >= 0, elapsed < 0.448 else { return 0 }
        let dx = CSSTiming.keyframes(
            [(0, 0), (64, -2), (128, 2), (192, -2), (256, 2), (320, -1), (448, 0)],
            ease: CSSTiming.easeInOut,
            atMs: elapsed * 1000.0
        )
        return CGFloat(dx)
    }
}

/// Sizes for `StatusRingView` per Spec 1b (§2).
enum StatusRingSize: CGFloat {
    case extraSmall = 11 // "Needs you" segment icon
    case small = 14      // Pill tab, Sidebar session & pane rows
    case large = 18      // Pane Overview card Row 1
}

/// Status Ring replacing the 7px dot and Crab across Sidebar and Overview (§2).
struct StatusRingView: View {
    let state: Tako.SurfaceState
    var size: StatusRingSize = .small
    var now: Date = Date()
    var elapsedInState: TimeInterval = 10.0
    var reduceMotion: Bool = false
    var shakeRingOnly: Bool = false
    /// For a live ring: bumped once for each second that brought output.
    var pulses: Int = 0

    private typealias T = Tako.LivingTokens

    var body: some View {
        let d = size.rawValue
        let t = now.timeIntervalSinceReferenceDate
        let shakeX: CGFloat = (shakeRingOnly && state == .failed && !reduceMotion)
            ? LivingAnimationState.failedShakeOffset(elapsed: elapsedInState)
            : 0
        let popScale: CGFloat = (state == .done && !reduceMotion)
            ? LivingAnimationState.donePopScale(elapsed: elapsedInState)
            : 1.0

        ZStack {
            switch state {
            case .idle:
                Circle()
                    .inset(by: 0.75)
                    .stroke(Color(nsColor: T.ringIdle), lineWidth: 1.5)

            case .working:
                Circle()
                    .inset(by: 1.25)
                    .stroke(Color(nsColor: T.ember).opacity(0.16), lineWidth: 2.5)
                if reduceMotion {
                    Circle()
                        .inset(by: 1.25)
                        .trim(from: 0, to: 0.777)
                        .rotation(.degrees(-90))
                        .stroke(Color(nsColor: T.ember), style: StrokeStyle(lineWidth: 2.5, lineCap: .butt))
                } else {
                    let spin = LivingAnimationState.spinDegrees(at: t)
                    Circle()
                        .inset(by: 1.25)
                        .stroke(
                            AngularGradient(
                                stops: [
                                    .init(color: Color(nsColor: T.ember).opacity(0), location: 0),
                                    .init(color: Color(nsColor: T.ember), location: 0.777),
                                    .init(color: .clear, location: 0.778),
                                    .init(color: .clear, location: 1.0),
                                ],
                                center: .center,
                                angle: .degrees(spin - 90)
                            ),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .butt)
                        )
                }

            case .progress(let p):
                let clamped = CGFloat(min(1.0, max(0.0, p)))
                Circle().inset(by: 1.25).stroke(Color(nsColor: T.progressTrack), lineWidth: 2.5)
                Circle()
                    .inset(by: 1.25)
                    .trim(from: 0, to: clamped)
                    .rotation(.degrees(-90))
                    .stroke(
                        // `.r-prog`: conic-gradient(Rust 0%, Ember p%), clockwise from the top.
                        AngularGradient(
                            stops: [.init(color: Color(nsColor: T.rust), location: 0),
                                    .init(color: Color(nsColor: T.ember), location: max(0.0001, clamped))],
                            center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .butt)
                    )
                    .animation(.easeOut(duration: 0.25), value: clamped)

            case .waiting:
                if !reduceMotion {
                    let halo = LivingAnimationState.haloMetrics(at: t)
                    Circle().stroke(Color(nsColor: T.claw), lineWidth: 2.0)
                        .frame(width: d, height: d).scaleEffect(halo.scale).opacity(halo.opacity)
                }
                Circle().inset(by: 1.0).stroke(Color(nsColor: T.claw), lineWidth: 2.0)
                let dotD: CGFloat = (size == .extraSmall) ? 3.0 : (size == .large ? 5.0 : 4.0)
                let blink = reduceMotion ? 1.0 : LivingAnimationState.blinkOpacity(at: t)
                Circle().fill(Color(nsColor: T.claw)).frame(width: dotD, height: dotD).opacity(blink)

            case .done:
                Circle().fill(Color(nsColor: T.ok))
                checkmarkShape(in: d)
                    .stroke(Color(nsColor: T.ink), style: StrokeStyle(lineWidth: size == .large ? 2.0 : 1.75, lineCap: .round, lineJoin: .round))

            case .failed:
                Circle().fill(Color(nsColor: T.error))
                exclamationShape(in: d).fill(Color(nsColor: T.ink))

            case .offline:
                Circle().inset(by: 0.75)
                    .stroke(Color(nsColor: T.faint), style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))

            case .live(let flowing):
                // Mounted while quiet too, at rest: a ripple mounted with the
                // first burst would miss it, as a new view sees no change.
                if !reduceMotion {
                    LiveRingRipple(pulses: pulses, diameter: d)
                }
                Circle().inset(by: 0.75)
                    .stroke(Color(nsColor: T.ember).opacity(flowing ? 1 : LiveRingStyle.quietOpacity), lineWidth: 1.5)
            }
        }
        .frame(width: d, height: d)
        .scaleEffect(popScale)
        .offset(x: shakeX)
    }

    private func checkmarkShape(in d: CGFloat) -> Path {
        let s = d / 14.0
        var path = Path()
        path.move(to: CGPoint(x: 4.0 * s, y: 7.2 * s))
        path.addLine(to: CGPoint(x: 6.1 * s, y: 9.3 * s))
        path.addLine(to: CGPoint(x: 10.0 * s, y: 5.0 * s))
        return path
    }

    private func exclamationShape(in d: CGFloat) -> Path {
        var path = Path()
        if d >= 18 {
            path.addRoundedRect(in: CGRect(x: 8, y: 4, width: 2, height: 6), cornerSize: CGSize(width: 1, height: 1))
            path.addRoundedRect(in: CGRect(x: 8, y: 12.5, width: 2, height: 2), cornerSize: CGSize(width: 1, height: 1))
        } else {
            let s = d / 14.0
            path.addRoundedRect(in: CGRect(x: 6 * s, y: 3 * s, width: 2 * s, height: 5 * s), cornerSize: CGSize(width: 1, height: 1))
            path.addRoundedRect(in: CGRect(x: 6 * s, y: 9.5 * s, width: 2 * s, height: 2 * s), cornerSize: CGSize(width: 1, height: 1))
        }
        return path
    }
}

