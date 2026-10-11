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
import ApplicationServices
import Foundation

// MARK: - Main Showcase Entrypoint

@main
struct TakoShowcase {
    static func main() {
        let rawArgs = Array(CommandLine.arguments.dropFirst())

        if rawArgs.contains("--list") {
            print("Tako Feature Showcase Matrix:")
            print(String(repeating: "-", count: 80))
            for item in showcaseManifest {
                print("[\(item.status.rawValue)] \(item.id.padding(toLength: 22, withPad: " ", startingAt: 0)) (\(item.chapter))")
                print("  Feature: \(item.feature)")
                print("  Witness: \(item.witness)")
            }
            exit(0)
        }

        guard let appPath = rawArgs.first, !appPath.starts(with: "-") else {
            print("usage: tako-showcase <Tako.app> [--pace fast|presentation] [--scene <id>] [--chapter <name>] [--record <file.mov>] [--display] [--output-dir <dir>]")
            print("       tako-showcase --list")
            exit(2)
        }

        guard AXIsProcessTrusted() else {
            print("FAIL: this process has no Accessibility permission to drive Tako UI")
            exit(1)
        }

        var pacing: PacingMode = .presentation
        var scenesWanted = Set<String>()
        var chapterWanted: String? = nil
        var recordPath: String? = nil
        var recordFullDisplay = false
        var outputDirPath = "target/demo-runs/\(Int(Date().timeIntervalSince1970))"

        var i = 1
        while i < rawArgs.count {
            let arg = rawArgs[i]
            switch arg {
            case "--pace":
                if i + 1 < rawArgs.count {
                    pacing = PacingMode(rawValue: rawArgs[i + 1]) ?? .presentation
                    i += 1
                }
            case "--scene":
                if i + 1 < rawArgs.count {
                    scenesWanted.insert(rawArgs[i + 1])
                    i += 1
                }
            case "--chapter":
                if i + 1 < rawArgs.count {
                    chapterWanted = rawArgs[i + 1]
                    i += 1
                }
            case "--record":
                if i + 1 < rawArgs.count {
                    recordPath = rawArgs[i + 1]
                    i += 1
                }
            case "--display":
                recordFullDisplay = true
            case "--output-dir":
                if i + 1 < rawArgs.count {
                    outputDirPath = rawArgs[i + 1]
                    i += 1
                }
            default:
                break
            }
            i += 1
        }

        let outputDirURL = URL(fileURLWithPath: outputDirPath)
        do {
            try FileManager.default.createDirectory(at: outputDirURL, withIntermediateDirectories: true)
        } catch {
            print("FAIL: Failed to create output directory at \(outputDirURL.path): \(error)")
            exit(1)
        }

        let gitRevision = ProcessInfo.processInfo.environment["TAKO_SHOWCASE_REV"] ?? Driver.sharedGitRevision()

        // Helper to persist report on all paths
        func persistReport(
            scenes: [ShowcaseSceneReport],
            video: VideoMetadata?,
            errorMsg: String?
        ) {
            let passed = scenes.filter { $0.status == "PASS" }.count
            let failed = (errorMsg != nil) ? max(1, scenes.filter { $0.status == "FAIL" }.count) : scenes.filter { $0.status == "FAIL" }.count
            let skipped = scenes.filter { $0.status == "SKIPPED" || $0.status == "NOT_REQUESTED" }.count

            let rep = ShowcaseReport(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                gitRevision: gitRevision,
                appPath: appPath,
                bundleId: ProcessInfo.processInfo.environment["TAKO_BUNDLE_ID"] ?? "unknown",
                commandOptions: rawArgs,
                pacing: pacing.rawValue,
                failedCount: failed,
                passedCount: passed,
                skippedCount: skipped,
                scenes: scenes,
                video: video,
                error: errorMsg
            )

            do {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try enc.encode(rep)
                try data.write(to: outputDirURL.appendingPathComponent("showcase_report.json"))

                var lines = [
                    "Tako Showcase Report",
                    "Timestamp: \(rep.timestamp)",
                    "Revision: \(rep.gitRevision)",
                    "App: \(rep.appPath) (Bundle: \(rep.bundleId))",
                    "Pacing: \(rep.pacing)",
                    "Status: \(failed == 0 ? "OK" : "FAILED")",
                    "Passed: \(passed), Failed: \(failed), Skipped/Unrequested: \(skipped)",
                    "",
                    "Scenes:",
                ]
                for s in scenes {
                    lines.append("  [\(s.status)] \(s.id) (\(String(format: "%.2f", s.durationSeconds))s) - \(s.feature)")
                }
                if let v = video {
                    lines.append("")
                    lines.append("Video:")
                    lines.append("  Path: \(v.path)")
                    lines.append("  Duration: \(String(format: "%.2f", v.durationSeconds))s")
                    lines.append("  Resolution: \(Int(v.width))x\(Int(v.height))")
                    lines.append("  Size: \(v.fileSize) bytes")
                }
                if let err = errorMsg {
                    lines.append("")
                    lines.append("Error: \(err)")
                }
                try lines.joined(separator: "\n").write(to: outputDirURL.appendingPathComponent("showcase_report.txt"), atomically: true, encoding: .utf8)
                print("Showcase artifacts written to: \(outputDirURL.path)")
            } catch {
                print("FAIL: Failed to persist showcase artifacts: \(error)")
            }
        }

        // Determine target scenes
        let targetScenes: [ShowcaseScene]
        if !scenesWanted.isEmpty {
            targetScenes = showcaseScenes.filter { scenesWanted.contains($0.manifest.id) }
        } else if let chapter = chapterWanted {
            targetScenes = showcaseScenes.filter { $0.manifest.chapter == chapter }
        } else {
            targetScenes = showcaseScenes.filter { $0.manifest.chapter == "core" }
        }

        guard !targetScenes.isEmpty else {
            let initialReports = showcaseManifest.map {
                ShowcaseSceneReport(id: $0.id, chapter: $0.chapter, feature: $0.feature, status: "NOT_REQUESTED", durationSeconds: 0, evidence: "No matching target scenes")
            }
            persistReport(scenes: initialReports, video: nil, errorMsg: "No matching showcase scenes found")
            print("FAIL: No matching showcase scenes found")
            exit(2)
        }

        var sceneReportMap: [String: ShowcaseSceneReport] = [:]
        for item in showcaseManifest {
            let isTarget = targetScenes.contains(where: { $0.manifest.id == item.id })
            sceneReportMap[item.id] = ShowcaseSceneReport(
                id: item.id,
                chapter: item.chapter,
                feature: item.feature,
                status: isTarget ? "PENDING" : "NOT_REQUESTED",
                durationSeconds: 0,
                evidence: isTarget ? "" : "Not requested in this run"
            )
        }

        // Preflight recorder if requested (Finding 1 & 2)
        var recorder: ShowcaseRecorder? = nil
        if let recPath = recordPath {
            print("==> Preflighting screen recorder...")
            do {
                try ShowcaseRecorder.preflightCheck(fullDisplay: recordFullDisplay)
                let recURL = URL(fileURLWithPath: recPath)
                recorder = try ShowcaseRecorder(targetFile: recURL, fullDisplay: recordFullDisplay)
            } catch {
                let reports = showcaseManifest.compactMap { sceneReportMap[$0.id] }
                persistReport(scenes: reports, video: nil, errorMsg: "Screen recording preflight error: \(error)")
                print("FAIL: Screen recording preflight error: \(error)")
                exit(1)
            }
        }

        let previouslyFront = NSWorkspace.shared.frontmostApplication
        var videoMeta: VideoMetadata? = nil
        var executionError: String? = nil

        do {
            let driver = try Driver(app: URL(fileURLWithPath: appPath))
            defer { driver.quit() }
            try driver.launch(config: "window-save-state = always\nsession-persistence = true\nremote-control = on\nconfirm-close-surface = false\n")

            let ctx = ShowcaseContext(driver: driver, pacing: pacing, outputDir: outputDirURL)

            // Start bounded recording if requested
            if let r = recorder {
                let initialFrame = driver.windowFrame()
                print("==> Starting screen recording (bounded: \(!recordFullDisplay))...")
                try r.start(for: initialFrame)
            }

            var hasFailed = false
            for scene in targetScenes {
                if hasFailed {
                    sceneReportMap[scene.manifest.id] = ShowcaseSceneReport(
                        id: scene.manifest.id,
                        chapter: scene.manifest.chapter,
                        feature: scene.manifest.feature,
                        status: "SKIPPED",
                        durationSeconds: 0,
                        evidence: "Skipped due to previous failure"
                    )
                    continue
                }

                print("==> Scene [\(scene.manifest.chapter)]: \(scene.manifest.feature)...")
                let start = Date()
                do {
                    try scene.run(ctx)
                    let duration = Date().timeIntervalSince(start)
                    sceneReportMap[scene.manifest.id] = ShowcaseSceneReport(
                        id: scene.manifest.id,
                        chapter: scene.manifest.chapter,
                        feature: scene.manifest.feature,
                        status: "PASS",
                        durationSeconds: duration,
                        evidence: "Verified postconditions"
                    )
                } catch {
                    hasFailed = true
                    let duration = Date().timeIntervalSince(start)
                    executionError = "Scene [\(scene.manifest.id)] failed: \(error)"
                    sceneReportMap[scene.manifest.id] = ShowcaseSceneReport(
                        id: scene.manifest.id,
                        chapter: scene.manifest.chapter,
                        feature: scene.manifest.feature,
                        status: "FAIL",
                        durationSeconds: duration,
                        evidence: "\(error)"
                    )
                    print("FAIL: \(executionError!)")
                }
            }

            if let r = recorder {
                print("==> Finalizing screen recording...")
                do {
                    videoMeta = try r.stop()
                    print("Recorded showcase movie saved to: \(r.targetFile.path) (\(String(format: "%.2f", videoMeta?.durationSeconds ?? 0))s, \(videoMeta?.fileSize ?? 0) bytes)")
                } catch {
                    executionError = "Recording finalization failed: \(error)"
                    print("FAIL: \(executionError!)")
                }
            }
        } catch {
            executionError = "Initialization error: \(error)"
            print("FAIL: \(executionError!)")
        }

        // Restore focus
        if let previouslyFront, !previouslyFront.isTerminated, let bundle = previouslyFront.bundleURL {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-g", "-a", bundle.path]
            try? open.run()
            open.waitUntilExit()
            previouslyFront.activate()
        }

        // Write mandatory artifacts (Finding 6)
        let finalReports = showcaseManifest.compactMap { sceneReportMap[$0.id] }
        persistReport(scenes: finalReports, video: videoMeta, errorMsg: executionError)

        let overallSuccess = executionError == nil && !finalReports.contains(where: { $0.status == "FAIL" })
        print(overallSuccess ? "Tako Showcase: OK" : "Tako Showcase: FAILED")
        exit(overallSuccess ? 0 : 1)
    }
}

extension Driver {
    static func sharedGitRevision() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["rev-parse", "HEAD"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return "unknown" }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
