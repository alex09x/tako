/*
 * tako — Restore explicitly enrolled lifecycle grants across app restarts
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Security
import Darwin

enum HookGrantPersistence {
    static let service = "com.tako-core.terminal.hook-bindings.v1"
    static var enabled: Bool {
        let process = ProcessInfo.processInfo
        return NSClassFromString("XCTestCase") == nil &&
            !process.processName.lowercased().contains("test") &&
            !process.arguments.contains(where: { $0.contains("Testing") || $0.contains("xctest") })
    }

    static func decode(_ data: Data, bundleID: String) -> ControlGrant? {
        guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["bundle_id"] as? String == bundleID,
              record["scopes"] as? [String] == ["signal"],
              let surface = record["surface"] as? String, UUID(uuidString: surface) != nil,
              let token = record["token"] as? String, token.count == 64,
              token.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return ControlGrant(token: token, client: "tako-hook-" + surface,
                            scopes: [.signal], description: "Enrolled terminal lifecycle hook")
    }

    static func records() -> [[String: Any]] {
        guard enabled else { return [] }
        return (metadata() ?? []).compactMap { metadata in
            guard let account = metadata[kSecAttrAccount as String] as? String,
                  let data = secret(account: account) else { return nil }
            var record = metadata
            record[kSecValueData as String] = data
            return record
        }
    }

    private static func metadata() -> [[String: Any]]? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { return nil }
        return result as? [[String: Any]]
    }

    // The binding is created and consumed through macOS's managed security
    // helper, whose Keychain access is already authorized for these items.
    private static func secret(account: String) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            process.terminate()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return output.fileHandleForReading.readDataToEndOfFile()
    }

    static func restore(bundleID: String) -> [ControlGrant] {
        records().compactMap { item in
            guard let data = item[kSecValueData as String] as? Data else { return nil }
            return decode(data, bundleID: bundleID)
        }
    }

    static func remove(token: String) -> Bool {
        guard enabled else { return true }
        guard let items = metadata() else { return false }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = secret(account: account),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            guard value["token"] as? String == token else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["delete-generic-password", "-s", service, "-a", account]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning {
                process.terminate()
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                return false
            }
            guard process.terminationStatus == 0 || process.terminationStatus == 44 else { return false }
        }
        return true
    }
}
