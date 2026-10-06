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

public struct DiagnosticsVersions: Codable, Sendable {
    public let appVersion: String
    public let buildNumber: String
    public let bundleIdentifier: String
    public let gitCommit: String?
    public let osVersion: String
    public let osBuild: String
    public let arch: String

    public init(
        appVersion: String,
        buildNumber: String,
        bundleIdentifier: String,
        gitCommit: String? = nil,
        osVersion: String,
        osBuild: String,
        arch: String
    ) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.bundleIdentifier = bundleIdentifier
        self.gitCommit = gitCommit
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.arch = arch
    }
}

public struct DiagnosticsSystem: Codable, Sendable {
    public let uptimeSeconds: Double
    public let physicalMemoryBytes: UInt64
    public let processMemoryBytes: UInt64
    public let processVirtualMemoryBytes: UInt64
    public let secureInputActive: Bool
    public let remoteControlMode: String

    public init(
        uptimeSeconds: Double,
        physicalMemoryBytes: UInt64,
        processMemoryBytes: UInt64,
        processVirtualMemoryBytes: UInt64,
        secureInputActive: Bool,
        remoteControlMode: String
    ) {
        self.uptimeSeconds = uptimeSeconds
        self.physicalMemoryBytes = physicalMemoryBytes
        self.processMemoryBytes = processMemoryBytes
        self.processVirtualMemoryBytes = processVirtualMemoryBytes
        self.secureInputActive = secureInputActive
        self.remoteControlMode = remoteControlMode
    }
}

public struct DiagnosticsPaneInfo: Codable, Sendable {
    public let id: String
    public let title: String
    public let cwd: String
    public let process: String?
    public let status: String?
    public let isSecureInput: Bool
    public let terminalText: String?

    public init(
        id: String,
        title: String,
        cwd: String,
        process: String? = nil,
        status: String? = nil,
        isSecureInput: Bool,
        terminalText: String? = nil
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.process = process
        self.status = status
        self.isSecureInput = isSecureInput
        self.terminalText = terminalText
    }
}

public struct DiagnosticsCrashSummary: Codable, Sendable {
    public let filename: String
    public let date: String
    public let signal: String?
    public let exception: String?
    public let preview: String

    public init(
        filename: String,
        date: String,
        signal: String? = nil,
        exception: String? = nil,
        preview: String
    ) {
        self.filename = filename
        self.date = date
        self.signal = signal
        self.exception = exception
        self.preview = preview
    }
}

public struct DiagnosticsReport: Codable, Sendable {
    public let generatedAt: String
    public let versions: DiagnosticsVersions
    public let system: DiagnosticsSystem
    public let configPath: String?
    public let configRedacted: String?
    public let panes: [DiagnosticsPaneInfo]
    public let recentLogs: [String]
    public let crashes: [DiagnosticsCrashSummary]
    public let benchmark: [String: Double]?

    public init(
        generatedAt: String,
        versions: DiagnosticsVersions,
        system: DiagnosticsSystem,
        configPath: String? = nil,
        configRedacted: String? = nil,
        panes: [DiagnosticsPaneInfo],
        recentLogs: [String] = [],
        crashes: [DiagnosticsCrashSummary] = [],
        benchmark: [String: Double]? = nil
    ) {
        self.generatedAt = generatedAt
        self.versions = versions
        self.system = system
        self.configPath = configPath
        self.configRedacted = configRedacted
        self.panes = panes
        self.recentLogs = recentLogs
        self.crashes = crashes
        self.benchmark = benchmark
    }
}
