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

/// What a status layer shows and runs, read off its layers, in the terms of
/// `MotionSpec.Effect`: the ring's look and motions, the border, the glow,
/// the glint, the lines.
@MainActor
enum StatusLayerInventory {
    typealias Effect = MotionSpec.Effect
    private typealias Name = Tako.TabStatusLayer.LayerName

    static func effects(of layer: Tako.TabStatusLayer) -> Set<Effect> {
        var out: Set<Effect> = []
        let ring = layer.ringContainer
        if ring.isHidden {
            out.insert(.ringHidden)
        } else {
            out.insert(.ring(ringLook(ring)))
            let parts = ring.sublayers ?? []
            if let spin = parts.first(where: { $0.name == "workingSpin" }) {
                out.insert(.spinner(moving: spin.animation(forKey: "spin") != nil))
            }
            if let halo = parts.first(where: { $0.name == "waitingHalo" }), halo.animation(forKey: "halo") != nil {
                out.insert(.halo)
            }
            if let dot = parts.first(where: { $0.name == "waitingDot" }) {
                out.insert(.blink(moving: dot.animation(forKey: "blink") != nil))
            }
            if ring.animation(forKey: "donePop") != nil { out.insert(.pop) }
        }

        if let comet = layer.named(Name.comet), !comet.isHidden, let gradient = layer.named(Name.cometGradient) as? CAGradientLayer {
            if gradient.animation(forKey: "cometSpin") != nil {
                out.insert(.border(.comet))
            } else if let colors = gradient.colors as? [CGColor], let first = colors.first,
                      first.alpha > 0, colors.allSatisfy({ $0 == first }) {
                out.insert(.border(.emberStill))
            } else {
                out.insert(.unknown("a comet standing still"))
            }
        }
        if let breathe = layer.named(Name.breathe), !breathe.isHidden {
            out.insert(.border(breathe.animation(forKey: "breathe") != nil ? .clawBreathing : .clawStill))
        }
        if let glow = layer.named(Name.breatheGlow), !glow.isHidden, let shadow = layer.named(Name.breatheGlowShadow) {
            out.insert(shadow.animation(forKey: "breatheGlow") != nil ? .glowBreathing : .glowStill)
        }
        if let dashed = layer.named(Name.offlineBorder), !dashed.isHidden { out.insert(.border(.dashed)) }
        if let line = layer.named(Name.failedLine), !line.isHidden { out.insert(.failedLine) }
        if let line = layer.named(Name.progressLine), !line.isHidden { out.insert(.progressLine) }
        if let glint = layer.named(Name.doneGlint), glint.animation(forKey: "doneFlash") != nil { out.insert(.glint) }
        return out
    }

    /// The ring's look, from what it is made of.
    static func ringLook(_ ring: CALayer) -> MotionSpec.RingLook {
        let parts = ring.sublayers ?? []
        let names = Set(parts.compactMap(\.name))
        if names.contains("workingSpin") { return .working }
        if names.contains("progressArc") { return .progress }
        if names.contains("waitingDot") { return .waiting }
        let shapes = parts.compactMap { $0 as? CAShapeLayer }
        if names.contains("liveRipple") {
            let ringStroke = shapes.first { $0.name != "liveRipple" }?.strokeColor?.alpha ?? 0
            return ringStroke > 0.9 ? .liveFlowing : .liveQuiet
        }
        if shapes.contains(where: { $0.fillColor.map { matches($0, MotionSpec.ok) } ?? false }) { return .done }
        if shapes.contains(where: { $0.fillColor.map { matches($0, MotionSpec.error) } ?? false }) { return .failed }
        if shapes.contains(where: { $0.lineDashPattern != nil }) { return .offline }
        return .idle
    }

    static func matches(_ color: CGColor, _ hex: Int) -> Bool {
        guard let c = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
              c.count >= 3 else { return false }
        let want = NSColor.spec(hex)
        return abs(c[0] - want.redComponent) < 0.02 && abs(c[1] - want.greenComponent) < 0.02 && abs(c[2] - want.blueComponent) < 0.02
    }
}

extension CALayer {
    /// The first layer named `name` in this tree, masks included.
    func named(_ name: String) -> CALayer? {
        if self.name == name { return self }
        for sub in sublayers ?? [] {
            if let found = sub.named(name) { return found }
        }
        return mask?.named(name)
    }
}
