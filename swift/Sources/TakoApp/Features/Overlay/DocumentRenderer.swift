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

/// Generates theme-aware HTML wrappers for Markdown, diffs, images, and documents (D1).
public enum DocumentRenderer {

    /// Generates CSS root variables matching the terminal theme.
    public static func cssVariables(for theme: TerminalTheme?) -> String {
        let bgHex = theme?.background.cssHexString ?? "#14100e"
        let fgHex = theme?.foreground.cssHexString ?? "#ede6df"
        let selBgHex = theme?.selectionBackground.cssHexString ?? "#352b23"
        let selFgHex = theme?.selectionForeground?.cssHexString ?? fgHex
        let fontName = theme?.fontFamily ?? "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', sans-serif"

        var paletteVars = ""
        if let theme = theme {
            for (idx, color) in theme.palette {
                paletteVars += "  --tako-color-\(idx): \(color.cssHexString);\n"
            }
        }

        // Standard ANSI fallbacks if palette keys are missing
        let defaults: [(Int, String)] = [
            (0, "#14100e"), (1, "#e5534b"), (2, "#57ab5a"), (3, "#c69026"),
            (4, "#539bf5"), (5, "#bc8cff"), (6, "#39c5cf"), (7, "#b1bac4"),
            (8, "#768390"), (9, "#ff7b72"), (10, "#3fb950"), (11, "#d29922"),
            (12, "#58a6ff"), (13, "#bc8cff"), (14, "#39c5cf"), (15, "#f0f6fc")
        ]
        for (idx, hex) in defaults {
            if theme?.palette[idx] == nil {
                paletteVars += "  --tako-color-\(idx): \(hex);\n"
            }
        }

        return """
        :root {
          --tako-bg: \(bgHex);
          --tako-fg: \(fgHex);
          --tako-selection-bg: \(selBgHex);
          --tako-selection-fg: \(selFgHex);
          --tako-font-family: \(fontName);
          --tako-font-mono: 'SF Mono', Menlo, Monaco, Consolas, 'Courier New', monospace;
        \(paletteVars)}
        """
    }

    /// Strict Content-Security-Policy blocking all network access, script execution,
    /// and disallowing direct file: subresource access in favor of sandboxed tako-asset: and data: URIs.
    public static let defaultCSP = "default-src 'none'; img-src 'self' tako-asset: data:; style-src 'unsafe-inline' tako-asset:; font-src tako-asset: data:; connect-src 'none'; script-src 'none'; media-src 'none'; object-src 'none'; form-action 'none';"

