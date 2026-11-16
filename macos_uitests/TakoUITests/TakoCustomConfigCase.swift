/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//
//  TakoCustomConfigCase.swift
//  Tako
//
//  Created by luca on 16.10.2025.
//

import XCTest
import Darwin

@MainActor
class TakoCustomConfigCase: XCTestCase {
    /// A private run (`scripts/uitest.sh --host-id`) names its own host and suite through the
    /// runner's environment; every terminate, state removal and defaults reset below follows
    /// them, so a private run never touches the shared host, its profile or this suite.
    static let defaultsSuiteName: String =
        ProcessInfo.processInfo.environment["TAKO_UITEST_DEFAULTS_SUITE"] ?? "TAKO_UI_TESTS"
    static let testBundleID =
        ProcessInfo.processInfo.environment["TAKO_UITEST_HOST_ID"] ?? "com.tako-core.terminal.uitest"

    private let configFile: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("tako")
    private let sessionsHome = URL(fileURLWithPath: "/private/tmp/tkui")
        .appendingPathComponent(String(UUID().uuidString.prefix(8)))

    var fixtureSessionsHome: URL { sessionsHome }
    var fixtureShellHome: URL { sessionsHome.appendingPathComponent("home", isDirectory: true) }

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: Self.testBundleID)
        if app.state != .notRunning { app.terminate() }
        try removeTestState()
        try resetTestDefaults()
        try FileManager.default.createDirectory(at: sessionsHome, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try updateConfig("")
    }

    override func tearDown() async throws {
        logTestProgress("teardown: app state begin")
        let app = XCUIApplication(bundleIdentifier: Self.testBundleID)
        if app.state != .notRunning {
            logTestProgress("teardown: terminate begin")
            app.terminate()
            logTestProgress("teardown: terminate end")
        }
        logTestProgress("teardown: state cleanup begin")
        try removeTestState()
        logTestProgress("teardown: state cleanup end")
        try resetTestDefaults()
        logTestProgress("teardown: config cleanup begin")
        try? FileManager.default.removeItem(at: configFile)
        logTestProgress("teardown: sessions cleanup begin")
        try? FileManager.default.removeItem(at: sessionsHome)
        logTestProgress("teardown: superclass begin")
        try await super.tearDown()
        logTestProgress("teardown: superclass end")
    }

    func logTestProgress(_ message: String) {
        let line = "[xcui progress \(Date().timeIntervalSince1970)] \(message)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    private func removeTestState() throws {
        let home = try accountHome()
        for path in ["Library/Application Support/\(Self.testBundleID)",
                     "Library/Saved Application State/\(Self.testBundleID).savedState"] {
            let url = home.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                logTestProgress("remove state: \(url.lastPathComponent) begin")
                try FileManager.default.removeItem(at: url)
                logTestProgress("remove state: \(url.lastPathComponent) end")
            }
        }
    }

    private func accountHome() throws -> URL {
        // Cocoa home-directory APIs are container-relative in the UI runner.
        // Resolve the account record without changing HOME or the app's env.
        var account = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var storage = [CChar](repeating: 0, count: 16_384)
        logTestProgress("account lookup begin")
        return try storage.withUnsafeMutableBufferPointer { bytes in
            let status = getpwuid_r(getuid(), &account, bytes.baseAddress!, bytes.count, &result)
            logTestProgress("account lookup end")
            guard status == 0, result != nil, let directory = account.pw_dir else {
                throw NSError(domain: NSPOSIXErrorDomain, code: status == 0 ? Int(ENOENT) : Int(status))
            }
            return URL(fileURLWithPath: String(cString: directory))
        }
    }

    private func resetTestDefaults() throws {
        for domain in [Self.testBundleID, Self.defaultsSuiteName] {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            logTestProgress("defaults \(domain): remove begin")
            defaults.removePersistentDomain(forName: domain)
            logTestProgress("defaults \(domain): synchronize begin")
            XCTAssertTrue(defaults.synchronize(), "Could not reset the test preferences domain")
            logTestProgress("defaults \(domain): synchronize end")
        }
    }

    func updateConfig(_ newConfig: String) throws {
        // The persistence suite has its own runner. These interaction tests
        // own their app lifecycle; explicit settings below can still override.
        let defaults = "window-save-state = never\nsession-persistence = false\nquit-after-last-window-closed = false\n"
        try (defaults + newConfig).write(to: configFile, atomically: true, encoding: .utf8)
    }

    func takoApplication(defaultsSuite: String = TakoCustomConfigCase.defaultsSuiteName) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES", "--no-update", "--no-launch-notices"])
        app.launchEnvironment["TAKO_CONFIG_PATH"] = configFile.path
        app.launchEnvironment["TAKO_USER_DEFAULTS_SUITE"] = defaultsSuite
        app.launchEnvironment["TAKO_SESSIONS_HOME"] = sessionsHome.path
        app.launchEnvironment["TAKO_NO_UPDATE"] = "1"
        app.launchEnvironment["TAKO_NO_LAUNCH_NOTICES"] = "1"
        // The real app is launched outside the runner's sandbox. Establish
        // its shell and provider homes explicitly before its first PTY starts.
        let home = fixtureShellHome
        let agents = sessionsHome.appendingPathComponent("agents", isDirectory: true)
        let environment = [
            "HOME": home.path,
            "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
            "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path,
            "XDG_CACHE_HOME": home.appendingPathComponent(".cache").path,
            "HISTFILE": home.appendingPathComponent(".shell_history").path,
            "ZDOTDIR": home.path,
            "TAKO_AGENT_HOOKS_HOME": agents.path,
            "CODEX_HOME": agents.appendingPathComponent(".codex").path,
        ]
        for (key, path) in environment {
            if key != "HISTFILE" {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            app.launchEnvironment[key] = path
        }
        return app
    }
}
