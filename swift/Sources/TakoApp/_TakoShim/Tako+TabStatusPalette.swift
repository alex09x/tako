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

extension Tako {
    @MainActor
    public struct TabStatusPalette: Equatable, Sendable {
        public let working: CGColor
        public let waiting: CGColor
        public let done: CGColor
        public let error: CGColor
        public let idle: CGColor
        public let customIdle: CGColor?
        public let configuredKeys: Set<String>
        public let hasCustomColors: Bool

        public static let defaultBrandTokens: TabStatusPalette = {
            TabStatusPalette(
                working: LivingTokens.ember.cgColor,
                waiting: LivingTokens.claw.cgColor,
                done: LivingTokens.ok.cgColor,
                error: LivingTokens.error.cgColor,
                idle: Brand.dim.cgColor,
                customIdle: nil,
                configuredKeys: [],
                hasCustomColors: false
            )
        }()

        public init(
            working: CGColor,
            waiting: CGColor,
            done: CGColor,
            error: CGColor,
            idle: CGColor,
            customIdle: CGColor? = nil,
            configuredKeys: Set<String> = [],
            hasCustomColors: Bool = true
        ) {
            self.working = working
            self.waiting = waiting
            self.done = done
            self.error = error
            self.idle = idle
            self.customIdle = customIdle
            self.configuredKeys = configuredKeys
            self.hasCustomColors = hasCustomColors
        }

        public init(theme: TerminalTheme?) {
            guard let theme, !theme.tabStatusColors.isEmpty else {
                self = Self.defaultBrandTokens
                return
            }
            let colors = theme.tabStatusColors
            let workingColor = colors["working"] ?? LivingTokens.ember.cgColor
            let waitingColor = colors["waiting"] ?? LivingTokens.claw.cgColor
            let doneColor = colors["done"] ?? LivingTokens.ok.cgColor
            let errorColor = colors["error"] ?? LivingTokens.error.cgColor
            let customIdle = colors["idle"]
            let idleColor = customIdle ?? Brand.dim.cgColor

            var configured = Set<String>()
            for key in ["working", "waiting", "done", "error", "idle"] {
                if colors[key] != nil {
                    configured.insert(key)
                }
            }

            self.working = workingColor
            self.waiting = waitingColor
            self.done = doneColor
            self.error = errorColor
            self.idle = idleColor
            self.customIdle = customIdle
            self.configuredKeys = configured
            self.hasCustomColors = !configured.isEmpty
        }

        public var idleRingColor: CGColor {
            customIdle ?? LivingTokens.ringIdle.cgColor
        }

        public var rust: CGColor {
            LivingTokens.rust.cgColor
        }

        public func color(for dot: String) -> NSColor {
            switch dot {
            case "ember": return NSColor(cgColor: working) ?? Brand.ember
            case "claw": return NSColor(cgColor: waiting) ?? Brand.claw
            case "ok": return NSColor(cgColor: done) ?? Brand.ok
            case "error": return NSColor(cgColor: error) ?? Brand.error
            case "dim": return NSColor(cgColor: idle) ?? Brand.dim
            default: return Brand.color(for: dot)
            }
        }

        public func hex(for dot: String) -> String {
            Brand.hexString(for: color(for: dot))
        }

        public func colorName(for dot: String) -> String {
            let keyMap = ["ember": "working", "claw": "waiting", "ok": "done", "error": "error", "dim": "idle"]
            if let key = keyMap[dot], configuredKeys.contains(key) {
                return hex(for: dot)
            }
            return ["ember": "orange", "claw": "amber", "ok": "green", "error": "red", "dim": "gray"][dot] ?? "gray"
        }
    }
}
