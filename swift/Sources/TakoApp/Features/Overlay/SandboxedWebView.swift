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

/// Singleton manager for the precompiled WebKit network deny rule list.
@MainActor
public final class NetworkSandbox {
    public static let shared = NetworkSandbox()

    public private(set) var cachedRuleList: WKContentRuleList?
    private var isCompiling = false
    private var pending: [(WKContentRuleList) -> Void] = []

    public static let blockRulesJSON = """
    [
      {
        "trigger": { "url-filter": "^https://" },
        "action": { "type": "block" }
      },
      {
        "trigger": { "url-filter": "^http://" },
        "action": { "type": "block" }
      },
      {
        "trigger": { "url-filter": "^wss://" },
        "action": { "type": "block" }
      },
      {
        "trigger": { "url-filter": "^ws://" },
        "action": { "type": "block" }
      },
      {
        "trigger": { "url-filter": "^ftp://" },
        "action": { "type": "block" }
      }
    ]
    """

    public init() {
        warmUp()
    }

    public func warmUp() {
        guard cachedRuleList == nil, !isCompiling else { return }
        isCompiling = true
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "TakoBlockNetwork",
            encodedContentRuleList: Self.blockRulesJSON
        ) { [weak self] ruleList, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.cachedRuleList = ruleList
                self.isCompiling = false
                if let ruleList = ruleList {
                    let callbacks = self.pending
                    self.pending.removeAll()
                    for cb in callbacks {
                        cb(ruleList)
                    }
                }
            }
        }
    }

    public func withRuleList(_ completion: @escaping @MainActor (WKContentRuleList) -> Void) {
        if let rule = cachedRuleList {
            completion(rule)
        } else {
            pending.append(completion)
            warmUp()
        }
    }
}

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

        // If rule list is already compiled, install into config before WKWebView is instantiated
        if let ruleList = NetworkSandbox.shared.cachedRuleList {
            config.userContentController.add(ruleList)
            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = context.coordinator
            context.coordinator.webView = webView
            context.coordinator.isRuleListInstalled = true
            loadContent(into: webView, coordinator: context.coordinator)
            return webView
        }

        // If not yet compiled, instantiate WKWebView but DO NOT load content until the rule is compiled and installed
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        NetworkSandbox.shared.withRuleList { ruleList in
            webView.configuration.userContentController.add(ruleList)
            context.coordinator.isRuleListInstalled = true
            context.coordinator.lastLoadedToken = self.reloadToken
            self.loadContent(into: webView, coordinator: context.coordinator)
        }

        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.overlay = overlay
        context.coordinator.theme = theme

        if context.coordinator.lastLoadedToken != reloadToken {
            context.coordinator.lastLoadedToken = reloadToken
            if context.coordinator.isRuleListInstalled {
                loadContent(into: webView, coordinator: context.coordinator)
            }
        }
    }

    private func loadContent(into webView: WKWebView, coordinator: Coordinator) {
        switch overlay.fileType {
        case .html:
            var usedEncoding: String.Encoding = .utf8
            if let content = try? String(contentsOf: overlay.fileURL, usedEncoding: &usedEncoding) {
                let styled = DocumentRenderer.injectThemeAndCSP(into: content, theme: theme)
                webView.loadHTMLString(styled, baseURL: overlay.sandboxedDirectory)
            } else if let content = try? String(contentsOf: overlay.fileURL, encoding: .utf8) {
                let styled = DocumentRenderer.injectThemeAndCSP(into: content, theme: theme)
                webView.loadHTMLString(styled, baseURL: overlay.sandboxedDirectory)
            } else if let content = try? String(contentsOf: overlay.fileURL, encoding: .isoLatin1) {
                let styled = DocumentRenderer.injectThemeAndCSP(into: content, theme: theme)
                webView.loadHTMLString(styled, baseURL: overlay.sandboxedDirectory)
            } else {
                let errorHTML = DocumentRenderer.renderSafeErrorHTML(
                    title: "Decoding Error",
                    message: "Unable to read HTML file with supported text encodings. Preview refused for security.",
                    theme: theme
                )
                webView.loadHTMLString(errorHTML, baseURL: overlay.sandboxedDirectory)
            }

        case .markdown:
            if let content = try? String(contentsOf: overlay.fileURL, encoding: .utf8) {
                let html = DocumentRenderer.renderMarkdownHTML(content, theme: theme)
                webView.loadHTMLString(html, baseURL: overlay.sandboxedDirectory)
            } else {
                let errorHTML = DocumentRenderer.renderSafeErrorHTML(
                    title: "Decoding Error",
                    message: "Unable to read Markdown file as UTF-8. Preview refused.",
                    theme: theme
                )
                webView.loadHTMLString(errorHTML, baseURL: overlay.sandboxedDirectory)
            }

        case .diff:
            if let content = try? String(contentsOf: overlay.fileURL, encoding: .utf8) {
                let html = DocumentRenderer.renderDiffHTML(content, theme: theme)
                webView.loadHTMLString(html, baseURL: overlay.sandboxedDirectory)
            } else {
                let errorHTML = DocumentRenderer.renderSafeErrorHTML(
                    title: "Decoding Error",
                    message: "Unable to read diff file as UTF-8. Preview refused.",
                    theme: theme
                )
                webView.loadHTMLString(errorHTML, baseURL: overlay.sandboxedDirectory)
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
        var isRuleListInstalled: Bool = false
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
