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
import QuartzCore
@testable import Tako

/// The Sessions UI design (Claude Design, «Nuzen логотип и дизайн» ›
/// Sessions UI.dc.html: 1b tabs, 4a sidebar, 4b Overview, 5a plain sessions)
/// as the numbers and rules the motion tests hold the app to. The CSS is the
/// reference where the prose rounds it (a glint of "0.9s" is 30% of a 3.2 s
/// loop, 0.96 s). Where the app departs from the page on a decision Alex
/// made, the entry says so.
enum MotionSpec {
    // MARK: Palette (1b, 5a)

    static let ember = 0xF4581C, claw = 0xFF7A3D, rust = 0xC23E0E, ok = 0x7BD88F, error = 0xD54E53
    static let ringIdle = 0x5A4D43, progressTrack = 0x3A2E26, ghostBorder = 0x3A2F27, faint = 0x6B6259, ink = 0x14100E

    // MARK: Motion (1b legend and «спека для программиста», CSS keyframes)

    /// `.r-work` spin .9s linear infinite, clockwise.
    static let spinnerTurn: CFTimeInterval = 0.9
    /// `orbit` 2.2s linear infinite: the comet, clockwise.
    static let cometTurn: CFTimeInterval = 2.2
    /// `breathe` 1.6s ease-in-out: a half 0.8 s each way; border Claw α .40↔.95, glow 0↔.30, radius 8.
    static let breatheHalf: CFTimeInterval = 0.8
    static let breatheStrokeAlpha: ClosedRange<CGFloat> = 0.40...0.95
    static let breatheGlowOpacity: ClosedRange<Float> = 0...0.30
    static let breatheGlowRadius: CGFloat = 8
    /// Reduce Motion: Claw border and a 20% glow, still.
    static let breatheReducedStrokeAlpha: CGFloat = 0.90
    static let breatheReducedGlowOpacity: Float = 0.20
    /// `halo` 1.6s ease-out: scale 1→2.1, opacity .75→0.
    static let haloLoop: CFTimeInterval = 1.6
    static let haloScale: ClosedRange<CGFloat> = 1...2.1
    static let haloOpacity: (from: Float, to: Float) = (0.75, 0)
    /// `blink` 1.6s ease-in-out: dot opacity 1→.25→1.
    static let blinkHalf: CFTimeInterval = 0.8
    static let blinkOpacity: (from: Float, to: Float) = (1, 0.25)
    /// `pop` 0%,6%,14%,22% of 3.2 s: scale 1, .55, 1.25, 1 on cubic-bezier(.3,1.6,.5,1), once.
    static let popDuration: CFTimeInterval = 0.704
    static let popValues: [CGFloat] = [1, 0.55, 1.25, 1]
    static let popKeyTimes: [Double] = [0, 192.0 / 704, 448.0 / 704, 1]
    static let popCurve: [Float] = [0.3, 1.6, 0.5, 1]
    /// `shimmer` 0%→30% of 3.2 s, ease-out (0,0,.58,1): one green band left to right, once.
    static let glintDuration: CFTimeInterval = 0.96
    static let glintCurve: [Float] = [0, 0, 0.58, 1]
    /// `shake` 0..14% of 3.2 s: x 0,-2,2,-2,2,-1,0, once. The whole pill shakes, title too
    /// (Alex, 2026-10-19, cd400914); a row shakes as a whole; a card shakes its ring.
    static let shakeDuration: CFTimeInterval = 0.448
    static let shakeOffsets: [CGFloat] = [0, -2, 2, -2, 2, -1, 0]
    /// 5a ripple: a Claw ring 1→1.7, opacity .95→0, 0.3 s ease-out, once per burst.
    static let rippleDuration: CFTimeInterval = 0.3
    static let rippleScale: CGFloat = 1.7
    static let rippleOpacity: Float = 0.95
    /// 5a: a quiet program's ring, Ember at 45%; 100% while output flows.
    static let liveQuietAlpha: CGFloat = 0.45

    // MARK: The tab strip (Terminal UI «Вкладки: анатомия, состояния, переходы»)

    /// "новая вкладка ⌘T 160ms ease-out": width 0 → full, content after.
    static let tabAppear: CFTimeInterval = 0.16
    /// "закрытие ⌘W 140ms ease-in": collapses, neighbours close up.
    static let tabClose: CFTimeInterval = 0.14
    /// "переключение ⌃Tab 120ms, только полоса": the content changes at once.
    static let tabBarSlide: CFTimeInterval = 0.12
    /// "перестановка drag 120ms, соседи раздвигаются".
    static let tabReorder: CFTimeInterval = 0.12
    /// "отпустил — вкладка «пружинит» на позицию (spring 300/24)".
    static let dropSpring = (stiffness: 300.0, damping: 24.0)
    /// "drag подняли: тень 0 14px 30px rgba(0,0,0,.55), наклон −3°".
    static let liftShadow = (offset: CGFloat(14), blur: CGFloat(30), alpha: CGFloat(0.55))
    static let liftTilt: CGFloat = -3
    /// "ховер фон #241C16 … появление 80ms", "тултипы через 800ms".
    static let buttonHover: CFTimeInterval = 0.08
    static let tooltipDelayMs = 800
    static let cssEaseOut = CSSTiming.cubicBezier(0, 0, 0.58, 1)
    static let cssEaseIn = CSSTiming.cubicBezier(0.42, 0, 1, 1)

