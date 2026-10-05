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

/// Custom URL scheme handler serving local assets under tako-asset://local/ strictly
/// confined within the pane's canonical sandboxed directory.
public final class SandboxedSchemeHandler: NSObject, WKURLSchemeHandler {
    private let getSandboxDir: () -> URL

    public init(getSandboxDir: @escaping () -> URL) {
        self.getSandboxDir = getSandboxDir
        super.init()
    }

    public enum AssetResolutionResult: Equatable {
        case allowed(URL, mimeType: String)
        case outsideSandbox
        case notFound
        case invalidScheme
    }

    public func resolveAsset(url: URL) -> AssetResolutionResult {
        guard url.scheme == "tako-asset" else {
            return .invalidScheme
        }

        let rawPath = url.path.removingPercentEncoding ?? url.path
        let cleanSubPath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let sandboxRoot = getSandboxDir().resolvingSymlinksInPath().standardizedFileURL
        let candidateURL = sandboxRoot.appendingPathComponent(cleanSubPath).resolvingSymlinksInPath().standardizedFileURL

        let canonicalSandbox = sandboxRoot.path
        let canonicalCandidate = candidateURL.path

        // Check strict containment: candidate path must equal or be inside canonical sandbox root
        let isInside = canonicalCandidate == canonicalSandbox ||
            canonicalCandidate.hasPrefix(canonicalSandbox.hasSuffix("/") ? canonicalSandbox : canonicalSandbox + "/")

        guard isInside else {
            return .outsideSandbox
        }

        guard FileManager.default.fileExists(atPath: canonicalCandidate) else {
            return .notFound
        }

        return .allowed(candidateURL, mimeType: mimeTypeFor(candidateURL))
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(NSError(domain: "TakoOverlay", code: 400, userInfo: [NSLocalizedDescriptionKey: "Missing URL"]))
            return
        }

        switch resolveAsset(url: url) {
        case .invalidScheme:
            urlSchemeTask.didFailWithError(NSError(domain: "TakoOverlay", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid scheme"]))
        case .outsideSandbox:
            urlSchemeTask.didFailWithError(NSError(domain: "TakoOverlay", code: 403, userInfo: [NSLocalizedDescriptionKey: "Security refusal: asset is outside sandbox"]))
        case .notFound:
            urlSchemeTask.didFailWithError(NSError(domain: "TakoOverlay", code: 404, userInfo: [NSLocalizedDescriptionKey: "Asset not found"]))
        case .allowed(let candidateURL, let mimeType):
            guard let data = try? Data(contentsOf: candidateURL) else {
                urlSchemeTask.didFailWithError(NSError(domain: "TakoOverlay", code: 404, userInfo: [NSLocalizedDescriptionKey: "Asset unreadable"]))
                return
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": mimeType,
                    "Content-Length": String(data.count),
                    "Access-Control-Allow-Origin": "*",
                    "Cache-Control": "no-cache"
                ]
            ) ?? URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil)
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Task stopped or cancelled by WebKit
    }

    private func mimeTypeFor(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "ico": return "image/x-icon"
        case "css": return "text/css"
        case "js": return "text/javascript"
        case "html", "htm": return "text/html"
        case "json": return "application/json"
        case "txt": return "text/plain"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        default: return "application/octet-stream"
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

        // Register custom sandboxed URL scheme handler for tako-asset://
        let schemeHandler = SandboxedSchemeHandler {
            context.coordinator.overlay.sandboxedDirectory
        }
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "tako-asset")

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

    private func baseAssetURL(for overlay: OverlayState) -> URL {
        let canonicalFileDir = overlay.fileURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalSandbox = overlay.sandboxedDirectory.resolvingSymlinksInPath().standardizedFileURL.path

        if canonicalFileDir == canonicalSandbox {
            return URL(string: "tako-asset://local/")!
        } else if canonicalFileDir.hasPrefix(canonicalSandbox) {
            let relative = String(canonicalFileDir.dropFirst(canonicalSandbox.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let encoded = relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relative
            return URL(string: "tako-asset://local/\(encoded)/")!
        } else {
            return URL(string: "tako-asset://local/")!
        }
    }

    private func loadContent(into webView: WKWebView, coordinator: Coordinator) {
        let baseURL = baseAssetURL(for: overlay)

        switch overlay.fileType {
        case .html:
            var usedEncoding: String.Encoding = .utf8
            if let content = try? String(contentsOf: overlay.fileURL, usedEncoding: &usedEncoding) {
                let styled = DocumentRenderer.injectThemeAndCSP(into: content, theme: theme)
                webView.loadHTMLString(styled, baseURL: baseURL)
            } else if let content = try? String(contentsOf: overlay.fileURL, encoding: .utf8) {
                let styled = DocumentRenderer.injectThemeAndCSP(into: content, theme: theme)
                webView.loadHTMLString(styled, baseURL: baseURL)
            } else if let content = try? String(contentsOf: overlay.fileURL, encoding: .isoLatin1) {
                let styled = DocumentRenderer.injectThemeAndCSP(into: content, theme: theme)
                webView.loadHTMLString(styled, baseURL: baseURL)
            } else {
                let errorHTML = DocumentRenderer.renderSafeErrorHTML(
                    title: "Decoding Error",
                    message: "Unable to read HTML file with supported text encodings. Preview refused for security.",
                    theme: theme
                )
                webView.loadHTMLString(errorHTML, baseURL: baseURL)
            }

        case .markdown:
            if let content = try? String(contentsOf: overlay.fileURL, encoding: .utf8) {
                let html = DocumentRenderer.renderMarkdownHTML(content, theme: theme)
                webView.loadHTMLString(html, baseURL: baseURL)
            } else {
                let errorHTML = DocumentRenderer.renderSafeErrorHTML(
                    title: "Decoding Error",
                    message: "Unable to read Markdown file as UTF-8. Preview refused.",
                    theme: theme
                )
                webView.loadHTMLString(errorHTML, baseURL: baseURL)
            }

        case .diff:
            if let content = try? String(contentsOf: overlay.fileURL, encoding: .utf8) {
                let html = DocumentRenderer.renderDiffHTML(content, theme: theme)
                webView.loadHTMLString(html, baseURL: baseURL)
            } else {
                let errorHTML = DocumentRenderer.renderSafeErrorHTML(
                    title: "Decoding Error",
                    message: "Unable to read diff file as UTF-8. Preview refused.",
                    theme: theme
                )
                webView.loadHTMLString(errorHTML, baseURL: baseURL)
            }

        case .image:
            let html = DocumentRenderer.renderImageHTML(fileURL: overlay.fileURL, theme: theme)
            webView.loadHTMLString(html, baseURL: baseURL)

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

            // Allow navigation within tako-asset scheme if inside sandboxed directory
            if url.scheme == "tako-asset" {
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
