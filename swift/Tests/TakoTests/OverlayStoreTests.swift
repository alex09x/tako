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
import Testing
@testable import Tako

@Suite @MainActor struct OverlayStoreTests {

    @Test func testInitialState() {
        let store = OverlayStore()
        let paneId = UUID()

        #expect(store.overlays.isEmpty)
        #expect(store.reloadTokens.isEmpty)
        #expect(store.overlay(for: paneId) == nil)
        #expect(store.hasOverlay(paneId: paneId) == false)
    }

    @Test func testOpenAndCloseOverlay() throws {
        let store = OverlayStore()
        let paneId = UUID()

        // Create a temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test-artifact-\(UUID().uuidString).md")
        try "# Test Artifact\n\nHello world".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let state = try store.openOverlay(
            paneId: paneId,
            path: tempFile.path,
            surfacePwd: tempDir.path
        )

        #expect(state.paneId == paneId)
        #expect(state.fileURL.standardizedFileURL == tempFile.standardizedFileURL)
        #expect(state.fileType == .markdown)
        #expect(state.title == tempFile.lastPathComponent)
        #expect(state.sandboxedDirectory.path == tempDir.standardizedFileURL.path)
        #expect(store.hasOverlay(paneId: paneId) == true)
        #expect(store.overlay(for: paneId)?.fileURL == tempFile.standardizedFileURL)
        #expect(store.reloadTokens[paneId] != nil)

        // Close overlay
        let closed = store.closeOverlay(paneId: paneId)
        #expect(closed == true)
        #expect(store.hasOverlay(paneId: paneId) == false)
        #expect(store.overlay(for: paneId) == nil)
        #expect(store.reloadTokens[paneId] == nil)

        // Closing non-existent overlay returns false
        let closedAgain = store.closeOverlay(paneId: paneId)
        #expect(closedAgain == false)
    }

    @Test func testFileTypeInferenceAndExplicitOverride() throws {
        let store = OverlayStore()
        let tempDir = FileManager.default.temporaryDirectory

        // 1. Markdown
        let mdFile = tempDir.appendingPathComponent("doc-\(UUID().uuidString).markdown")
        try "Content".write(to: mdFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: mdFile) }

        let s1 = try store.openOverlay(paneId: UUID(), path: mdFile.path, surfacePwd: tempDir.path)
        #expect(s1.fileType == .markdown)