    // MARK: The crab of a classic tab (Terminal UI «Краб во вкладке: 7 состояний», CSS keyframes, SVGs)

    /// `crab-scuttle 0.8s steps(1)`: 0% translateX(-2px) rotate(-8deg), 25% (1, 5°), 50% (3, -5°), 75% (1, 8°).
    static let crabScuttleCycle: CFTimeInterval = 0.8
    static let crabScuttlePoses: [(dx: CGFloat, clockwiseDegrees: CGFloat)] = [(-2, -8), (1, 5), (3, -5), (1, 8)]
    /// `crab-hop`: translateY 0, -4px at 30%, 0 at 55%, -2px at 70%, 0 at 85%, ease-in-out each step;
    /// 1.4 s after exit 0 ("зелёный + подпрыг"), 2 s on a bell ("подпрыгивает один раз").
    static let crabHopStops: [(at: Double, up: Double)] = [(0, 0), (0.30, 4), (0.55, 0), (0.70, 2), (0.85, 0), (1, 0)]
    static let crabHopSuccess: CFTimeInterval = 1.4
    static let crabHopBell: CFTimeInterval = 2
    /// "дрожь один раз (0.4s)": `crab-shake` x 0, -2px at 20%, 2, -2, 2, 0, ease-in-out each step.
    static let crabShakeDuration: CFTimeInterval = 0.4
    static let crabShakeStops: [(at: Double, dx: Double)] = [(0, 0), (0.2, -2), (0.4, 2), (0.6, -2), (0.8, 2), (1, 0)]
    /// "реконнект — пульсирует": `crab-pulse 1.1s ease-in-out infinite`, opacity 1, .35 at 50%, 1.
    static let crabPulseCycle: CFTimeInterval = 1.1
    static let crabPulseStops: [(at: Double, opacity: Double)] = [(0, 1), (0.5, 0.35), (1, 1)]
    /// "призрак": the SVG at `opacity:0.45`, still.
    static let crabGhostOpacity: Float = 0.45
    /// Each state's SVG fills: the claws' group, then the body's.
    static let crabStates: [Tako.CrabState] = [.idle, .running, .succeeded, .failed(code: 1), .attention, .reconnecting, .ghost]
    static func crabColors(_ state: Tako.CrabState) -> (claws: Int, body: Int) {
        switch state {
        case .idle, .attention, .ghost: return (claw, ember)
        case .running, .reconnecting: return (claw, claw)
        case .succeeded: return (ok, ok)
        case .failed: return (error, error)
        }
    }
    /// The SVGs' rects in their 120 box, a cell every 11 from (5, 21): the
    /// claws, the body, the eyes (drawn in the tab's colour: holes).
    static let crabClawRects = [(5, 21), (16, 21), (5, 32), (93, 21), (104, 21), (104, 32)]
    static let crabBodyRects = [(16, 43), (93, 43), (27, 54), (38, 54), (49, 54), (60, 54), (71, 54), (82, 54), (27, 65), (49, 65),
                                (60, 65), (82, 65), (27, 76), (38, 76), (49, 76), (60, 76), (71, 76), (82, 76), (16, 87), (38, 87),
                                (71, 87), (93, 87)]
    static let crabEyeRects = [(38, 65), (71, 65)]
    static let ghostBodyRects = [(16, 43), (93, 43), (27, 43), (38, 43), (49, 43), (60, 43), (71, 43), (82, 43), (27, 54), (49, 54),
                                 (60, 54), (82, 54), (27, 65), (38, 65), (49, 65), (60, 65), (71, 65), (82, 65), (27, 76), (38, 76),
                                 (49, 76), (60, 76), (71, 76), (82, 76), (27, 87), (49, 87), (60, 87), (82, 87)]
    static let ghostEyeRects = [(38, 54), (71, 54)]
    /// A rect of the SVG as (column, row) of the crab's 10 x 7 grid, row 0 at the top.
    static func crabCell(_ rect: (Int, Int)) -> CrabCell { CrabCell(column: (rect.0 - 5) / 11, row: (rect.1 - 21) / 11) }
    struct CrabCell: Hashable { let column: Int, row: Int }

    // MARK: Shapes

    static let ringSide: CGFloat = 14
    static let progressLineHeight: CGFloat = 2
    static let failedLineHeight: CGFloat = 2
    static let offlineDash: [NSNumber] = [3, 3]

    // MARK: Rules (1b, 5a)

    /// "только если команда идёт > 3s".
    static let minimumVisible: TimeInterval = 3
    /// "На активной вкладке «готово» и «ошибка» гаснут через 2s, на фоновых держатся до фокуса".
    static let focusedLinger: TimeInterval = 2
    /// 5a: output within 150 ms of a key is its echo.
    static let echoWindow: TimeInterval = 0.15
    /// 5a: flowing while output arrived in the last 3 s.
    static let liveWindow = 3
    /// offline > failed > waiting > working > progress > done > live > idle.
    static let priorityOrder: [Tako.SurfaceState] = [.offline, .failed, .waiting, .working, .progress(0.5), .done, .live(flowing: true), .idle]

