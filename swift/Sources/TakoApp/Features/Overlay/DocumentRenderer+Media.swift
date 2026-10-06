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

extension DocumentRenderer {
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
}
