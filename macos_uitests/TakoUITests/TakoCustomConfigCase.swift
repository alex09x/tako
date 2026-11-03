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
    static let defaultsSuiteName: String = "TAKO_UI_TESTS"
    private static let testBundleID = "com.tako-core.terminal.uitest"

    private let configFile: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("tako")
    private let sessionsHome = URL(fileURLWithPath: "/private/tmp/tkui")
        .appendingPathComponent(String(UUID().uuidString.prefix(8)))

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
        let app = XCUIApplication(bundleIdentifier: Self.testBundleID)
        if app.state != .notRunning { app.terminate() }
        try removeTestState()
        try resetTestDefaults()
        try? FileManager.default.removeItem(at: configFile)
        try? FileManager.default.removeItem(at: sessionsHome)
        try await super.tearDown()
    }

    private func removeTestState() throws {
        let home = try accountHome()
        for path in ["Library/Application Support/\(Self.testBundleID)",
                     "Library/Saved Application State/\(Self.testBundleID).savedState"] {
            let url = home.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func accountHome() throws -> URL {
        // Cocoa home-directory APIs are container-relative in the UI runner.
        // Resolve the account record without changing HOME or the app's env.
        var account = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var storage = [CChar](repeating: 0, count: 16_384)
        return try storage.withUnsafeMutableBufferPointer { bytes in
            let status = getpwuid_r(getuid(), &account, bytes.baseAddress!, bytes.count, &result)
            guard status == 0, result != nil, let directory = account.pw_dir else {
                throw NSError(domain: NSPOSIXErrorDomain, code: status == 0 ? Int(ENOENT) : Int(status))
            }
            return URL(fileURLWithPath: String(cString: directory))
        }
    }

    private func resetTestDefaults() throws {
        for domain in [Self.testBundleID, Self.defaultsSuiteName] {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            defaults.removePersistentDomain(forName: domain)
            XCTAssertTrue(defaults.synchronize(), "Could not reset the test preferences domain")
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
        return app
    }
}