    /// Every state a surface can show, live in both its forms.
    static let states: [Tako.SurfaceState] = [.idle, .working, .progress(0.4), .waiting, .done, .failed, .offline,
                                              .live(flowing: true), .live(flowing: false)]

    // MARK: Surfaces drawn by Core Animation

    /// A surface the CA status layer draws, as the app configures it.
    enum Surface: String, CaseIterable, CustomStringConvertible {
        /// A pill tab: every state, its ring 8-9 pt in.
        case pill
        /// A session row of the sidebar (4a): every state; progress runs the comet too, its line 8 pt in.
        case row
        /// A pane row's border: "показывают только «работает» и «ошибка», остальные состояния — кольцом".
        case paneSurface
        /// A pane row's ring, every state, on a layer of its own.
        case paneRing
        var description: String { rawValue }
    }

    /// What a surface shows in `state`: the oracle every Core Animation test
    /// is checked against. `entered` is a change into the state (not the
    /// first state a surface is drawn in), which is what fires a one-off.
    static func effects(on surface: Surface, _ state: Tako.SurfaceState, reduceMotion: Bool, entered: Bool) -> Set<Effect> {
        var out: Set<Effect> = []
        let moving = !reduceMotion
        // The ring.
        switch surface {
        case .pill, .row, .paneRing:
            switch state {
            case .idle: out.insert(.ring(.idle))
            case .working: out.insert(.ring(.working)); out.insert(.spinner(moving: moving))
            case .progress: out.insert(.ring(.progress))
            case .waiting:
                out.insert(.ring(.waiting)); out.insert(.blink(moving: moving))
                if moving { out.insert(.halo) }
            case .done:
                out.insert(.ring(.done))
                if entered && moving { out.insert(.pop) }
            case .failed: out.insert(.ring(.failed))
            case .offline: out.insert(.ring(.offline))
            case .live(let flowing): out.insert(.ring(flowing ? .liveFlowing : .liveQuiet))
            }
        case .paneSurface:
            out.insert(.ringHidden)
        }
        // The surface.
        let drawsSurface = surface != .paneRing
        let surfaceState: Tako.SurfaceState = surface == .paneSurface
            ? ((state == .working || state == .failed) ? state : .idle) : state
        guard drawsSurface else { return out }
        switch surfaceState {
        case .working:
            out.insert(.border(reduceMotion ? .emberStill : .comet))
        case .progress:
            out.insert(.progressLine)
            if surface == .row { out.insert(.border(reduceMotion ? .emberStill : .comet)) }
        case .waiting:
            out.insert(.border(reduceMotion ? .clawStill : .clawBreathing))
            out.insert(reduceMotion ? .glowStill : .glowBreathing)
        case .done:
            if entered && moving { out.insert(.glint) }
        case .failed:
            out.insert(.failedLine)
        case .offline:
            out.insert(.border(.dashed))
        case .idle, .live:
            break
        }
        return out
    }

    /// One thing a status layer shows or runs, as `StatusLayerInventory` reads it.
    enum Effect: Hashable, CustomStringConvertible {
        case ring(RingLook)
        case ringHidden
        case spinner(moving: Bool)
        case halo
        case blink(moving: Bool)
        case pop
        case border(BorderLook)
        case glowBreathing
        case glowStill
        case glint
        case failedLine
        case progressLine
        case unknown(String)

        var description: String {
            switch self {
            case .ring(let look): return "ring:\(look)"
            case .ringHidden: return "ring hidden"
            case .spinner(let moving): return moving ? "spinner turning" : "spinner still"
            case .halo: return "halo"
            case .blink(let moving): return moving ? "dot blinking" : "dot still"
            case .pop: return "pop"
            case .border(let look): return "border:\(look)"
            case .glowBreathing: return "glow breathing"
            case .glowStill: return "glow still"
            case .glint: return "glint"
            case .failedLine: return "failed line"
            case .progressLine: return "progress line"
            case .unknown(let what): return "unknown:\(what)"
            }
        }
    }

    enum RingLook: String { case idle, working, progress, waiting, done, failed, offline, liveFlowing, liveQuiet }
    enum BorderLook: String { case comet, emberStill, clawBreathing, clawStill, dashed }
}

/// Readable test names for the states (`.progress(0.4)` and not a mangled enum).
extension Tako.SurfaceState {
    var specName: String {
        switch self {
        case .idle: return "idle"
        case .working: return "working"
        case .progress(let p): return "progress \(Int(p * 100))%"
        case .waiting: return "waiting"
        case .done: return "done"
        case .failed: return "failed"
        case .offline: return "offline"
        case .live(let flowing): return flowing ? "live flowing" : "live quiet"
        }
    }
}

extension NSColor {
    /// An sRGB colour from a design hex, `alpha` over it.
    static func spec(_ hex: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
