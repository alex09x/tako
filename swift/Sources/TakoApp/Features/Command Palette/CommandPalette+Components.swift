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
import SwiftUI

extension String {
    /// Returns the character indices that match `query`, trying a substring match first,
    /// then falling back to initials matching (first letter of each word).
    /// - Returns: `nil` if neither matches.
    func matchedIndices(for query: String) -> [String.Index]? {
        guard !query.isEmpty else { return nil }

        // Prefer substring match.
        if let range = self.range(of: query, options: .caseInsensitive) {
            return Array(self[range].indices)
        }

        // Fall back to initials match.
        let words = self.split(whereSeparator: \.isWhitespace)
        var queryIndex = query.startIndex
        var matched: [String.Index] = []

        for word in words {
            guard queryIndex < query.endIndex else { break }

            if word.first?.lowercased() == query[queryIndex].lowercased() {
                matched.append(word.startIndex)
                queryIndex = query.index(after: queryIndex)
            }
        }

        return queryIndex == query.endIndex ? matched : nil
    }
}

/// The terminal's font for the palette's terminal-style rows.
@MainActor
enum TUIFont {
    private static var theme: TerminalTheme? { (NSApp.delegate as? AppDelegate)?.tako.config.theme }
    static var regular: Font { Font(TakoTUI.font(theme)) }
    static var bold: Font { Font(TakoTUI.font(theme, bold: true)) }
    static var small: Font {
        let f = TakoTUI.font(theme)
        return Font(NSFont(descriptor: f.fontDescriptor, size: max(f.pointSize - 2, 10)) ?? f)
    }
}

/// `╭─ Title ╱╱╱╱╱─╮` without its frame: the title in Claw, then hatching
/// shaded from Rust to Ember to the edge.
struct TUIHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 0) {
            Text(" \(title) ")
                .font(TUIFont.bold)
                .foregroundStyle(Color(nsColor: TakoTUI.claw))
                .fixedSize()
            Text(String(repeating: "╱", count: 120))
                .font(TUIFont.regular)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(LinearGradient(colors: [Color(nsColor: TakoTUI.rust), Color(nsColor: TakoTUI.ember)],
                                                startPoint: .leading, endPoint: .trailing))
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }
}

/// A rule between parts of a terminal-style panel: `├────┤` in the dim colour.
struct TUIRule: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: TakoTUI.dim).opacity(0.6))
            .frame(height: 1)
    }
}
