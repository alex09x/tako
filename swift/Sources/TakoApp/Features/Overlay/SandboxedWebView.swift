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
import WebKit

/// Sandboxed WebKit view enforcing local directory boundaries and terminal theme styling (D1).
///
/// Prevents network access, blocks popups/new windows, confines local reads strictly to
/// the pane's sandboxed directory, and injects terminal CSS theme variables.
public struct SandboxedWebView: NSViewRepresentable {
    public let overlay: OverlayState
    public let reloadToken: UUID?
    public let theme: TerminalTheme?

    public init(overlay: OverlayState, reloadToken: UUID?, theme: TerminalTheme?) {
        self.overlay = overlay
        self.reloadToken = reloadToken
        self.theme = theme
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(overlay: overlay, theme: theme)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = false

        // Block all network requests (http, https, ws, wss, ftp)
        let blockRules = """
        [
          {
            "trigger": {
              "url-filter": "^https?://|^wss?://|^ftp://"
            },
            "action": {
              "type": "block"
            }
          }
        ]
        """
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "TakoBlockNetwork",
            encodedContentRuleList: blockRules
        ) { ruleList, _ in
            if let ruleList = ruleList {
                config.userContentController.add(ruleList)
            }
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        loadContent(into: webView, coordinator: context.coordinator)
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.overlay = overlay
        context.coordinator.theme = theme

        if context.coordinator.lastLoadedToken != reloadToken {
            context.coordinator.lastLoadedToken = reloadToken
            loadContent(into: webView, coordinator: context.coordinator)
        }
    }

    private func loadContent(into webView: WKWebView, coordinator: Coordinator) {
        switch overlay.fileType {
        case .html:
            if let content = try? String(contentsOf: overlay.fileURL, encoding: .utf8) {
                let styled = DocumentRenderer.injectThemeAndCSP(into: content, theme: theme)
                webView.loadHTMLString(styled, baseURL: overlay.sandboxedDirectory)
            } else {
                webView.loadFileURL(overlay.fileURL, allowingReadAccessTo: overlay.sandboxedDirectory)
            }

        case .markdown:
            if let content = try? String(contentsOf: overlay.fileURL, encoding: .utf8) {
                let html = DocumentRenderer.renderMarkdownHTML(content, theme: theme)
                webView.loadHTMLString(html, baseURL: overlay.sandboxedDirectory)
            } else {
                webView.loadFileURL(overlay.fileURL, allowingReadAccessTo: overlay.sandboxedDirectory)
            }

        case .diff:
            if let content = try? String(contentsOf: overlay.fileURL, encoding: .utf8) {
                let html = DocumentRenderer.renderDiffHTML(content, theme: theme)
                webView.loadHTMLString(html, baseURL: overlay.sandboxedDirectory)
            } else {
                webView.loadFileURL(overlay.fileURL, allowingReadAccessTo: overlay.sandboxedDirectory)
            }

        case .image:
            let html = DocumentRenderer.renderImageHTML(fileURL: overlay.fileURL, theme: theme)
            webView.loadHTMLString(html, baseURL: overlay.sandboxedDirectory)

        case .pdf:
            webView.loadFileURL(overlay.fileURL, allowingReadAccessTo: overlay.sandboxedDirectory)
        }
    }

    // MARK: - Navigation Coordinator & Security Policy

    public final class Coordinator: NSObject, WKNavigationDelegate {
        var overlay: OverlayState
        var theme: TerminalTheme?
        var lastLoadedToken: UUID?
        weak var webView: WKWebView?

        init(overlay: OverlayState, theme: TerminalTheme?) {
            self.overlay = overlay
            self.theme = theme
        }

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            // Strictly allow about:blank for initial HTML loads
            if url.absoluteString == "about:blank" {
                decisionHandler(.allow)
                return
            }

            // Strictly permit only file:// URLs inside the canonical sandboxed directory
            if url.isFileURL {
                let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
                let canonicalSandboxPath = overlay.sandboxedDirectory.resolvingSymlinksInPath().standardizedFileURL.path
                let isInside = canonicalURL.path == canonicalSandboxPath ||
                    canonicalURL.path.hasPrefix(canonicalSandboxPath.hasSuffix("/") ? canonicalSandboxPath : canonicalSandboxPath + "/")
                if isInside {
                    decisionHandler(.allow)
                    return
                }
            }

            // Refuse all network, cross-directory, or arbitrary protocol requests
            decisionHandler(.cancel)
        }
    }
}