    /// Wraps markdown content into an HTML document styled with terminal theme variables.
    public static func renderMarkdownHTML(_ markdownText: String, theme: TerminalTheme?) -> String {
        let css = cssVariables(for: theme)
        let escaped = escapeHTML(markdownText)
        let bodyHtml = parseSimpleMarkdown(escaped)

        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="\(defaultCSP)">
          <style>
            \(css)
            * { box-sizing: border-box; }
            body {
              margin: 0;
              padding: 24px;
              background-color: var(--tako-bg);
              color: var(--tako-fg);
              font-family: var(--tako-font-family);
              font-size: 14px;
              line-height: 1.6;
              word-wrap: break-word;
            }
            h1, h2, h3, h4, h5, h6 {
              color: var(--tako-fg);
              margin-top: 24px;
              margin-bottom: 12px;
              font-weight: 600;
              border-bottom: 1px solid rgba(255, 255, 255, 0.1);
              padding-bottom: 6px;
            }
            h1 { font-size: 24px; }
            h2 { font-size: 18px; }
            h3 { font-size: 16px; }
            p { margin-top: 0; margin-bottom: 16px; }
            code {
              font-family: var(--tako-font-mono);
              font-size: 13px;
              background: rgba(255, 255, 255, 0.08);
              padding: 2px 6px;
              border-radius: 4px;
            }
            pre {
              background: rgba(0, 0, 0, 0.3);
              border: 1px solid rgba(255, 255, 255, 0.1);
              border-radius: 6px;
              padding: 12px;
              overflow-x: auto;
              font-family: var(--tako-font-mono);
              font-size: 13px;
              line-height: 1.45;
            }
            pre code { background: none; padding: 0; }
            blockquote {
              margin: 0 0 16px 0;
              padding: 0 16px;
              border-left: 4px solid var(--tako-color-4);
              color: var(--tako-color-7);
            }
            ul, ol { padding-left: 24px; margin-bottom: 16px; }
            li { margin-bottom: 4px; }
            table {
              border-collapse: collapse;
              width: 100%;
              margin-bottom: 16px;
            }
            th, td {
              border: 1px solid rgba(255, 255, 255, 0.15);
              padding: 8px 12px;
              text-align: left;
            }
            th { background: rgba(255, 255, 255, 0.05); }
            a { color: var(--tako-color-4); text-decoration: none; }
            a:hover { text-decoration: underline; }
            hr { border: 0; height: 1px; background: rgba(255, 255, 255, 0.1); margin: 24px 0; }
          </style>
        </head>
        <body>
          \(bodyHtml)
        </body>
        </html>
        """
    }

    /// Wraps a unified diff into a formatted HTML document.
    public static func renderDiffHTML(_ diffText: String, theme: TerminalTheme?) -> String {
        let css = cssVariables(for: theme)
        let lines = diffText.components(separatedBy: "\n")
        var diffHtml = ""

        for line in lines {
            let escaped = escapeHTML(line)
            if line.hasPrefix("+++") || line.hasPrefix("---") {
                diffHtml += "<div class='line file-header'>\(escaped)</div>"
            } else if line.hasPrefix("@@") {
                diffHtml += "<div class='line hunk-header'>\(escaped)</div>"
            } else if line.hasPrefix("+") {
                diffHtml += "<div class='line line-add'>\(escaped)</div>"
            } else if line.hasPrefix("-") {
                diffHtml += "<div class='line line-remove'>\(escaped)</div>"
            } else {
                diffHtml += "<div class='line line-context'>\(escaped)</div>"
            }
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="\(defaultCSP)">
          <style>
            \(css)
            * { box-sizing: border-box; }
            body {
              margin: 0;
              padding: 16px;
              background-color: var(--tako-bg);
              color: var(--tako-fg);
              font-family: var(--tako-font-mono);
              font-size: 12px;
              line-height: 1.5;
            }
            .diff-container {
              background: rgba(0, 0, 0, 0.2);
              border: 1px solid rgba(255, 255, 255, 0.1);
              border-radius: 6px;
              overflow-x: auto;
              padding: 4px 0;
            }
            .line {
              white-space: pre-wrap;
              padding: 1px 12px;
              font-family: var(--tako-font-mono);
            }
            .file-header {
              font-weight: bold;
              color: var(--tako-fg);
              background: rgba(255, 255, 255, 0.05);
            }
            .hunk-header {
              color: var(--tako-color-6);
              background: rgba(57, 197, 207, 0.1);
              padding-top: 4px;
              padding-bottom: 4px;
            }
            .line-add {
              background: rgba(87, 171, 90, 0.18);
              color: var(--tako-color-10);
            }
            .line-remove {
              background: rgba(229, 83, 75, 0.18);
              color: var(--tako-color-9);
            }
            .line-context {
              color: var(--tako-color-7);
            }
          </style>
        </head>
        <body>
          <div class="diff-container">
            \(diffHtml)
          </div>
        </body>
        </html>
        """
    }

