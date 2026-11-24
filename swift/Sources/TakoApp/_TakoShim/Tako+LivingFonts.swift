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
import CoreText
import SwiftUI

/// The shell's own typefaces (JetBrains Mono, Space Grotesk), registered once from the bundle.
extension Tako.LivingTokens {
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