        // 2. HTML
        let htmlFile = tempDir.appendingPathComponent("page-\(UUID().uuidString).html")
        try "<h1>Title</h1>".write(to: htmlFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: htmlFile) }

        let s2 = try store.openOverlay(paneId: UUID(), path: htmlFile.path, surfacePwd: tempDir.path)
        #expect(s2.fileType == .html)

        // 3. Diff
        let diffFile = tempDir.appendingPathComponent("changes-\(UUID().uuidString).patch")
        try "--- a/file\n+++ b/file".write(to: diffFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: diffFile) }

        let s3 = try store.openOverlay(paneId: UUID(), path: diffFile.path, surfacePwd: tempDir.path)
        #expect(s3.fileType == .diff)

        // 4. Override
        let txtFile = tempDir.appendingPathComponent("log-\(UUID().uuidString).txt")
        try "--- a\n+++ b".write(to: txtFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: txtFile) }

        let s4 = try store.openOverlay(paneId: UUID(), path: txtFile.path, typeString: "diff", surfacePwd: tempDir.path)
        #expect(s4.fileType == .diff)
    }

    @Test func testSandboxingRejectionOutsideWorkingDirectory() throws {
        let store = OverlayStore()
        let tempDir = FileManager.default.temporaryDirectory
        let projectDir = tempDir.appendingPathComponent("project-\(UUID().uuidString)")
        let outsideDir = tempDir.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: projectDir)
            try? FileManager.default.removeItem(at: outsideDir)
        }

        let insideFile = projectDir.appendingPathComponent("report.html")
        try "<p>Inside</p>".write(to: insideFile, atomically: true, encoding: .utf8)

        let outsideFile = outsideDir.appendingPathComponent("secret.txt")
        try "secret".write(to: outsideFile, atomically: true, encoding: .utf8)

        // 1. Inside file succeeds
        let s1 = try store.openOverlay(paneId: UUID(), path: insideFile.path, surfacePwd: projectDir.path)
        #expect(s1.sandboxedDirectory.path == projectDir.resolvingSymlinksInPath().standardizedFileURL.path)

        // 2. Outside file is strictly rejected
        #expect(throws: Error.self) {
            try store.openOverlay(paneId: UUID(), path: outsideFile.path, surfacePwd: projectDir.path)
        }

        // 3. Symlink pointing outside sandbox is strictly rejected
        let symlinkPath = projectDir.appendingPathComponent("symlink_to_secret.txt")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: outsideFile)
        #expect(throws: Error.self) {
            try store.openOverlay(paneId: UUID(), path: symlinkPath.path, surfacePwd: projectDir.path)
        }

        // 4. Dot-dot path traversal escaping sandbox is strictly rejected
        let dotDotPath = projectDir.appendingPathComponent("../outside-\(outsideDir.lastPathComponent)/secret.txt")
        #expect(throws: Error.self) {
            try store.openOverlay(paneId: UUID(), path: dotDotPath.path, surfacePwd: projectDir.path)
        }
    }

    @Test func testImageFilenameEscapingAndCSPInjection() {
        let tempDir = FileManager.default.temporaryDirectory
        let maliciousFilename = "crafted\" onerror=\"alert(1)'.png"
        let fileURL = tempDir.appendingPathComponent(maliciousFilename)

        let html = DocumentRenderer.renderImageHTML(fileURL: fileURL, theme: nil)

        // Verifies no raw unescaped breakout attribute
        #expect(!html.contains("src=\"crafted\" onerror=\"alert(1)'.png\""))
        #expect(!html.contains("alt=\"crafted\" onerror=\"alert(1)'.png\""))

        // Verifies properly escaped attributes and caption
        #expect(html.contains("alt=\"crafted&quot; onerror=&quot;alert(1)&#39;.png\""))
        #expect(html.contains("crafted&quot; onerror=&quot;alert(1)&#39;.png</div>"))

        // Verifies strict Content-Security-Policy blocking all scripts and network
        #expect(html.contains("http-equiv=\"Content-Security-Policy\""))
        #expect(html.contains("default-src 'none'"))
        #expect(html.contains("script-src 'none'"))
        #expect(html.contains("connect-src 'none'"))
    }

    @Test func testReloadOverlay() throws {
        let store = OverlayStore()
        let paneId = UUID()
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("reload-\(UUID().uuidString).md")
        try "# Initial".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        try store.openOverlay(paneId: paneId, path: tempFile.path, surfacePwd: tempDir.path)
        let initialToken = store.reloadTokens[paneId]
        #expect(initialToken != nil)

        store.reloadOverlay(paneId: paneId)
        let reloadedToken = store.reloadTokens[paneId]
        #expect(reloadedToken != nil)
        #expect(reloadedToken != initialToken)
    }

    @Test func testNonExistentFileThrows() {
        let store = OverlayStore()
        let fakePath = "/path/to/nonexistent/file-\(UUID().uuidString).html"

        #expect(throws: Error.self) {
            try store.openOverlay(paneId: UUID(), path: fakePath)
        }
    }

    @Test func testHTMLLoadPathAlwaysReceivesCSPAndRejectsUnsafeFallback() {
        // 1. Untrusted HTML document containing remote subresources
        let untrustedHTML = """
        <!DOCTYPE html>
        <html>
        <head><title>Untrusted</title></head>
        <body>
          <img src="https://attacker.com/leak.png">
          <script src="https://attacker.com/exploit.js"></script>
        </body>
        </html>
        """
        let styled = DocumentRenderer.injectThemeAndCSP(into: untrustedHTML, theme: nil)
        #expect(styled.contains("<meta http-equiv=\"Content-Security-Policy\""))
        #expect(styled.contains("default-src 'none'"))
        #expect(styled.contains("script-src 'none'"))
        #expect(styled.contains("connect-src 'none'"))

        // 2. Fallback safe error HTML generation on decoding failure
        let errorHTML = DocumentRenderer.renderSafeErrorHTML(
            title: "Decoding Error",
            message: "Unable to read HTML file with supported text encodings.",
            theme: nil
        )
        #expect(errorHTML.contains("<meta http-equiv=\"Content-Security-Policy\""))
        #expect(errorHTML.contains("default-src 'none'"))
        #expect(errorHTML.contains("Decoding Error"))
        #expect(errorHTML.contains("Unable to read HTML file"))

        // 3. Network block rules verify regex pattern
        #expect(NetworkSandbox.blockRulesJSON.contains("^https://"))
        #expect(NetworkSandbox.blockRulesJSON.contains("^http://"))
        #expect(NetworkSandbox.blockRulesJSON.contains("^wss://"))
        #expect(NetworkSandbox.blockRulesJSON.contains("^ws://"))
        #expect(NetworkSandbox.blockRulesJSON.contains("^ftp://"))

        // 4. Verify file: scheme is completely excluded from CSP subresources
        #expect(!DocumentRenderer.defaultCSP.contains("file:"))
        #expect(DocumentRenderer.defaultCSP.contains("tako-asset:"))
        #expect(styled.contains("img-src 'self' tako-asset: data:"))
        #expect(!styled.contains("img-src 'self' file:"))
    }

    @Test func testSandboxedSchemeHandlerEnforcesDirectoryContainment() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let sandboxDir = tempDir.appendingPathComponent("sandbox-\(UUID().uuidString)")
        let outsideDir = tempDir.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandboxDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sandboxDir)
            try? FileManager.default.removeItem(at: outsideDir)
        }

        let insideFile = sandboxDir.appendingPathComponent("chart.png")
        let insideData = Data([0x89, 0x50, 0x4E, 0x47])
        try insideData.write(to: insideFile)

        let outsideFile = outsideDir.appendingPathComponent("secret.png")
        try Data([0x00, 0x01]).write(to: outsideFile)

        let symlinkFile = sandboxDir.appendingPathComponent("symlink_outside.png")
        try FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: outsideFile)

        let handler = SandboxedSchemeHandler { sandboxDir }

        // 1. Inside asset loads successfully
        let resInside = handler.resolveAsset(url: URL(string: "tako-asset://local/chart.png")!)
        #expect(resInside == .allowed(insideFile.resolvingSymlinksInPath().standardizedFileURL, mimeType: "image/png"))

        // 2. Traversal outside sandbox is refused
        let resTraversal = handler.resolveAsset(url: URL(string: "tako-asset://local/../outside-\(outsideDir.lastPathComponent)/secret.png")!)
        #expect(resTraversal == .outsideSandbox)

        // 3. Symlink escaping sandbox is refused
        let resSymlink = handler.resolveAsset(url: URL(string: "tako-asset://local/symlink_outside.png")!)
        #expect(resSymlink == .outsideSandbox)

        // 4. Non-existent file in sandbox returns notFound
        let resMissing = handler.resolveAsset(url: URL(string: "tako-asset://local/missing.png")!)
        #expect(resMissing == .notFound)

        // 5. Invalid scheme returns invalidScheme
        let resInvalid = handler.resolveAsset(url: URL(string: "file:///etc/passwd")!)
        #expect(resInvalid == .invalidScheme)
    }
}