    /// Wraps an image file into a centered preview HTML document.
    public static func renderImageHTML(fileURL: URL, theme: TerminalTheme?) -> String {
        let css = cssVariables(for: theme)
        let filename = fileURL.lastPathComponent
        let escapedFilename = escapeHTML(filename)
        let urlEncoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        let escapedSrc = escapeHTML(urlEncoded)

        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="\(defaultCSP)">
          <style>
            \(css)
            * { box-sizing: border-box; }
            body {
              margin: 0;
              padding: 24px;
              background-color: var(--tako-bg);
              display: flex;
              flex-direction: column;
              align-items: center;
              justify-content: center;
              min-height: 100vh;
              font-family: var(--tako-font-family);
            }
            .image-card {
              max-width: 95%;
              max-height: 90vh;
              display: flex;
              flex-direction: column;
              align-items: center;
            }
            img {
              max-width: 100%;
              max-height: 80vh;
              object-fit: contain;
              border-radius: 6px;
              box-shadow: 0 4px 20px rgba(0, 0, 0, 0.4);
              background-image: linear-gradient(45deg, rgba(255,255,255,0.05) 25%, transparent 25%),
                                linear-gradient(-45deg, rgba(255,255,255,0.05) 25%, transparent 25%),
                                linear-gradient(45deg, transparent 75%, rgba(255,255,255,0.05) 75%),
                                linear-gradient(-45deg, transparent 75%, rgba(255,255,255,0.05) 75%);
              background-size: 20px 20px;
              background-position: 0 0, 0 10px, 10px -10px, -10px 0px;
            }
            .caption {
              margin-top: 12px;
              color: var(--tako-fg);
              opacity: 0.7;
              font-size: 13px;
            }
          </style>
        </head>
        <body>
          <div class="image-card">
            <img src="\(escapedSrc)" alt="\(escapedFilename)">
            <div class="caption">\(escapedFilename)</div>
          </div>
        </body>
        </html>
        """
    }

    /// Injects Content-Security-Policy and theme variables into arbitrary HTML documents.
    public static func injectThemeAndCSP(into rawHTML: String, theme: TerminalTheme?) -> String {
        let css = cssVariables(for: theme)
        let injection = """
        <meta http-equiv="Content-Security-Policy" content="\(defaultCSP)">
        <style id="tako-theme-vars">
        \(css)
        </style>
        """

        if let headRange = rawHTML.range(of: "<head>", options: .caseInsensitive) {
            var modified = rawHTML
            modified.insert(contentsOf: "\n" + injection + "\n", at: headRange.upperBound)
            return modified
        } else if let htmlRange = rawHTML.range(of: "<html>", options: .caseInsensitive) {
            var modified = rawHTML
            modified.insert(contentsOf: "\n<head>\n" + injection + "\n</head>\n", at: htmlRange.upperBound)
            return modified
        } else {
            return "<head>\n" + injection + "\n</head>\n" + rawHTML
        }
    }

    /// Renders a sandboxed error HTML document with strict CSP and theme styling.
    public static func renderSafeErrorHTML(title: String, message: String, theme: TerminalTheme?) -> String {
        let escTitle = escapeHTML(title)
        let escMessage = escapeHTML(message)
        let css = cssVariables(for: theme)

        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="\(defaultCSP)">
          <style>
            \(css)
            body {
              font-family: var(--tako-font-family, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif);
              background-color: var(--tako-bg, #1a1a1a);
              color: var(--tako-fg, #e0e0e0);
              display: flex;
              align-items: center;
              justify-content: center;
              min-height: 100vh;
              margin: 0;
              padding: 24px;
              box-sizing: border-box;
              text-align: center;
            }
            .error-card {
              max-width: 480px;
              padding: 24px;
              border: 1px solid rgba(229, 83, 75, 0.4);
              border-radius: 8px;
              background: rgba(229, 83, 75, 0.08);
            }
            h2 {
              color: var(--tako-color-9, #ff7b72);
              margin-top: 0;
              margin-bottom: 12px;
              font-size: 18px;
            }
            p {
              color: var(--tako-fg, #cccccc);
              margin: 0;
              font-size: 14px;
              line-height: 1.5;
            }
          </style>
        </head>
        <body>
          <div class="error-card">
            <h2>\(escTitle)</h2>
            <p>\(escMessage)</p>
          </div>
        </body>
        </html>
        """
    }

    // MARK: - Helpers

    public static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func parseSimpleMarkdown(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var inPre = false
        var out: [String] = []

        for line in lines {
            if line.hasPrefix("```") {
                if inPre {
                    out.append("</code></pre>")
                    inPre = false
                } else {
                    out.append("<pre><code>")
                    inPre = true
                }
                continue
            }
            if inPre {
                out.append(line + "\n")
                continue
            }

            if line.hasPrefix("# ") {
                out.append("<h1>" + line.dropFirst(2) + "</h1>")
            } else if line.hasPrefix("## ") {
                out.append("<h2>" + line.dropFirst(3) + "</h2>")
            } else if line.hasPrefix("### ") {
                out.append("<h3>" + line.dropFirst(4) + "</h3>")
            } else if line.hasPrefix("> ") {
                out.append("<blockquote>" + line.dropFirst(2) + "</blockquote>")
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                out.append("<ul><li>" + line.dropFirst(2) + "</li></ul>")
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append("<br>")
            } else {
                out.append("<p>" + line + "</p>")
            }
        }

        if inPre {
            out.append("</code></pre>")
        }

        return out.joined(separator: "\n")
    }
}

extension CGColor {
    /// Formats a CGColor into standard CSS #RRGGBB hex representation.
    public var cssHexString: String {
        guard let components = self.components, components.count >= 3 else {
            return "#000000"
        }
        let r = Int((components[0] * 255.0).rounded())
        let g = Int((components[1] * 255.0).rounded())
        let b = Int((components[2] * 255.0).rounded())
        return String(format: "#%02x%02x%02x", min(255, max(0, r)), min(255, max(0, g)), min(255, max(0, b)))
    }
}
