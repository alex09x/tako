/*
 * tako — Setup agent icon helper
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

/// Supported AI coding agent providers for setup cards and dialogs.
public enum SetupAgentProvider: String, CaseIterable, Identifiable, Sendable {
    case antigravity
    case gemini
    case claude
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .antigravity: return "Antigravity"
        case .gemini: return "Gemini CLI"
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        }
    }

    public var assetName: String {
        switch self {
        case .antigravity: return "AgentAntigravity"
        case .gemini: return "AgentGemini"
        case .claude: return "AgentClaude"
        case .codex: return "AgentCodex"
        }
    }

    public var bundleIdentifiers: [String] {
        switch self {
        case .antigravity:
            return ["com.google.antigravity", "com.google.Antigravity", "antigravity"]
        case .gemini:
            return ["com.google.gemini", "com.google.Gemini", "com.google.gemini.desktop"]
        case .claude:
            return ["com.anthropic.claudefordesktop", "com.anthropic.claude", "com.anthropic.Claude"]
        case .codex:
            return ["com.openai.codex", "com.openai.chat", "com.openai.ChatGPT", "com.openai.Codex"]
        }
    }

    public var knownAppNames: [String] {
        switch self {
        case .antigravity: return ["Antigravity.app", "Google Antigravity.app"]
        case .gemini: return ["Gemini.app", "Google Gemini.app"]
        case .claude: return ["Claude.app", "Claude for Desktop.app"]
        case .codex: return ["ChatGPT.app", "Codex.app", "OpenAI Codex.app"]
        }
    }

    public static func match(_ identifier: String) -> SetupAgentProvider? {
        let lower = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let direct = SetupAgentProvider(rawValue: lower) { return direct }
        if lower.contains("antigravity") || lower == "agy" { return .antigravity }
        if lower.contains("gemini") { return .gemini }
        if lower.contains("claude") { return .claude }
        if lower.contains("codex") || lower.contains("chatgpt") || lower.contains("openai") { return .codex }
        return nil
    }
}

/// Resolves provider icons preferring installed application bundles via NSWorkspace,
/// followed by bundled asset catalog images, with crisp vector drawing fallbacks.
@MainActor
public enum SetupAgentIconResolver {
    private static var cache: [String: NSImage] = [:]

    /// Resolves the best available icon image for the given provider:
    /// 1. Installed application icon via NSWorkspace bundle lookup
    /// 2. Asset catalog image if bundled
    /// 3. Rendered crisp vector fallback
    public static func resolveIcon(for provider: SetupAgentProvider, size: CGFloat = 16) -> NSImage {
        let key = "\(provider.rawValue):\(Int(size))"
        if let cached = cache[key] { return cached }

        let image = findInstalledAppIcon(for: provider, size: size)
            ?? findBundledAssetImage(named: provider.assetName, size: size)
            ?? renderVectorFallback(for: provider, size: size)

        cache[key] = image
        return image
    }

    /// Resolves by string identifier
    public static func resolveIcon(for identifier: String, size: CGFloat = 16) -> NSImage {
        if let provider = SetupAgentProvider.match(identifier) {
            return resolveIcon(for: provider, size: size)
        }
        return renderGenericAgentFallback(identifier: identifier, size: size)
    }

    private static func findInstalledAppIcon(for provider: SetupAgentProvider, size: CGFloat) -> NSImage? {
        for bundleId in provider.bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
               FileManager.default.fileExists(atPath: url.path) {
                let img = NSWorkspace.shared.icon(forFile: url.path)
                img.size = NSSize(width: size, height: size)
                return img
            }
        }
        let searchDirs = [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
        for dir in searchDirs {
            for appName in provider.knownAppNames {
                let appURL = dir.appendingPathComponent(appName)
                if FileManager.default.fileExists(atPath: appURL.path) {
                    let img = NSWorkspace.shared.icon(forFile: appURL.path)
                    img.size = NSSize(width: size, height: size)
                    return img
                }
            }
        }
        return nil
    }

    private static func findBundledAssetImage(named name: String, size: CGFloat) -> NSImage? {
        if let image = NSImage(named: NSImage.Name(name)) {
            image.size = NSSize(width: size, height: size)
            return image
        }
        return nil
    }

    public static func renderVectorFallback(for provider: SetupAgentProvider, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            drawVectorGlyph(provider: provider, in: rect, context: context)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func renderGenericAgentFallback(identifier: String, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let bgPath = CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: size * 0.22, cornerHeight: size * 0.22, transform: nil)
            context.addPath(bgPath)
            context.setFillColor(red: 0.20, green: 0.24, blue: 0.32, alpha: 1.0)
            context.fillPath()
            return true
        }
        return image
    }

    nonisolated private static func drawVectorGlyph(provider: SetupAgentProvider, in rect: CGRect, context: CGContext) {
        let w = rect.width
        let h = rect.height
        let cornerRadius = min(w, h) * 0.22
        let insetRect = rect.insetBy(dx: 0.5, dy: 0.5)

        let bgPath = CGPath(roundedRect: insetRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        switch provider {
        case .antigravity:
            context.addPath(bgPath)
            context.setFillColor(red: 0.14, green: 0.17, blue: 0.38, alpha: 1.0)
            context.fillPath()

            let sx = w / 16.0
            let sy = h / 16.0

            context.beginPath()
            context.move(to: CGPoint(x: 8.0 * sx, y: 13.5 * sy))
            context.addLine(to: CGPoint(x: 12.5 * sx, y: 8.5 * sy))
            context.addLine(to: CGPoint(x: 10.8 * sx, y: 8.5 * sy))
            context.addLine(to: CGPoint(x: 8.0 * sx, y: 11.2 * sy))
            context.addLine(to: CGPoint(x: 5.2 * sx, y: 8.5 * sy))
            context.addLine(to: CGPoint(x: 3.5 * sx, y: 8.5 * sy))
            context.closePath()
            context.setFillColor(red: 0.40, green: 0.68, blue: 1.00, alpha: 1.0)
            context.fillPath()

            context.beginPath()
            context.move(to: CGPoint(x: 8.0 * sx, y: 9.5 * sy))
            context.addLine(to: CGPoint(x: 11.0 * sx, y: 5.5 * sy))
            context.addLine(to: CGPoint(x: 9.5 * sx, y: 5.5 * sy))
            context.addLine(to: CGPoint(x: 8.0 * sx, y: 7.2 * sy))
            context.addLine(to: CGPoint(x: 6.5 * sx, y: 5.5 * sy))
            context.addLine(to: CGPoint(x: 5.0 * sx, y: 5.5 * sy))
            context.closePath()
            context.setFillColor(red: 0.65, green: 0.82, blue: 1.00, alpha: 1.0)
            context.fillPath()

            context.beginPath()
            context.move(to: CGPoint(x: 8.0 * sx, y: 4.2 * sy))
            context.addLine(to: CGPoint(x: 8.8 * sx, y: 3.2 * sy))
            context.addLine(to: CGPoint(x: 8.0 * sx, y: 2.2 * sy))
            context.addLine(to: CGPoint(x: 7.2 * sx, y: 3.2 * sy))
            context.closePath()
            context.setFillColor(red: 0.90, green: 0.95, blue: 1.00, alpha: 1.0)
            context.fillPath()

        case .gemini:
            context.addPath(bgPath)
            context.setFillColor(red: 0.08, green: 0.22, blue: 0.54, alpha: 1.0)
            context.fillPath()

            let sx = w / 16.0
            let sy = h / 16.0

            context.beginPath()
            context.move(to: CGPoint(x: 8.0 * sx, y: 14.0 * sy))
            context.addCurve(to: CGPoint(x: 14.0 * sx, y: 8.0 * sy),
                             control1: CGPoint(x: 8.0 * sx, y: 9.5 * sy),
                             control2: CGPoint(x: 9.5 * sx, y: 8.0 * sy))
            context.addCurve(to: CGPoint(x: 8.0 * sx, y: 2.0 * sy),
                             control1: CGPoint(x: 9.5 * sx, y: 8.0 * sy),
                             control2: CGPoint(x: 8.0 * sx, y: 6.5 * sy))
            context.addCurve(to: CGPoint(x: 2.0 * sx, y: 8.0 * sy),
                             control1: CGPoint(x: 8.0 * sx, y: 6.5 * sy),
                             control2: CGPoint(x: 6.5 * sx, y: 8.0 * sy))
            context.addCurve(to: CGPoint(x: 8.0 * sx, y: 14.0 * sy),
                             control1: CGPoint(x: 6.5 * sx, y: 8.0 * sy),
                             control2: CGPoint(x: 8.0 * sx, y: 9.5 * sy))
            context.closePath()
            context.setFillColor(red: 0.95, green: 0.97, blue: 1.00, alpha: 1.0)
            context.fillPath()

            context.beginPath()
            context.move(to: CGPoint(x: 8.0 * sx, y: 11.5 * sy))
            context.addCurve(to: CGPoint(x: 11.5 * sx, y: 8.0 * sy),
                             control1: CGPoint(x: 8.0 * sx, y: 9.0 * sy),
                             control2: CGPoint(x: 9.0 * sx, y: 8.0 * sy))
            context.addCurve(to: CGPoint(x: 8.0 * sx, y: 4.5 * sy),
                             control1: CGPoint(x: 9.0 * sx, y: 8.0 * sy),
                             control2: CGPoint(x: 8.0 * sx, y: 7.0 * sy))
            context.addCurve(to: CGPoint(x: 4.5 * sx, y: 8.0 * sy),
                             control1: CGPoint(x: 8.0 * sx, y: 7.0 * sy),
                             control2: CGPoint(x: 7.0 * sx, y: 8.0 * sy))
            context.addCurve(to: CGPoint(x: 8.0 * sx, y: 11.5 * sy),
                             control1: CGPoint(x: 7.0 * sx, y: 8.0 * sy),
                             control2: CGPoint(x: 8.0 * sx, y: 9.0 * sy))
            context.closePath()
            context.setFillColor(red: 0.45, green: 0.72, blue: 1.00, alpha: 1.0)
            context.fillPath()

        case .claude:
            context.addPath(bgPath)
            context.setFillColor(red: 0.84, green: 0.42, blue: 0.26, alpha: 1.0)
            context.fillPath()

            let sx = w / 16.0
            let sy = h / 16.0

            context.setFillColor(red: 1.00, green: 0.96, blue: 0.92, alpha: 1.0)
            context.fill(CGRect(x: 7.2 * sx, y: 3.0 * sy, width: 1.6 * sx, height: 10.0 * sy))
            context.fill(CGRect(x: 3.0 * sx, y: 7.2 * sy, width: 10.0 * sx, height: 1.6 * sy))

            context.beginPath()
            context.move(to: CGPoint(x: 4.6 * sx, y: 4.6 * sy))
            context.addLine(to: CGPoint(x: 5.7 * sx, y: 3.5 * sy))
            context.addLine(to: CGPoint(x: 12.5 * sx, y: 10.3 * sy))
            context.addLine(to: CGPoint(x: 11.4 * sx, y: 11.4 * sy))
            context.closePath()
            context.fillPath()

            context.beginPath()
            context.move(to: CGPoint(x: 4.6 * sx, y: 11.4 * sy))
            context.addLine(to: CGPoint(x: 3.5 * sx, y: 10.3 * sy))
            context.addLine(to: CGPoint(x: 10.3 * sx, y: 3.5 * sy))
            context.addLine(to: CGPoint(x: 11.4 * sx, y: 4.6 * sy))
            context.closePath()
            context.fillPath()

            context.fill(CGRect(x: 7.0 * sx, y: 7.0 * sy, width: 2.0 * sx, height: 2.0 * sy))

        case .codex:
            context.addPath(bgPath)
            context.setFillColor(red: 0.06, green: 0.40, blue: 0.35, alpha: 1.0)
            context.fillPath()

            let sx = w / 16.0
            let sy = h / 16.0

            context.setStrokeColor(red: 0.92, green: 0.98, blue: 0.95, alpha: 1.0)
            context.setLineWidth(1.0 * min(sx, sy))
            context.setLineCap(.round)
            context.setLineJoin(.round)

            let cx = 8.0 * sx
            let cy = 8.0 * sy
            for i in 0..<6 {
                let angle = Double(i) * (.pi / 3.0)
                let cosA = CGFloat(cos(angle))
                let sinA = CGFloat(sin(angle))
                let r1: CGFloat = 2.0 * sx
                let r2: CGFloat = 4.5 * sx
                context.beginPath()
                context.move(to: CGPoint(x: cx + r1 * cosA, y: cy + r1 * sinA))
                context.addQuadCurve(to: CGPoint(x: cx + r2 * cos(CGFloat(angle) + 0.6), y: cy + r2 * sin(CGFloat(angle) + 0.6)),
                                     control: CGPoint(x: cx + 3.8 * sx * cos(CGFloat(angle) + 0.3), y: cy + 3.8 * sy * sin(CGFloat(angle) + 0.3)))
                context.strokePath()
            }
        }
    }
}

/// A compact, accessible 16pt icon view representing an AI coding agent.
/// Looks up native application icons for installed apps, falling back to
/// bundled vector assets or crisp vector glyphs without generic gray dots.
@MainActor
public struct SetupAgentIcon: View {
    public let id: String
    public var size: CGFloat
    public var isDecorative: Bool

    public init(id: String, size: CGFloat = 16, isDecorative: Bool = true) {
        self.id = id
        self.size = size
        self.isDecorative = isDecorative
    }

    public init(agentId: String, size: CGFloat = 16, isDecorative: Bool = true) {
        self.init(id: agentId, size: size, isDecorative: isDecorative)
    }

    init(agent: SetupAgentService.Status, size: CGFloat = 16, isDecorative: Bool = true) {
        self.init(id: agent.id, size: size, isDecorative: isDecorative)
    }

    init(agent: AgentHooksTool.AgentInfo, size: CGFloat = 16, isDecorative: Bool = true) {
        self.init(id: agent.id, size: size, isDecorative: isDecorative)
    }

    public init(provider: SetupAgentProvider, size: CGFloat = 16, isDecorative: Bool = true) {
        self.init(id: provider.rawValue, size: size, isDecorative: isDecorative)
    }

    public var body: some View {
        let icon = SetupAgentIconResolver.resolveIcon(for: id, size: size)
        let provider = SetupAgentProvider.match(id)
        let label = provider?.displayName ?? id

        let imageView = Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))

        Group {
            if isDecorative {
                imageView.accessibilityHidden(true)
            } else {
                imageView
                    .accessibilityLabel(Text(label))
                    .accessibilityIdentifier("SetupAgentIcon-\(id)")
            }
        }
        .frame(width: size, height: size)
    }

    /// Programmatic NSImage resolver for AppKit integration
    public static func image(for agentId: String, size: CGFloat = 16) -> NSImage {
        SetupAgentIconResolver.resolveIcon(for: agentId, size: size)
    }

    /// Programmatic NSImage resolver by provider enum
    public static func image(for provider: SetupAgentProvider, size: CGFloat = 16) -> NSImage {
        SetupAgentIconResolver.resolveIcon(for: provider, size: size)
    }
}
