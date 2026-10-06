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
import Foundation
import UniformTypeIdentifiers

@MainActor
enum DiagnosticsExporter {
    /// Collects a complete, self-contained diagnostic report with secrets and paths redacted.
    static func collectReport(
        allPanes: [ControlCommands.Pane]? = nil,
        includeTerminal: Bool = false,
        includeBenchmark: Bool = false
    ) -> DiagnosticsReport {
        let panesToCollect = allPanes ?? ControlCommands.panes()
        let versions = collectVersions()
        let system = collectSystemInfo()
        let (configPath, configRedacted) = collectConfig()
        let panes = collectPanes(allPanes: panesToCollect, includeTerminal: includeTerminal)
        let crashes = collectCrashes()
        let benchmark = includeBenchmark ? runMicrobenchmark() : nil

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let generatedAt = formatter.string(from: Date())

        return DiagnosticsReport(
            generatedAt: generatedAt,
            versions: versions,
            system: system,
            configPath: configPath,
            configRedacted: configRedacted,
            panes: panes,
            recentLogs: [],
            crashes: crashes,
            benchmark: benchmark
        )
    }

    /// Exports the diagnostic report to a user-selected local file via NSSavePanel.
    static func exportToFile(
        from panes: [ControlCommands.Pane]? = nil,
        window: NSWindow? = nil,
        completion: ((Result<URL, Error>) -> Void)? = nil
    ) {
        let allPanes = panes ?? ControlCommands.panes()
        let targetWindow = window ?? NSApp.keyWindow ?? NSApp.mainWindow
        let report = collectReport(allPanes: allPanes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        guard let data = try? encoder.encode(report) else {
            completion?(.failure(NSError(domain: "TakoDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode diagnostics JSON"])))
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "tako-diagnostics-\(defaultFilenameTimestamp()).json"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType.json]

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                completion?(.success(url))
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
                completion?(.failure(error))
            }
        }

        if let targetWindow {
            panel.beginSheetModal(for: targetWindow, completionHandler: handleResponse)
        } else {
            handleResponse(panel.runModal())
        }
    }

    private static func collectVersions() -> DiagnosticsVersions {
        let bundle = Bundle.main
        let appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.7"
        let buildNumber = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let bundleID = bundle.bundleIdentifier ?? "com.tako-core.terminal"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buildChars = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.osversion", &buildChars, &size, nil, 0)
        let osBuild = String(cString: buildChars)

        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif

        return DiagnosticsVersions(
            appVersion: appVersion,
            buildNumber: buildNumber,
            bundleIdentifier: bundleID,
            gitCommit: nil,
            osVersion: osVersion,
            osBuild: osBuild,
            arch: arch
        )
    }

    private static func collectSystemInfo() -> DiagnosticsSystem {
        let uptime = ProcessInfo.processInfo.systemUptime
        let physicalMem = ProcessInfo.processInfo.physicalMemory

        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let resident = kerr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
        let virtualSize = kerr == KERN_SUCCESS ? UInt64(info.virtual_size) : 0

        let secureActive = SecureInput.shared.enabled
        let mode = ControlCommands.mode.rawValue

        return DiagnosticsSystem(
            uptimeSeconds: uptime,
            physicalMemoryBytes: physicalMem,
            processMemoryBytes: resident,
            processVirtualMemoryBytes: virtualSize,
            secureInputActive: secureActive,
            remoteControlMode: mode
        )
    }

    private static func collectConfig() -> (path: String?, content: String?) {
        let home = NSHomeDirectory()
        let configPath = (home as NSString).appendingPathComponent(".config/tako/config")
        guard FileManager.default.fileExists(atPath: configPath),
              let raw = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return (DiagnosticsRedactor.reducePath(configPath), nil)
        }
        let redacted = DiagnosticsRedactor.redactSecrets(in: raw)
        return (DiagnosticsRedactor.reducePath(configPath), redacted)
    }

    private static func collectPanes(allPanes: [ControlCommands.Pane], includeTerminal: Bool) -> [DiagnosticsPaneInfo] {
        allPanes.map { pane in
            let surface = pane.surface
            let isSecure = SecureInput.shared.isSecure(for: surface) || surface.isSecureInput
            let id = surface.id.uuidString.lowercased()
            let title = surface.title
            let cwd = DiagnosticsRedactor.reducePath(surface.workingDirectory ?? "")

            let terminalText: String?
            if includeTerminal && !isSecure {
                terminalText = ControlInput.read(surface.core, lines: 1000, styled: false)["text"]?.string
            } else {
                terminalText = nil
            }

            return DiagnosticsPaneInfo(
                id: id,
                title: title,
                cwd: cwd,
                process: nil,
                status: nil,
                isSecureInput: isSecure,
                terminalText: terminalText
            )
        }
    }

    private static func collectCrashes() -> [DiagnosticsCrashSummary] {
        let home = NSHomeDirectory()
        let diagDir = (home as NSString).appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: diagDir) else {
            return []
        }
        let takoReports = files
            .filter { $0.hasPrefix("Tako") || $0.hasPrefix("takoctl") }
            .sorted()
            .suffix(5)

        return takoReports.compactMap { filename in
            let filePath = (diagDir as NSString).appendingPathComponent(filename)
            guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return nil }
            let lines = content.components(separatedBy: "\n").prefix(30)
            let preview = DiagnosticsRedactor.redactSecrets(in: lines.joined(separator: "\n"))
            return DiagnosticsCrashSummary(
                filename: filename,
                date: defaultFilenameTimestamp(),
                signal: nil,
                exception: nil,
                preview: preview
            )
        }
    }

    private static func runMicrobenchmark() -> [String: Double] {
        let iterations = 10_000
        let start = CFAbsoluteTimeGetCurrent()
        var dummy = 0
        for i in 0..<iterations {
            dummy &+= (i ^ 0x5a5a)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let throughput = Double(iterations) / max(elapsed, 0.000001)
        return [
            "iterations": Double(iterations),
            "elapsed_seconds": elapsed,
            "ops_per_second": throughput,
            "dummy_sink": Double(dummy)
        ]
    }

    private static func defaultFilenameTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
