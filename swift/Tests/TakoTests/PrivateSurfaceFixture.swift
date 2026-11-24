/*
 * tako — Private, noninteractive processes for hosted surface regressions
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Darwin
import Testing
@testable import Tako

@MainActor
final class PrivateSurfaceFixture {
    let root: URL
    let configuration: Tako.SurfaceConfiguration
    private var surfaces: [Tako.SurfaceView] = []

    init() throws {
        var template = Array("/private/tmp/tks.XXXXXX".utf8CString)
        guard let directory = mkdtemp(&template) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        root = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        let paths = ["HOME": root.path, "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
                     "XDG_DATA_HOME": root.appendingPathComponent("data").path,
                     "XDG_CACHE_HOME": root.appendingPathComponent("cache").path,
                     "ZDOTDIR": root.path, "TAKO_AGENT_HOOKS_HOME": root.appendingPathComponent("hooks").path,
                     "CODEX_HOME": root.appendingPathComponent("codex").path,
                     "TAKO_SESSIONS_HOME": root.appendingPathComponent("sessions").path]
        for path in Set(paths.values) {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        var environment = paths
        environment["HISTFILE"] = root.appendingPathComponent("history").path
        var config = Tako.SurfaceConfiguration(workingDirectory: root.path, environmentVariables: environment)
        config.program = ["/bin/sleep", "60"]
        config.allowsSessionPersistence = false
        configuration = config
    }

    func surface() -> Tako.SurfaceView {
        let view = Tako.SurfaceView(baseConfig: configuration, theme: .takoDefault)
        view.selfTestCapturing = true
        view.setFrameSize(CGSize(width: 400, height: 300))
        view.flushPendingResizeForTesting()
        surfaces.append(view)
        return view
    }

    func cleanUp() {
        let children = surfaces.compactMap { $0.pty?.child }.filter { $0 > 1 }
        surfaces.forEach { $0.close() }
        let gone = TerminalTestSupport.waitUntil(timeout: 2) {
            children.allSatisfy { Darwin.kill($0, 0) != 0 && errno == ESRCH }
        }
        guard gone else {
            Issue.record("Private fixture process cleanup was not proved; data kept at \(root.path)")
            return
        }
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Private fixture data kept at \(root.path): \(error)") }
    }
}
